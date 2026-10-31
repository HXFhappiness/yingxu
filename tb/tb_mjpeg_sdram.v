`timescale 1ns/1ps
module tb_mjpeg_sdram;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,fvalid=0;wire fready,busy,done,error;wire [7:0] code;
    reg [20:0] src_addr,dst_addr=21'h100000;reg [15:0] jpg_len;
    wire [31:0] frame_cycles;wire [17:0] committed;
    wire cv,cw;wire [20:0] ca;wire [3:0] cn;
    wire rv,rr,rl,wv,wr,wl;wire [31:0] rd,wd;
    reg [7:0] container[0:2999999];
    reg [15:0] gold[0:307199];reg [31:0] image[0:153599];reg covered[0:153599];
    integer infd,gfd,nfile,nframes,limit=1,first=0,fault=0,pressure=0,expect_code=-1;
    integer f,off,ln,i,n,words_seen=0,read_beats=0,write_beats=0,commands=0;
    integer tick=0,remaining_delay=0;
    reg active=0,is_write=0,rv_r=0,rl_r=0,mdone=0,merr=0;
    reg [31:0] rd_r;
    reg [20:0] base;reg [3:0] count,index;
    reg [31:0] rng=32'h12345678;
    reg [1023:0] filename,goldname,dumpname;
    integer dumpfd=0,jpg_start=0,jpg_end=0,location;
    wire opportunity=pressure ? (tick%40==0 || tick%40==8 || tick%40==16 || tick%40==24) : rng[3:0]!=0;
    wire cr=!active && remaining_delay==0 && !mdone && tick%7!=0;
    assign rv=rv_r;assign rd=rd_r;assign rl=rl_r;
    assign wr=active && is_write && index<count && opportunity;
    yingxu_mjpeg_decoder dut(.clk(clk),.rst(rst),.frame_valid(fvalid),.frame_ready(fready),
        .src_addr(src_addr),.dst_addr(dst_addr),.jpeg_bytes(jpg_len),
        .busy(busy),.done(done),.error(error),.error_code(code),.frame_cycles(frame_cycles),.committed_words(committed),
        .cmd_valid(cv),.cmd_ready(cr),.cmd_write(cw),.cmd_addr(ca),.cmd_words(cn),
        .rvalid(rv),.rready(rr),.rdata(rd),.rlast(rl),.wvalid(wv),.wready(wr),.wdata(wd),.wlast(wl),
        .mem_done(mdone),.mem_error(merr));
    function integer le32(input integer a);
        le32={container[a+3],container[a+2],container[a+1],container[a]};
    endfunction
    function [31:0] source_word(input [20:0] a);
        integer b;
        begin b=(a-21'h010000)*4;
            source_word={container[b+3],container[b+2],container[b+1],container[b]};
        end
    endfunction
    reg held_cmd=0,held_write=0;reg [24:0] old_cmd;reg old_cw;
    reg [32:0] old_write;
    always @(posedge clk) begin
        tick<=tick+1;rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        mdone<=0;merr<=0;
        if(!rst) begin
            if(held_cmd && (!cv || {ca,cn}!==old_cmd || cw!==old_cw)) $fatal(1,"command changed during stall");
            held_cmd<=cv&&!cr;old_cmd<={ca,cn};old_cw<=cw;
            if(held_write && (!wv || {wd,wl}!==old_write)) $fatal(1,"write payload changed during stall");
            held_write<=wv&&!wr;old_write<={wd,wl};
            if(cv && cr) begin
                if(cn<1 || cn>8) $fatal(1,"invalid burst length");
                if(cw ? (ca<dst_addr || ca+cn>dst_addr+153600) : (ca<jpg_start || ca+cn>jpg_end))
                    $fatal(1,"out of bounds command write=%0d addr=%h words=%0d",cw,ca,cn);
                active<=1;is_write<=cw;base<=ca;count<=cn;index<=0;commands<=commands+1;
            end
            if(active && !is_write && !rv_r && index<count && opportunity) begin
                rv_r<=1;rd_r<=source_word(base+index);rl_r<=(fault==6 && f==first && read_beats==0) ? 1'b1:(index+1==count);
            end
            if(rv_r && rr) begin
                rv_r<=0;index<=index+1'b1;read_beats<=read_beats+1;
                if(index+1==count) remaining_delay<=5;
            end
            if(wv && wr) begin
                location=base+index-dst_addr;
                if(covered[location] || wd!=={gold[location*2],gold[location*2+1]})
                    $fatal(1,"SDRAM_PIXCHK frame=%0d word=%0d got=%08h expected=%08h duplicate=%0d",f,location,wd,{gold[location*2],gold[location*2+1]},covered[location]);
                covered[location]=1;image[location]=wd;words_seen=words_seen+1;
                if(wl!==(index+1==count)) $fatal(1,"wlast mismatch");
                index<=index+1'b1;write_beats<=write_beats+1;
                if(index+1==count) remaining_delay<=7;
            end
            if(remaining_delay!=0) begin
                remaining_delay<=remaining_delay-1;
                if(remaining_delay==1) begin
                    if(f==first && ((fault==4 && !is_write) || (fault==5 && is_write))) merr<=1;
                    else mdone<=1;
                    active<=0;
                end
            end
        end
    end
    initial begin
        if(!$value$plusargs("file=%s",filename) || !$value$plusargs("gold=%s",goldname)) $fatal(1,"file/gold required");
        n=$value$plusargs("limit=%d",limit);n=$value$plusargs("first=%d",first);
        n=$value$plusargs("expect_code=%d",expect_code);n=$value$plusargs("fault=%d",fault);n=$value$plusargs("pressure=%d",pressure);
        if($value$plusargs("dump=%s",dumpname)) begin dumpfd=$fopen(dumpname,"wb");if(!dumpfd) $fatal(1,"dump open");end
        infd=$fopen(filename,"rb");if(!infd) $fatal(1,"container open");
        nfile=$fread(container,infd);$fclose(infd);
        if({container[0],container[1],container[2],container[3]}!==32'h59585631) $fatal(1,"container magic");
        nframes=le32(12);if(first+limit>nframes) $fatal(1,"frame index range");
        gfd=$fopen(goldname,"rb");if(!gfd) $fatal(1,"gold open");
        repeat(5) @(negedge clk);rst=0;
        for(f=first;f<first+limit;f=f+1) begin
            off=le32(32+f*8);ln=le32(36+f*8);
            if(fault!=0 && f==first) begin
                if(fault==1) ln=ln-16;
                else if(fault==2) begin
                    for(i=off;i<off+ln-4;i=i+1)
                        if(container[i]==255 && container[i+1]==8'hC4) begin container[i+5]=255;i=off+ln;end
                end
            end
            if(ln<4 || ln>65535 || off+ln>nfile || off%512!=0) $fatal(1,"YXV frame extent");
            src_addr=21'h010000+(off/4);jpg_len=ln;
            jpg_start=src_addr;jpg_end=src_addr+(ln+3)/4;
            for(i=0;i<153600;i=i+1) covered[i]=0;
            words_seen=0;
            n=$fseek(gfd,f*614400,0);n=$fread(gold,gfd,0,307200);
            if(n!=614400) $fatal(1,"gold frame extent read=%0d",n);
            @(negedge clk);fvalid=1;wait(fready);@(negedge clk);fvalid=0;
            wait(done);@(negedge clk);
            if(active || remaining_delay || rv_r) $fatal(1,"frame reported before physical transaction completion");
            if(fault!=0 && f==first) begin
                if(expect_code>=0 && code!==expect_code[7:0]) $fatal(1,"wrong error code actual=%h expected=%h",code,expect_code);
                if(!error || frame_cycles>=8_000_000) $fatal(1,"malformed frame did not fail promptly");
                $display("ERRORCHK: PASS frame=%0d fault=%0d code=%02h cycles=%0d committed_partial=%0d no-commit no-OOB",f,fault,code,frame_cycles,committed);
            end else begin
                if(error || committed!=153600 || words_seen!=153600) $fatal(1,"frame result error=%0d code=%h words=%0d",error,code,words_seen);
                for(i=0;i<153600;i=i+1) if(!covered[i]) $fatal(1,"missing output word");
                if(frame_cycles>4166666) $fatal(1,"DEADLINECHK 24fps failed cycles=%0d",frame_cycles);
                $display("SDRAM_FRAMECHK: PASS frame=%0d bytes=%0d words=%0d/153600 pixels=307200/307200 zero-diff cycles=%0d ratio_frame_x10000=%0d pressure=%0d",f,ln,words_seen,frame_cycles,frame_cycles*24/10000,pressure);
                if(dumpfd && f==first) for(i=0;i<153600;i=i+1)
                    $fwrite(dumpfd,"%c%c%c%c",image[i][31:24],image[i][23:16],image[i][15:8],image[i][7:0]);
            end
            repeat(5) @(negedge clk);
        end
        $fclose(gfd);if(dumpfd) $fclose(dumpfd);
        $display("SDRAM_SUITE: PASS frames=%0d pressure=%0d fault=%0d commands=%0d read_words=%0d write_words=%0d",limit,pressure,fault,commands,read_beats,write_beats);
        $finish;
    end
    initial begin #4_000_000_000;$fatal(1,"system TB timeout");end
endmodule
