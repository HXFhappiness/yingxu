// tb_a_sender.v — yx_a_vq_sender 独立验收（A 侧单测）
//
// 判据（只看 GATE / TB-SUMMARY）：
//   1. 流跑完（FSM 回 IDLE、解析器到 PS_DONE）；
//   2. TX 端重组出的 payload 与源 .yxv2 **逐字节一致**；
//   3. 发出的 payload 字节总数 == 源文件字节数（不丢不多）；
//   4. 分片口径：按**窗口**（序幕 + 每帧）分别算期望分片数与短片数，
//      TB 自己解析源文件得出期望值 —— 不硬编码，改流也成立；
//   5. 帧锁存节流：总耗时 ≈ PRO_CYC + 帧数×T_FRAME_CYC（±30%），
//      即"每帧字节摊在一个帧周期内"确实生效（这是 P6 交付物 2 的核心）。
//
// 说明：本测试在**分片接口层**（payload_req/payload_dat）重组，验证发送器自身的
//       分片与喂数逻辑；GMII 上真正进出线的字节由 p6_e2e 端到端验证。
`timescale 1ns/1ps

module tb_a_sender;
    // ★ 单测把周期缩小以加快仿真，但**必须保持 period ≥ 该窗 win_total**
    //   （KEY 体 115,200 / DELTA 体 ≤18,476 / 码本 32,768），否则 Bresenham 的
    //   acc 每拍净增 (win_total − period) 无界溢出。
    localparam integer T_KEY_CYC   = 200000;
    localparam integer T_DELTA_CYC = 100000;
    localparam integer PRO_CYC     = 100000;
    localparam [15:0]  FRAG_LEN    = 16'd1472;

    reg clk125 = 1'b0;
    always #4 clk125 = ~clk125;          // 125MHz

    reg rst_p = 1'b1;

    // ---- 源：从文件按字节喂 ----
    reg  [7:0] smem [0:1048575];
    reg  [7:0] rmem [0:1048575];         // 重组结果
    integer slen, sf, sp, rn;
    reg [255:0] path;

    wire       src_valid;
    reg  [7:0] src_data;
    wire       src_ready;

    wire        gmii_tx_clk;
    wire [7:0]  gmii_txd;
    wire        gmii_txen;
    wire [31:0] tx_byte_cnt;
    wire [15:0] tx_pkt_cnt;
    wire [15:0] tx_short_cnt;
    wire [15:0] tx_frame_cnt;

    yx_a_vq_sender #(
        .T_KEY_CYC   (T_KEY_CYC),
        .T_DELTA_CYC (T_DELTA_CYC),
        .PRO_CYC     (PRO_CYC),
        .FRAG_LEN    (FRAG_LEN)
    ) u_dut (
        .clk125       (clk125),
        .rst_p        (rst_p),
        .src_valid    (src_valid),
        .src_data     (src_data),
        .src_ready    (src_ready),
        .gmii_tx_clk  (gmii_tx_clk),
        .gmii_txd     (gmii_txd),
        .gmii_txen    (gmii_txen),
        .tx_byte_cnt  (tx_byte_cnt),
        .tx_pkt_cnt   (tx_pkt_cnt),
        .tx_short_cnt (tx_short_cnt),
        .tx_frame_cnt (tx_frame_cnt)
    );

    // ================= 源驱动：握手拍预取下一字节 =================
    // ★ 三个坑都在这里踩过：
    //   ① `src_data <= smem[sp]` 且 `sp <= sp+1` 同拍 NBA → 握手拍 DUT 采到的
    //      src_data 还是**上一个**字节（实测整体错位一格：59 59 58 56…）。
    //      解法：握手成功那拍**预取 smem[sp+1]**。
    //   ② `always @(*)` 组合读 1M 条目的 smem → iverilog 卡死（实测）。
    //      解法：寄存驱动，不用 @(*)。
    //   ③ DUT 的 src_data 是**当拍组合取用**（与 eth_udp_tx_gmii 的 FWFT 语义
    //      一致），所以 src_data 必须在 src_valid 拍就已就绪 —— 预取正好保证。
    reg sp_valid;
    always @(posedge clk125) begin
        if (rst_p) begin
            sp       <= 0;
            sp_valid <= 1'b0;
            src_data <= 8'h00;
        end else if (!sp_valid) begin
            sp       <= 0;
            sp_valid <= (slen > 0);
            src_data <= smem[0];
        end else if (src_ready) begin
            if (sp + 1 < slen) begin
                sp       <= sp + 1;
                src_data <= smem[sp + 1];
            end else begin
                sp_valid <= 1'b0;
            end
        end
    end
    assign src_valid = sp_valid;

    // ================= 重组：分片弹出即写 rmem =================
    integer byte_errs = 0;
    always @(posedge clk125) begin
        if (!rst_p && u_dut.frag_pop === 1'b1) begin
            rmem[rn] <= u_dut.frag_head;
            rn <= rn + 1;
        end
    end

    // ================= 期望值：TB 自己解析源文件 =================
    // 窗口 = 序幕(20 + cbn×32) + 每帧(KEY: 5+NB×2 / DELTA: 5+MB+changed×2)
    // 期望分片数 = Σ ceil(win/FRAG_LEN)；期望短片数 = Σ (win % FRAG_LEN != 0)
    integer exp_pkt, exp_short, exp_frames, win_n;
    integer po, pf, pkind, pch, pflen, nbv, mbv, nb2v;
    integer w_tot, w_bytes, exp_cyc_acc;
    integer i;

    // ================= 节流观测 =================
    integer cyc_cnt = 0;
    integer dbg_div = 0;
    always @(posedge clk125) begin
        if (!rst_p) begin
            cyc_cnt = cyc_cnt + 1;
            dbg_div = dbg_div + 1;
            if (dbg_div >= 500000) begin
                dbg_div = 0;
                $display("  TRACE t=%0d ps=%0d win_sent=%0d win_total=%0d st=%0d fcnt=%0d sp=%0d rn=%0d",
                         cyc_cnt, u_dut.ps, u_dut.win_sent, u_dut.win_total,
                         u_dut.st, u_dut.frag_cnt, sp, rn);
            end
        end
    end

    // ================= 解析状态迁移探针（定位窗口边界/帧长） =================
    reg [2:0] ps_q = 3'd0;
    always @(posedge clk125) begin
        if (!rst_p && (u_dut.ps !== ps_q)) begin
            $display("PSTRANS %0d->%0d win_total=%0d win_sent=%0d sp=%0d nf=%0d nb2=%0d mb=%0d body=%0d",
                     ps_q, u_dut.ps, u_dut.win_total, u_dut.win_sent, sp,
                     u_dut.nf_left, u_dut.nb2, u_dut.mb, u_dut.body_len);
            ps_q <= u_dut.ps;
        end
    end

    // ================= 检查 =================
    integer errs = 0, checks = 0;
    task chk;
        input cond;
        input [255:0] name;
        begin
            checks = checks + 1;
            if (!cond) begin errs = errs + 1; $display("  FAIL: %0s", name); end
            else $display("  ok  : %0s", name);
        end
    endtask

    integer g, done_seen, exp_cyc, lo_cyc, hi_cyc;

    initial begin
        $display("=== tb_a_sender: A 侧发送器验收（帧锁存 T_KEY=%0d T_DELTA=%0d PRO=%0d FRAG=%0d）===",
                 T_KEY_CYC, T_DELTA_CYC, PRO_CYC, FRAG_LEN);
        if (!$value$plusargs("STREAM=%s", path)) begin
            $display("TB-ERR: +STREAM 必需"); $finish;
        end
        sf = $fopen(path, "rb");
        if (sf == 0) begin $display("TB-ERR: 打不开 %s", path); $finish; end
        slen = $fread(smem, sf);
        $fclose(sf);
        rn = 0;

        // ---------- 解析源文件，算期望窗口/分片 ----------
        nbv  = (smem[7]  | (smem[8]  << 8)) >> 2;              // W/4
        nbv  = nbv * ((smem[9] | (smem[10] << 8)) >> 2);       // ×(H/4) = NB
        nb2v = nbv * 2;
        mbv  = (nbv + 7) / 8;
        exp_frames = smem[12] | (smem[13] << 8);
        w_tot = 20 + (smem[14] | (smem[15] << 8)) * 32;

        exp_pkt   = (w_tot + FRAG_LEN - 1) / FRAG_LEN;
        exp_short = ((w_tot % FRAG_LEN) != 0) ? 1 : 0;
        $display("TB: stream=%0dB  NB=%0d  MB=%0d  帧数=%0d  序幕=%0dB",
                 slen, nbv, mbv, exp_frames, w_tot);

        po = w_tot;
        w_bytes = w_tot;
        exp_cyc_acc = 0;
        for (pf = 0; pf < exp_frames; pf = pf + 1) begin
            pkind = smem[po];
            pch   = smem[po+1] | (smem[po+2] << 8) | (smem[po+3] << 16);
            if (pkind == 0) pflen = 5 + nb2v;
            else            pflen = 5 + mbv + pch * 2;
            $display("     frame %0d: kind=%0d len=%0d off=%0d", pf, pkind, pflen, po);
            exp_pkt   = exp_pkt + (pflen + FRAG_LEN - 1) / FRAG_LEN;
            exp_short = exp_short + (((pflen % FRAG_LEN) != 0) ? 1 : 0);
            w_bytes   = w_bytes + pflen;
            po        = po + pflen;
            // 帧锁存周期按帧类型累计（KEY 长周期 / DELTA 短周期）
            exp_cyc_acc = exp_cyc_acc + ((pkind == 0) ? T_KEY_CYC : T_DELTA_CYC);
        end
        win_n = exp_frames + 1;
        $display("TB: 期望窗口数=%0d（1 序幕 + %0d 帧）  期望分片=%0d  期望短片=%0d  窗口字节合计=%0d",
                 win_n, exp_frames, exp_pkt, exp_short, w_bytes);
        chk(w_bytes === slen, "TB 自身解析：窗口字节合计 == 文件长度（帧长公式正确）");

        rst_p = 1'b1;
        repeat (5) @(posedge clk125);
        rst_p = 1'b0;

        // ---------- 跑完整条流 ----------
        done_seen = 0;
        for (g = 0; g < 60_000_000; g = g + 1) begin
            @(posedge clk125);
            if (rn >= slen && u_dut.st === 2'd0 && u_dut.ps === 3'd4 && done_seen == 0) begin
                repeat (10) @(posedge clk125);
                if (rn >= slen && u_dut.st === 2'd0) done_seen = 1;
            end
            if (done_seen) g = 60_000_000;
        end
        $display("  DBG slen=%0d 重组字节=%0d 报文=%0d 短片=%0d 帧=%0d clk125=%0d ps=%0d",
                 slen, rn, tx_pkt_cnt, tx_short_cnt, tx_frame_cnt, cyc_cnt, u_dut.ps);

        chk(done_seen === 1, "流跑完（FSM 回 IDLE 且解析器到 PS_DONE）");
        chk(rn === slen, "重组字节数 == 源文件字节数");
        chk(tx_byte_cnt === slen, "tx_byte_cnt == slen");

        // 逐字节比对
        for (i = 0; i < slen; i = i + 1) begin
            if (rmem[i] !== smem[i]) begin
                if (byte_errs < 4)
                    $display("  BYTEMISMATCH i=%0d got=%02h exp=%02h", i, rmem[i], smem[i]);
                byte_errs = byte_errs + 1;
            end
        end
        chk(byte_errs === 0, "payload 与源 .yxv2 逐字节一致");

        // 分片口径（期望值来自 TB 自己解析源文件）
        chk(tx_pkt_cnt   === exp_pkt,   "分片总数 == Σ ceil(窗口/FRAG_LEN)");
        chk(tx_short_cnt === exp_short, "短片数 == 窗口数（每窗口末尾各 1 个残余片）");
        chk(tx_frame_cnt === exp_frames,"摊开完的帧数 == 文件头帧数");

        // 帧锁存节流：总耗时 ≈ PRO_CYC + Σ(按帧类型的周期) + 每包串行开销
        // （S_GAP 70 拍 + 前导/CRC/喂空 ~1500 拍 ≈ 1.6k/包；不加上限会把
        //   S_GAP 修复的真实开销误判成"太慢"）
        exp_cyc = PRO_CYC + exp_cyc_acc + exp_pkt * 1600;
        lo_cyc  = (exp_cyc * 80) / 100;
        hi_cyc  = (exp_cyc * 120) / 100;
        $display("  TIME 实测 %0d clk125，期望 %0d（节流 %0d + %0d 包串行余量），允许 [%0d, %0d]",
                 cyc_cnt, exp_cyc, PRO_CYC + exp_cyc_acc, exp_pkt, lo_cyc, hi_cyc);
        chk((cyc_cnt >= lo_cyc) && (cyc_cnt <= hi_cyc),
            "帧锁存节流生效：KEY/DELTA 按各自周期摊开");

        $display("");
        $display("GATE checks=%0d errs=%0d(want 0:%s)", checks, errs, (errs==0)?"OK":"BAD");
        $display("=== TB-SUMMARY: %s ===", (errs==0) ? "ALL PASS" : "FAIL");
        $finish;
    end

endmodule
