`timescale 1ns/1ps
// S1-B: the only modified DUT is sd_stream_reader_core.v.
// Other modules are instantiated unchanged. All checks fail with $fatal.

module sd_drain_source #(parameter MODE=1, KIND=0, BASE_LBA=1000)(
    input clk, rst, go, input [27:0] lba, input [15:0] sectors,
    input ready, output [7:0] data, output valid, first, last,
    output [31:0] offset, output [27:0] sector,
    output [8:0] sector_byte, ram_addr,
    output init_done, busy, done, output read_complete
);
    wire ctrl_start; wire [1:0] ctrl_mode; wire [27:0] ctrl_sector;
    reg ctrl_done=0, filling=0; reg [8:0] fill_addr=0;
    reg [27:0] fill_sector=0; integer init_wait=0;
    wire [7:0] ram_data;
    reg [7:0] image[0:131071]; integer fd, nbytes=0;
    reg [1023:0] filename;
    initial begin
        if (KIND==2 || KIND==3) begin
            if (!$value$plusargs("file=%s",filename)) $fatal(1,"need +file=");
            fd=$fopen(filename,"rb");
            if (!fd) $fatal(1,"input file missing");
            nbytes=$fread(image,fd); $fclose(fd);
        end
    end
    function [7:0] pattern(input integer n);
        pattern=((n*37)^(n>>8)^(n>>3)^8'hA7)&255;
    endfunction
    function [7:0] bmp_channel(input integer pixel, input integer channel);
        case (channel)
          0: bmp_channel=pixel&255;
          1: bmp_channel=(pixel>>3)&255;
          2: bmp_channel=((pixel>>5)^8'h77)&255;
        endcase
    endfunction
    function [7:0] source_byte(input integer n);
        integer pixel, ch;
        begin
            if (KIND==0) source_byte=pattern(n);
            else if (KIND==1) begin
                if (n<54) begin
                    case(n)
                      0: source_byte="B"; 1: source_byte="M";
                      10: source_byte=54; 14: source_byte=40;
                      18: source_byte=0; 19: source_byte=5; // width=1280
                      22: source_byte=8'h30; 23: source_byte=8'hFD;
                      24,25: source_byte=8'hFF; // height=-720, top-down
                      26: source_byte=1; 28: source_byte=24;
                      default: source_byte=0;
                    endcase
                end else begin
                    pixel=(n-54)/3; ch=(n-54)%3;
                    source_byte=bmp_channel(pixel,ch);
                end
            end else source_byte=(n>=0 && n<nbytes) ? image[n] : 0;
        end
    endfunction
    // Use the actual vendor RAM model: registered read, not a combinational stub.
    ram_dual_port_simple #(.data_width(8),.data_num(512)) rd_ram (
        .douta(), .doutb(ram_data),
        .dina(source_byte((fill_sector-BASE_LBA)*512+fill_addr)),
        .addra(fill_addr), .addrb(ram_addr), .wea(filling), .clka(clk),.clkb(clk)
    );
    always @(posedge clk) begin
        if (rst) begin ctrl_done<=0; filling<=0; init_wait<=0; fill_addr<=0; end
        else begin
            ctrl_done<=0;
            if (init_wait!=0) begin
                init_wait<=init_wait-1;
                if (init_wait==1) ctrl_done<=1;
            end
            if (filling) begin
                if (fill_addr==511) begin filling<=0; ctrl_done<=1; end
                else fill_addr<=fill_addr+1;
            end
            if (ctrl_start) begin
                if (ctrl_mode==0) init_wait<=4;
                else if (ctrl_mode==2) begin
                    fill_sector<=ctrl_sector; fill_addr<=0; filling<=1;
                end else $fatal(1,"unexpected controller command");
            end
        end
    end
    assign read_complete=ctrl_done && ctrl_mode==2;
    sd_stream_reader_core #(.DRAIN_1CYC(MODE)) dut (
        .clk(clk),.rst(rst),.start(go),.start_sector(lba),.sector_count(sectors),
        .ctrl_start(ctrl_start),.ctrl_mode(ctrl_mode),.ctrl_sector_addr(ctrl_sector),
        .ctrl_done(ctrl_done),.ctrl_rd_ram_addr(ram_addr),.ctrl_rd_ram_data(ram_data),
        .stream_data(data),.stream_valid(valid),.stream_ready(ready),
        .stream_first(first),.stream_last(last),.stream_byte_offset(offset),
        .stream_sector_addr(sector),.stream_sector_byte_addr(sector_byte),
        .init_done(init_done),.busy(busy),.done(done)
    );
endmodule

module sd_drain_equiv_case #(parameter STALL=0, NSECT=1)(output reg finished=0);
    reg clk=0; always #10 clk=~clk;
    reg rst=1, go=0; reg [15:0] requested=0;
    wire [1:0] valid,first,last,init_done,busy,done,read_complete;
    wire [7:0] data[0:1]; wire [31:0] offset[0:1];
    wire [27:0] sector[0:1]; wire [8:0] sb[0:1],addr[0:1];
    reg [1:0] ready=3;
    integer count[0:1],cycles=0,read_cycle[0:1],elapsed[0:1];
    reg [1:0] completed=0,held=0;
    reg [7:0] trace[0:1][0:4095];
    reg [7:0] held_data[0:1]; reg [31:0] held_offset[0:1];
    reg [8:0] held_addr[0:1]; reg held_first[0:1],held_last[0:1];
    integer tail_pause[0:1]; reg [31:0] rng[0:1];
    genvar g;
    generate for(g=0;g<2;g=g+1) begin: modes
        sd_drain_source #(.MODE(g)) source (
            .clk(clk),.rst(rst),.go(go),.lba(28'd1000),.sectors(requested),
            .ready(ready[g]),.data(data[g]),.valid(valid[g]),.first(first[g]),.last(last[g]),
            .offset(offset[g]),.sector(sector[g]),.sector_byte(sb[g]),.ram_addr(addr[g]),
            .init_done(init_done[g]),.busy(busy[g]),.done(done[g]),.read_complete(read_complete[g])
        );
        always @(negedge clk) begin
            if(rst) begin ready[g]=1; tail_pause[g]=0; rng[g]=32'h1234ABCD+g; end
            else if(STALL) begin
                rng[g]={rng[g][30:0],rng[g][31]^rng[g][21]^rng[g][1]^rng[g][0]};
                if(valid[g] && sb[g]==511 && tail_pause[g]<7) begin
                    ready[g]=0; tail_pause[g]=tail_pause[g]+1;
                end else begin
                    ready[g]=(rng[g][2:0]!=0 && rng[g][5:3]!=0);
                    if(!valid[g] || sb[g]!=511) tail_pause[g]=0;
                end
            end else ready[g]=1;
        end
        always @(posedge clk) begin
            if(rst || (go && requested!=0)) begin
                count[g]=0; completed[g]=0; held[g]=0; elapsed[g]=0;
            end else begin
                if(read_complete[g]) read_cycle[g]=cycles;
                if(held[g]) begin
                    if(!valid[g] || data[g]!==held_data[g] || offset[g]!==held_offset[g] ||
                       first[g]!==held_first[g] || last[g]!==held_last[g])
                        $fatal(1,"STALL payload changed mode=%0d offset=%0d",g,offset[g]);
                    if(!ready[g] && addr[g]!==held_addr[g]) $fatal(1,"STALL RAM address changed");
                end
                held[g]=valid[g]&&!ready[g];
                held_data[g]=data[g]; held_offset[g]=offset[g]; held_addr[g]=addr[g];
                held_first[g]=first[g]; held_last[g]=last[g];
                if(valid[g]&&ready[g]) begin
                    if(offset[g]!==count[g] || sb[g]!==count[g]%512 ||
                       sector[g]!==1000+count[g]/512 ||
                       first[g] !== (count[g]==0) || last[g] !== (count[g]==requested*512-1))
                        $fatal(1,"metadata mismatch mode=%0d count=%0d",g,count[g]);
                    if(data[g]!==source.pattern(count[g])) $fatal(1,"oracle byte mismatch");
                    trace[g][count[g]]=data[g];
                    count[g]=count[g]+1;
                    if(sb[g]==511) elapsed[g]=cycles-read_cycle[g];
                end
                if(done[g]) begin
                    if(count[g]!=requested*512 || busy[g]) $fatal(1,"done/busy/count mismatch");
                    if(completed[g]) $fatal(1,"duplicate done");
                    completed[g]=1;
                end
            end
        end
    end endgenerate
    // Counter changes away from the sampling edge: no simulator ordering ambiguity.
    always @(negedge clk) cycles=cycles+1;
    task launch(input integer n);
        begin
            @(negedge clk); requested=n; go=1;
            @(negedge clk); go=0;
        end
    endtask
    task compare(input integer n);
        integer i;
        begin
            wait(completed==3); @(negedge clk);
            for(i=0;i<n*512;i=i+1)
                if(trace[0][i]!==trace[1][i]) $fatal(1,"A/B mismatch at %0d",i);
            if(!STALL && (elapsed[1]>520 || elapsed[1]<512 || elapsed[0]<1024 || elapsed[0]>1030))
                $fatal(1,"DRAINCHK cycles fast=%0d old=%0d",elapsed[1],elapsed[0]);
            $display("DRAINCHK: PASS sectors=%0d stall=%0d compare=%0d fast_last_sector=%0d old_last_sector=%0d",n,STALL,n*512,elapsed[1],elapsed[0]);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk); rst=0; wait(init_done==3);
        launch(0); repeat(12) @(negedge clk);
        if(busy || valid || done) $fatal(1,"zero sector request not ignored");
        launch(NSECT); compare(NSECT);
        // Reset with outstanding byte(s), then replay from offset zero.
        launch(1); wait(count[1]>=17); @(negedge clk); rst=1;
        repeat(5) @(negedge clk); rst=0; wait(init_done==3);
        launch(1); compare(1);
        finished=1;
    end
    initial begin #4_000_000; $fatal(1,"drain case timeout"); end
endmodule

module tb_sd_drain;
    wire a,b;
    sd_drain_equiv_case #(.STALL(0),.NSECT(1)) throughput(a);
    sd_drain_equiv_case #(.STALL(1),.NSECT(3)) stalls(b);
    initial begin wait(a&&b); $display("DRAIN_SUITE: PASS zero request, A/B, random+tail stalls, reset/replay"); $finish; end
endmodule

module tb_sd_bmp;
    reg clk=0; always #10 clk=~clk;
    reg rst=1, go=0, load_start=0;
    wire [7:0] data; wire valid,ready,init_done,busy,done;
    wire [31:0] wrdata; wire wr_en,loaded;
    wire [19:0] words; integer checked=0;
    sd_drain_source #(.KIND(1)) source (
        .clk(clk),.rst(rst),.go(go),.lba(28'd1000),.sectors(16'd5401),.ready(ready),
        .data(data),.valid(valid),.first(),.last(),.offset(),.sector(),.sector_byte(),.ram_addr(),
        .init_done(init_done),.busy(busy),.done(done),.read_complete()
    );
    yingxu_bmp_loader dut (
        .clk(clk),.rst(rst),.start(load_start),.sd_data(data),.sd_valid(valid),.sd_ready(ready),
        .wr2_data(wrdata),.wr2_en(wr_en),.wr2_full(1'b0),.i_base(21'h100000),
        .wr2_addr(),.wr2_max_addr(),.wr2_len(),.wr2_load(),.words_written(words),.loaded(loaded)
    );
    function [15:0] expected_pixel(input integer n);
        reg[7:0] b,g,r;
        begin b=n&255; g=(n>>3)&255; r=((n>>5)^8'h77)&255;
            expected_pixel={r[7:3],g[7:2],b[7:3]}; end
    endfunction
    always @(posedge clk) if(!rst && wr_en) begin
        if(wrdata!=={expected_pixel(checked*2),expected_pixel(checked*2+1)})
            $fatal(1,"BMP pair mismatch word=%0d",checked);
        checked=checked+1;
    end
    initial begin
        repeat(5) @(negedge clk); rst=0; wait(init_done);
        @(negedge clk); load_start=1;
        @(negedge clk); load_start=0; go=1;
        @(negedge clk); go=0;
        wait(done); repeat(3) @(negedge clk);
        if(!loaded || words!=460800 || checked!=460800) $fatal(1,"BMP incomplete");
        $display("BMPCHK: PASS 1280x720 words=%0d/460800 pixels=%0d/921600 zero-diff",checked,checked*2);
        $finish;
    end
    initial begin #200_000_000; $fatal(1,"BMP timeout"); end
endmodule

module tb_sd_cart;
    reg clk=0,pix=0; always #10 clk=~clk; always #6.818 pix=~pix;
    reg rst=1,en=0,go=0,requested=0;
    wire [7:0] data; wire valid,init_done,busy,done,restart,cart_ready;
    wire [9:0] wc; integer i,bad=0,file_words; reg[23:0] gold;
    sd_drain_source #(.KIND(2)) source (
        .clk(clk),.rst(rst),.go(go),.lba(28'd1000),.sectors(16'd4),.ready(cart_ready),
        .data(data),.valid(valid),.first(),.last(),.offset(),.sector(),.sector_byte(),.ram_addr(),
        .init_done(init_done),.busy(busy),.done(done),.read_complete()
    );
    yx8_cart_soc_v2 dut (
        .sys_clk(clk),.pix_clk(pix),.sys_rst(rst),.pix_rst(rst),.en(en),.sd_ready(init_done),
        .sd_data(data),.sd_valid(valid),.key0_n(1'b1),.key1_n(1'b1),
        .pix_frame_tick(1'b0),.reload(1'b0),.test_mode(1'b0),
        .cart_restart(restart),.cart_wcnt(wc),.cart_ready(cart_ready)
    );
    // Model the FPGA's zero-initialized power-on counter; do not bypass its 1M cycles.
    initial dut.por_cnt=0;
    always @(posedge clk) begin
        go<=0;
        if(!rst && restart && !requested) begin go<=1; requested<=1; end
    end
    initial begin
        repeat(5) @(negedge clk); rst=0; en=1;
        wait(done); wait(dut.loaded_s); repeat(8) @(negedge pix);
        $display("CART_DIAG wc=%0d words_r=%0d requested=%0d file_bytes=%0d loaded=%b state=%0d",
                 wc,dut.words_r,requested,source.nbytes,dut.loaded_s,dut.lstate);
        // Diagnostic comparison follows the immutable file header. The strict
        // user-requested WC=606 gate below is retained and must still fail at 604.
        file_words={source.image[9],source.image[8]};
        if(file_words<1 || file_words>768) $fatal(1,"invalid fixture header");
        for(i=0;i<file_words;i=i+1) begin
            gold={source.image[32+i*3],source.image[33+i*3],source.image[34+i*3]};
            if(dut.u_prog.ram[i]!==gold) bad=bad+1;
        end
        $display("CART_WORDCHK: BADC0UNT=%0d of %0d; WC=%0d required=606",bad,file_words,wc);
        if(bad) $fatal(1,"cart program mismatch");
        for(i=file_words;i<1023;i=i+1)
            if(dut.u_prog.ram[i]!==24'd0) $fatal(1,"cart padding mismatch word=%0d",i);
        if(dut.u_prog.ram[1023]!==0) $fatal(1,"cart metadata mismatch");
        if(wc!=606 || dut.words_r!=606 || !requested) $fatal(1,"cart WC mismatch: strict 606 gate retained");
        $display("CARTCHK: PASS BADC0UNT=0 of 606; cart_wcnt(WC)=606; padding/meta zero-diff");
        $finish;
    end
    initial begin #30_000_000; $fatal(1,"cart timeout"); end
endmodule

module tb_sd_wav;
    reg clk=0,pix=0; always #10 clk=~clk; always #6.818 pix=~pix;
    reg rst=1,active=0,go=0,pending=0,issued=0; reg[27:0] lba=2000000;
    wire [7:0] data; wire valid,ready,init_done,busy,done,restart;
    wire[27:0] base; wire[23:0] left,right; wire wav_active;
    reg tick=0; integer tc=0,oticks=0,pops=0,nz=0,zc=0,last_l=0,fed=0,chunks=0;
    integer ratio,expect_ratio;
    sd_drain_source #(.KIND(3),.BASE_LBA(2000000)) source (
        .clk(clk),.rst(rst),.go(go),.lba(lba),.sectors(16'd16),.ready(ready),
        .data(data),.valid(valid),.first(),.last(),.offset(),.sector(),.sector_byte(),.ram_addr(),
        .init_done(init_done),.busy(busy),.done(done),.read_complete()
    );
    yingxu_wav_player #(.CHUNK_BYTES(28'd8192)) dut (
        .sys_clk(clk),.sys_rst(rst),.pix_clk(pix),.pix_rst(rst),.music_active(active),
        .wav_base(base),.wav_restart(restart),.sd_data(data),.sd_valid(valid),.sd_ready(ready),
        .out_tick(tick),.wav_l(left),.wav_r(right),.wav_active(wav_active)
    );
    always @(posedge clk) begin
        if(rst) begin go<=0; pending<=0; issued<=0; fed<=0; chunks<=0; end
        else begin
            go<=0;
            if(valid&&ready) fed<=fed+1;
            if(restart || (active&&!issued)) pending<=1;
            if(pending && init_done && !busy) begin go<=1; lba<=base; pending<=0; issued<=1; end
            if(restart) begin
                if(base-2000000 != fed/512) $fatal(1,"CHUNKCHK FAIL base=%0d fed=%0d",base-2000000,fed/512);
                $display("CHUNKCHK: OK base_off=%0d fed=%0d",base-2000000,fed/512);
                chunks<=chunks+1;
            end
        end
    end
    always @(posedge pix) begin
        if(rst) begin tc<=0; tick<=0; end
        else if(tc==63) begin tc<=0; tick<=1; end
        else begin tc<=tc+1; tick<=0; end
        if(!rst && tick) oticks=oticks+1;
        if(!rst && wav_active && dut.pop) begin
            pops=pops+1;
            if(left!==0) nz=nz+1;
            if(($signed(left)<0)!=(last_l<0) && left!==0) zc=zc+1;
            last_l=$signed(left);
        end
    end
    initial begin
        repeat(8) @(negedge clk); rst=0;
        wait(init_done); repeat(8) @(negedge clk); active=1;
        wait(pops>=16000); #1000;
        ratio=pops*10000/oticks; expect_ratio=dut.rate*10000/48000;
        if(ratio+300<=expect_ratio || ratio>=expect_ratio+300) $fatal(1,"RATECHK FAIL");
        if(nz<=pops*3/4 || zc<=100 || chunks<8) $fatal(1,"WAV waveform/chunks failed");
        $display("WAVCHK: PASS rate=%0d pops=%0d nonzero=%0d crossings=%0d",dut.rate,pops,nz,zc);
        $display("RATECHK: PASS ratio_x10000=%0d expected=%0d; CHUNKCHK count=%0d exact-match",ratio,expect_ratio,chunks);
        $finish;
    end
    initial begin #100_000_000; $fatal(1,"WAV timeout"); end
endmodule
