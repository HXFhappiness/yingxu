// =============================================================================
// tb_wav_player.v — yingxu_wav_player 独立验证
//   喂 tb_tune.yxm（262Hz 0.25s + 392Hz 0.25s）→ 检查 wav_l 是否产生正弦、
//   零交叉频率是否对应两个音符、pcm 长度/头解析是否正确。
// 编译：
//   iverilog -g2012 -o tb_wav.vvp tb_wav_player.v yingxu_wav_player.v \
//             media/sd/ram_dual_port_simple.v
// =============================================================================
`timescale 1ns/1ps

module tb_wav_player;

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

    yingxu_wav_player #(
        .MUSIC_BASE (28'd2_000_000),
        .CHUNK_BYTES(28'd2_765_312)
    ) dut (
        .sys_clk(sys_clk), .sys_rst(sys_rst),
        .pix_clk(pix_clk), .pix_rst(pix_rst),
        .music_active(music_active),
        .wav_base(wav_base), .wav_restart(wav_restart),
        .sd_data(sd_data), .sd_valid(sd_valid), .sd_ready(sd_ready),
        .out_tick(out_tick),
        .wav_l(wav_l), .wav_r(wav_r), .wav_active(wav_active)
    );

    // ---- 48kHz 节拍（加速版：每 64 拍来一次，仿真快 42 倍）------------------
    integer tc = 0;
    always @(posedge pix_clk) begin
        if (tc == 63) begin tc <= 0; out_tick <= 1'b1; end
        else          begin tc <= tc + 1; out_tick <= 1'b0; end
    end

    // ---- 字节流 -----------------------------------------------------------
    reg [7:0] bytes [0:262143];
    integer nbytes = 0, bidx = 0;

    reg cur_v;
    always @(posedge sys_clk) begin
        if (!sd_ready) bp_low = bp_low + 1;
        if ((dut.occ > max_occ) && (dut.occ < 1100)) max_occ = dut.occ;
        if (sys_rst) begin
            sd_valid <= 1'b0; cur_v <= 1'b0;
        end
        else if (!cur_v) begin
            // 没有待发字节：取下一个（若还有）
            if (music_active && bidx < nbytes) begin
                sd_data  <= bytes[bidx];
                sd_valid <= 1'b1;
                cur_v    <= 1'b1;
            end
            else begin
                sd_valid <= 1'b0;
            end
        end
        else if (sd_ready) begin
            // 本拍握手成功 → 前进
            bidx <= bidx + 1;
            if (bidx + 1 < nbytes) begin
                sd_data <= bytes[bidx + 1];   // 立刻换成下一个
            end
            else begin
                sd_valid <= 1'b0; cur_v <= 1'b0;
            end
        end
        // 否则（cur_v 且 !ready）：保持不变，等 ready
    end

    // ---- 观测 -------------------------------------------------------------
    integer pops = 0, nz = 0, zc = 0;
    integer bp_low = 0, max_occ = 0;
    integer last_l = 0, first_nz_time = 0;
    integer min_l = 99999999, max_l = -99999999;
    integer seg_pops = 0, seg_zc = 0;

    always @(posedge pix_clk) begin
        if (wav_active && (dut.pop === 1'b1)) begin
            pops = pops + 1;
            if (wav_l !== 24'sd0) begin
                nz = nz + 1;
                if (first_nz_time == 0) first_nz_time = pops;
            end
            if ((($signed(wav_l) < 0) != (last_l < 0)) && wav_l !== 24'sd0) zc = zc + 1;
            last_l = $signed(wav_l);
            if ($signed(wav_l) < min_l) min_l = $signed(wav_l);
            if ($signed(wav_l) > max_l) max_l = $signed(wav_l);

            seg_pops = seg_pops + 1;
            if (seg_pops == 3000) begin
                // 每 3000 个样本（≈62ms@48k）报一次局部零交叉
                $display("SEG pops=%0d zc=%0d last=%0d", pops, seg_zc, $signed(wav_l));
                seg_pops = 0; seg_zc = 0;
            end
            if ((($signed(wav_l) < 0) != (last_l < 0))) seg_zc = seg_zc + 1;
        end
    end

    // ---- 主流程 -----------------------------------------------------------
    integer fp;
    initial begin
        fp = $fopen("out/tb_tune.yxm", "rb");
        if (fp == 0) begin $display("FATAL: tb_tune.yxm missing"); $finish; end
        nbytes = $fread(bytes, fp);
        $fclose(fp);
        $display("[TB] bytes=%0d", nbytes);

        repeat (10) @(posedge sys_clk);
        sys_rst = 0;
        repeat (10) @(posedge pix_clk);
        pix_rst = 0;

        repeat (100) @(posedge pix_clk);
        music_active = 1;

        // 等足够样本被弹出（24000 样本）
        wait (pops >= 24000);
        #1000;

        $display("=================================================");
        $display("RESULT pops=%0d nonzero=%0d zerocross=%0d", pops, nz, zc);
        $display("       min=%0d max=%0d first_nz_pop=%0d", min_l, max_l, first_nz_time);
        $display("       BP: ready_low_cycles=%0d max_occ=%0d", bp_low, max_occ);
        $display("       sstate=%0d ch=%0d rate=%0d pcm_left=%0d wav_active=%b",
                 dut.sstate, dut.ch, dut.rate, dut.pcm_left, wav_active);
        // 262Hz 在 0.25s 内约 65 个周期；两个音共约 163 个零交叉（每周期 2 次）
        if (nz > 20000 && zc > 200) $display("VERDICT: PASS (sine present)");
        else                        $display("VERDICT: FAIL (no waveform)");
        $finish;
    end

endmodule
