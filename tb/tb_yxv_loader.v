`timescale 1ns/1ps
module tb_yxv_loader;
    reg clk=0;always #5 clk=~clk;reg rst=1,en=0;
    wire sv;reg sr=0,sdone=0;wire [27:0] lba;wire [15:0] sectors;
    reg [7:0] data;reg valid=0;wire ready;
    wire meta,fail;wire [7:0] error;wire [9:0] frames;wire [31:0] pcm;
    wire [1:0] slots;reg [1:0] release_slot=0;wire [31:0] tag0,tag1;wire [15:0] len0,len1;
    wire cv,cw,wv,wl;reg cr=0,wr=0,done=0;wire [20:0] addr;wire [3:0] words;wire [31:0] wd;
    reg [7:0] source[0:5999999];reg [31:0] memory[0:2097151];
    integer fd,nfile,i,j,off,nbytes,base=0,p=0,left=0,cycle=0,cmds=0,midx=0,delay_done=0;
    reg reading=0,writing=0;reg [20:0] maddr;reg [1023:0] filename;
    yingxu_yxv_loader dut(.clk(clk),.rst(rst),.enable(en),.sd_valid(sv),.sd_ready(sr),.sd_lba(lba),.sd_sectors(sectors),
        .sd_done(sdone),.sd_byte(data),.sd_byte_valid(valid),.sd_byte_ready(ready),
        .ready(meta),.failed(fail),.error_code(error),.frames(frames),.pcm_bytes(pcm),
        .slot_valid(slots),.slot_release(release_slot),.slot_tag0(tag0),.slot_tag1(tag1),.slot_len0(len0),.slot_len1(len1),
        .cmd_valid(cv),.cmd_ready(cr),.cmd_write(cw),.cmd_addr(addr),.cmd_words(words),
        .wvalid(wv),.wready(wr),.wdata(wd),.wlast(wl),.mem_done(done),.mem_error(1'b0));
    function integer le32(input integer pos);le32={source[pos+3],source[pos+2],source[pos+1],source[pos]};endfunction
    always @(negedge clk) begin
        sr=!reading && !rst;cr=!writing && delay_done==0 && !done;wr=writing && cycle%3!=0;
        if(reading) begin valid=1;data=base+p<nfile ? source[base+p]:0;end else valid=0;
    end
    always @(posedge clk) begin
        cycle<=cycle+1;sdone<=0;done<=0;
        if(rst) begin reading<=0;writing<=0;delay_done<=0;end
        else begin
            if(sv&&sr) begin base<=(lba-3000000)*512;p<=0;left<=sectors*512;reading<=1;cmds<=cmds+1;end
            if(valid&&ready) begin p<=p+1;if(p+1==left) begin reading<=0;sdone<=1;end end
            if(cv&&cr) begin if(!cw || words!=8) $fatal(1,"loader burst contract");writing<=1;maddr<=addr;midx<=0;end
            if(wv&&wr) begin memory[maddr+midx]<=wd;midx<=midx+1;if(midx==7) begin writing<=0;delay_done<=4;end end
            if(delay_done!=0) begin delay_done<=delay_done-1;if(delay_done==1)done<=1;end
        end
    end
    task check_slot(input integer bank,input integer index,input integer length);
        integer a,k;reg [7:0] actual;
        begin
            a=le32(32+index*8);
            for(k=0;k<length;k=k+1) begin actual=memory[(bank ? 21'h084000:21'h080000)+k/4]>>(8*(k%4));
                if(actual!==source[a+k]) $fatal(1,"JPEG staging diff bank=%0d byte=%0d",bank,k);
            end
        end
    endtask
    initial begin
        if(!$value$plusargs("file=%s",filename)) filename="tb/testvectors/testvec_budget.yxv";
        fd=$fopen(filename,"rb");nfile=$fread(source,fd);$fclose(fd);
        repeat(5) @(negedge clk);rst=0;en=1;
        wait(slots==3);@(negedge clk);
        if(fail || !meta || frames!=le32(12) || pcm!=le32(20) || tag0!=0 || tag1!=1) $fatal(1,"metadata/staging failed %h",error);
        off=le32(32+(frames-1)*8);nbytes=le32(36+(frames-1)*8);off=off+(nbytes+511)/512*512;
        for(i=0;i<pcm;i=i+1) begin
            if(((memory[21'h100000+i/4]>>(8*(i%4)))&255)!==source[off+i]) $fatal(1,"PCM preload byte diff %0d",i);
        end
        check_slot(0,0,len0);check_slot(1,1,len1);
        release_slot=1;@(negedge clk);release_slot=0;
        wait(slots[0]&&tag0==2);@(negedge clk);check_slot(0,2,len0);
        $display("SUPPLYCHK: PASS frames=%0d PCM=%0d bytes zero-diff JPEG=0,1,2 exact table-indexed commands=%0d",frames,pcm,cmds);
        // Common reset plus invalid magic: must drain one sector then stop.
        rst=1;repeat(5) @(negedge clk);source[0]=0;rst=0;
        wait(fail);@(negedge clk);
        if(reading || error!=8'h92) $fatal(1,"bad header failed to drain/error");
        $display("HEADERCHK: PASS bad magic code=%h finite reject drained-SD",error);$finish;
    end
    initial begin #20000000;$fatal(1,"loader timeout state=%d count=%d",dut.state,dut.count);end
endmodule
