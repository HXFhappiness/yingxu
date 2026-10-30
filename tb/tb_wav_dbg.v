`timescale 1ns/1ps
// tb_wav_dbg.v — 调试：pop 时打印 RAM 内容 / rdata / wdec / 打包字节
module tb_wav_dbg;

    reg sys_clk = 0, pix_clk = 0;
    always #10    sys_clk = ~sys_clk;     // 50 MHz
    always #6.818 pix_clk = ~pix_clk;     // 73.3 MHz

    reg  sys_rst = 1, pix_rst = 1;
    reg  music_active = 0;
    reg  [7:0] sd_data = 8'h00;
    reg        sd_valid = 1'b0;
    wire       sd_ready;
    wire [27:0] wav_base;
    wire        wav_restart;
    reg        out_tick = 1'b0;
    wire [23:0] wav_l, wav_r;
    wire        wav_active;

    yingxu_wav_player dut (
        .sys_clk(sys_clk), .sys_rst(sys_rst),
        .pix_clk(pix_clk), .pix_rst(pix_rst),
        .music_active(music_active),
        .wav_base(wav_base), .wav_restart(wav_restart),
        .sd_data(sd_data), .sd_valid(sd_valid), .sd_ready(sd_ready),
        .out_tick(out_tick),
        .wav_l(wav_l), .wav_r(wav_r), .wav_active(wav_active)
    );

    integer tc = 0;
    always @(posedge pix_clk) begin
        if (tc == 63) begin tc <= 0; out_tick <= 1'b1; end
        else          begin tc <= tc + 1; out_tick <= 1'b0; end
    end

    reg [7:0] bytes [0:262143];
    integer nbytes = 0, bidx = 0;

    always @(posedge sys_clk) begin
        if (sys_rst) sd_valid <= 1'b0;
        else if (music_active && sd_ready && bidx < nbytes) begin
            sd_data  <= bytes[bidx];
            sd_valid <= 1'b1;
            bidx     <= bidx + 1;
        end
        else sd_valid <= 1'b0;
    end

    integer pops = 0;
    integer wfire = 0;
    always @(posedge pix_clk) begin
        if (dut.pop) begin
            pops = pops + 1;
            if (pops <= 8 || pops % 2000 == 0)
                $display("POP#%0d t=%0t rptr=%0d wptr=%0d wdec=%0d raddr=%0d ram[raddr]=%08X rdata=%08X wav_l=%06X b123=%02X%02X%02X",
                         pops, $time, dut.rptr, dut.wptr, dut.wdec, dut.raddr,
                         dut.u_fifo.ram[dut.rptr[9:0]], dut.rdata, wav_l,
                         dut.b1, dut.b0, dut.b2);
        end
    end
    always @(posedge sys_clk) if (dut.wena) begin
        wfire = wfire + 1;
        if (wfire <= 4)
            $display("WR#%0d t=%0t waddr=%0d wdata=%08X byte_v=%b bcnt=%0d",
                     wfire, $time, dut.waddr, dut.wdata, dut.byte_v, dut.bcnt);
    end

    integer fp;
    initial begin
        fp = $fopen("out/tb_tune.yxm", "rb");
        if (fp == 0) begin $display("FATAL: no file"); $finish; end
        nbytes = $fread(bytes, fp);
        $fclose(fp);
        $display("[TB] bytes=%0d  hdr=%02x%02x%02x%02x ch=%02x rate=%02x%02x",
                 nbytes, bytes[0], bytes[1], bytes[2], bytes[3], bytes[5], bytes[8], bytes[9]);
        repeat (10) @(posedge sys_clk);
        sys_rst = 0;
        repeat (10) @(posedge pix_clk);
        pix_rst = 0;
        repeat (100) @(posedge pix_clk);
        music_active = 1;
        wait (pops >= 6000);
        #1000;
        $display("DONE pops=%0d wptr=%0d rptr=%0d", pops, dut.wptr, dut.rptr);
        $finish;
    end
endmodule
