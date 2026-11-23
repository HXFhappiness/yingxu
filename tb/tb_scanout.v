`timescale 1ns/1ps
// tb_scanout.v — yx_b_scanout 独立仿真（P3 调试用，脱离全 SoC）
//
// 判据设计（YX6 定稿）：
//   源侧 video_source_test 有 2 级流水，故每行 valid 拍数 = 1280 有效 + 2 拍
//   消隐溢出（与 A 板同构、对 HDMI 核无害）。判据按"行内像素序号 m<1280"
//   比对，行末溢出拍忽略；期望值直接查内存模型（字=乘法哈希，可反解）。
//   全局 SHIFT（常数相位）由前 1000 像素自动搜索 —— 常数=正常，逐行增长=bug。
module tb_scanout;
`ifdef PIXDLY
    parameter PIX_DLY_P = `PIXDLY;
`else
    parameter PIX_DLY_P = 0;
`endif
    localparam FB_WIN0  = 21'd115200;
    localparam FB_TOTAL = 21'd460800;
    localparam NPASS    = 4;

    reg pixel_clk = 1'b0;
    always #6.818 pixel_clk = ~pixel_clk;
    reg pixel_rst = 1'b1;
    reg rst_n = 1'b0;

    reg win_show_req = 1'b0;
    reg first_win_done = 1'b0;
    wire video_ready = 1'b1;

    // ---- 行为读源：do 为 pop 沿寄存（vendor 语义）----
    reg [31:0] rmem [0:2*FB_TOTAL-1];
    reg [20:0] rptr = 0;
    reg [31:0] do_r = 0;
    reg rd1_load_d = 1'b0;
    wire [31:0] rd1_data = do_r;
    wire        rd1_empty = rd1_load_d;
    wire        rd1_bmask0 = 1'b0;
    wire        rd1_we = 1'b0;

    wire [20:0] rd1_addr;
    wire        rd1_load;
    wire [8:0]  rd1_len;
    wire        rd1_en;
    wire        video_user, video_valid, video_last;
    wire [23:0] video_data;
    wire        win_show;
    wire [15:0] disp_pass, disp_stall;

    yx_b_scanout #(
        .FB_WIN0  (FB_WIN0),
        .FB_TOTAL (FB_TOTAL),
        .PIX_DLY  (PIX_DLY_P)
    ) u_scanout (
        .rst_n          (rst_n),
        .win_show_req   (win_show_req),
        .first_win_done (first_win_done),
        .pixel_clk      (pixel_clk),
        .pixel_rst      (pixel_rst),
        .rd1_addr       (rd1_addr),
        .rd1_load       (rd1_load),
        .rd1_len        (rd1_len),
        .rd1_en         (rd1_en),
        .rd1_data       (rd1_data),
        .rd1_empty      (rd1_empty),
        .rd1_we         (rd1_we),
        .rd1_bmask0     (rd1_bmask0),
        .rd1_clk        (),
        .video_user     (video_user),
        .video_valid    (video_valid),
        .video_last     (video_last),
        .video_data     (video_data),
        .video_ready    (video_ready),
        .disp_pass      (disp_pass),
        .win_show       (win_show),
        .disp_stall     (disp_stall)
    );

    always @(posedge pixel_clk) begin
        rd1_load_d <= rd1_load;
        if (rd1_load)              rptr <= rd1_addr;
        else if (rd1_en && !rd1_empty) begin
            do_r <= rmem[rptr];
            rptr <= rptr + 21'd1;
            pops = pops + 1;
        end
    end

    integer k;
    initial begin
        for (k = 0; k < 2*FB_TOTAL; k = k + 1)
            rmem[k] = k * 32'h9E3779B9;      // 乘法哈希：每槽位唯一、可反解
    end

    // ---- 采集：按行内像素序号记录实际输出 ----
    reg [23:0] got [0:921599];               // 一遍 720×1280
    integer line = 0, m = 0, ng = 0, rec = 0;
    integer pass_p = 0;
    integer pops = 0, pops_frame = 0;

    always @(posedge pixel_clk) begin
        if (!pixel_rst) begin
            if (video_user) begin
                pass_p = pass_p + 1;
                if (rec) $display("SOFRAME pass=%0d pops_in_frame=%0d (want 460800) lines=%0d",
                                  pass_p, pops - pops_frame, line);
                pops_frame = pops;
                line = 0; m = 0;
                rec = (pass_p == 2);          // 录第 2 遍（稳态）
            end
            if (video_valid) begin
                // ★ 每行恰 1280 个 valid 拍（pops/frame=460801≈460800 佐证）。
                //   按 1280 切行；行内第 m 拍 ↔ 本行像素 m。
                if (rec && line == 3 && m < 10)
                    $display("SOHEAD m=%0d x=%0d pair=%08h got=%06h exp=%06h exp6=%06h",
                             m, u_scanout.px_w, u_scanout.u_play.pair, video_data,
                             exp_pix(line*1280+m, win_show),
                             exp_pix(line*1280+m-6, win_show));
                if (rec && m < 1280) begin
                    got[line*1280 + m] = video_data;
                    ng = ng + 1;
                end
                m = m + 1;
                if (m == 1280) begin m = 0; line = line + 1; end
            end
        end
    end

    // ---- 期望值查内存 ----
    function [23:0] exp_pix(input integer q, input integer win);
        reg [15:0] px;
        reg [31:0] wd;
        begin
            wd = rmem[FB_WIN0 + win*FB_TOTAL + (q >> 1)];
            px = (q[0]) ? wd[31:16] : wd[15:0];
            exp_pix = { px[15:11], px[15:13], px[10:5], px[10:9], px[4:0], px[4:2] };
        end
    endfunction

    integer sh, best_sh, best_mm, mm, ii, jj, errs, lbad;
    integer line_mm [0:1023];
    reg [23:0] e;
    integer win_used;

    initial begin
        rst_n = 0;
        pixel_rst = 1;
        #100;
        pixel_rst = 0;
        rst_n = 1;
        first_win_done = 1;
        while (pass_p < NPASS) @(posedge pixel_clk);
        #1000;

        win_used = win_show;
        // ★ 逐行实测偏移（诊断漂移：常数=正常，逐行变=每行拍数假设错）
        for (jj = 0; jj < 6; jj = jj + 1) begin
            best_mm = 2000000000; best_sh = 0;
            for (sh = 0; sh < 12; sh = sh + 1) begin
                mm = 0;
                for (ii = jj*1280 + 100; ii < jj*1280 + 300; ii = ii + 1) begin
                    e = exp_pix(ii - sh, win_used);
                    if (got[ii] !== e) mm = mm + 1;
                end
                if (mm < best_mm) begin best_mm = mm; best_sh = sh; end
            end
            $display("SOLINESH line=%0d best_sh=%0d mm=%0d", jj, best_sh, best_mm);
        end
        // 移位搜索（前 1000 像素）
        best_mm = 2000000000; best_sh = 0;
        for (sh = 0; sh < 8; sh = sh + 1) begin
            mm = 0;
            for (ii = 100; ii < 1100; ii = ii + 1) begin
                e = exp_pix(ii - sh, win_used);
                if (got[ii] !== e) mm = mm + 1;
            end
            $display("SOSHIFT sh=%0d mm=%0d", sh, mm);
            if (mm < best_mm) begin best_mm = mm; best_sh = sh; end
        end
        // 全量 + 按行
        for (ii = 0; ii < 1024; ii = ii + 1) line_mm[ii] = 0;
        errs = 0;
        for (ii = 3000; ii < ng; ii = ii + 1) begin
            e = exp_pix(ii - best_sh, win_used);
            if (got[ii] !== e) begin
                errs = errs + 1;
                jj = ii / 1280;
                if (jj < 1024) line_mm[jj] = line_mm[jj] + 1;
                if (errs <= 6)
                    $display("SOMM ii=%0d line=%0d got=%06h exp=%06h", ii, jj, got[ii], e);
            end
        end
        lbad = 0;
        for (ii = 0; ii < 1024; ii = ii + 1)
            if (line_mm[ii] > 0) lbad = lbad + 1;
        $display("SOSUM best_sh=%0d mm_sample=%0d errs=%0d ng=%0d nlines_bad=%0d stall=%0d",
                 best_sh, best_mm, errs, ng, lbad, disp_stall);
        for (ii = 0; ii < 6; ii = ii + 1)
            $display("SOLINEMM line=%0d mm=%0d", ii, line_mm[ii]);
        if (errs == 0 && ng >= 921600)
            $display("=== TB-SUMMARY: ALL PASS ===");
        else
            $display("=== TB-SUMMARY: FAIL ===");
        $finish;
    end

    initial begin
        #400000000;
        $display("SO-WATCHDOG pass=%0d ng=%0d", pass_p, ng);
        $display("=== TB-SUMMARY: FAIL (watchdog) ===");
        $finish;
    end
endmodule
