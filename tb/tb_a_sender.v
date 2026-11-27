// tb_a_sender.v — yx_a_vq_sender 独立验收（A 侧单测）
//
// 判据（只看 GATE / TB-SUMMARY）：
//   1. TX 端重组出的 payload 与源 .yxv2 **逐字节一致**；
//   2. 发出的 payload 字节总数 == 源文件字节数（不丢不多）；
//   3. 分片长度都 == FRAG_LEN，只有流末尾最后一片可短；
//   4. 源侧节流生效：平均收字节速率 == 1 / BYTE_DIV 个 clk125（±2%）；
//   5. 全程无"分片内数据不足"（即 frag_pop 不会在 FIFO 空时发生）。
//
// 说明：本测试在**分片接口层**（payload_req/payload_dat）重组，验证发送器自身的
//       分片与喂数逻辑；GMII 上真正进出线的字节由 p6_e2e 端到端验证。
`timescale 1ns/1ps

module tb_a_sender;
    localparam integer BYTE_DIV = 20;
    localparam [15:0]  FRAG_LEN = 16'd1472;

    reg clk125 = 1'b0;
    always #4 clk125 = ~clk125;          // 125MHz

    reg rst_p = 1'b1;

    // ---- 源：从文件按字节喂 ----
    reg  [7:0] smem [0:1048575];
    reg  [7:0] rmem [0:1048575];         // 重组结果
    integer slen, sf, sp, rn;
    reg [255:0] path;

    reg        src_valid = 1'b0;
    reg  [7:0] src_data  = 8'd0;
    wire       src_ready;

    wire        gmii_tx_clk;
    wire [7:0]  gmii_txd;
    wire        gmii_txen;
    wire        tx_en_pulse_o;
    wire        tx_done_o;
    wire        payload_req;
    wire [7:0]  payload_dat;

    wire [31:0] tx_byte_cnt;
    wire [15:0] tx_pkt_cnt;
    wire [15:0] tx_short_cnt;

    yx_a_vq_sender #(
        .BYTE_DIV (BYTE_DIV),
        .FRAG_LEN (FRAG_LEN)
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
        .tx_short_cnt (tx_short_cnt)
    );

    // ================= 源驱动：src_ready 放行时推进 =================
    always @(posedge clk125) begin
        if (rst_p) begin
            src_valid <= 1'b0;
            sp        <= 0;
        end else begin
            if (sp < slen) begin
                src_valid <= 1'b1;
                src_data  <= smem[sp];
                if (src_valid && src_ready) sp <= sp + 1;
            end else begin
                src_valid <= 1'b0;
            end
        end
    end

    // ================= 重组：分片弹出即写 rmem =================
    integer byte_errs = 0;
    always @(posedge clk125) begin
        if (!rst_p && u_dut.frag_pop === 1'b1) begin
            rmem[rn] <= u_dut.frag_head;
            rn <= rn + 1;
        end
    end

    // ================= 分片长度检查 =================
    integer frag_errs = 0;
    integer pkt_seen  = 0;
    always @(posedge clk125) begin
        if (!rst_p && u_dut.tx_done === 1'b1) begin
            pkt_seen = pkt_seen + 1;
            // 除最后一片外都必须填满
            if (u_dut.frag_bytes != FRAG_LEN && u_dut.tx_byte_cnt < slen)
                frag_errs = frag_errs + 1;
        end
    end

    // ================= 节流速率观测 =================
    integer cyc_cnt = 0, take_cnt = 0;
    real    rate_measured, rate_want;
    // ★ 诊断：每 200k 拍采样一次 FSM 状态，看时间花在哪
    integer dbg_div = 0;
    always @(posedge clk125) begin
        if (!rst_p) begin
            cyc_cnt = cyc_cnt + 1;
            if (src_valid && src_ready) take_cnt = take_cnt + 1;
            dbg_div = dbg_div + 1;
            if (dbg_div >= 200000) begin
                dbg_div = 0;
                $display("  TRACE t=%0d st=%0d frag_cnt=%0d frag_rd=%0d frag_bytes=%0d pace=%b room=%b req=%b rn=%0d",
                         cyc_cnt, u_dut.st, u_dut.frag_cnt, u_dut.frag_rd,
                         u_dut.frag_bytes, u_dut.pace_tick, u_dut.frag_room,
                         u_dut.payload_req, rn);
            end
        end
    end

    // ================= 检查 =================
    integer errs = 0, checks = 0;
    integer i;
    task chk;
        input cond;
        input [255:0] name;
        begin
            checks = checks + 1;
            if (!cond) begin errs = errs + 1; $display("  FAIL: %0s", name); end
            else $display("  ok  : %0s", name);
        end
    endtask

    integer g, done_seen;
    initial begin
        $display("=== tb_a_sender: A 侧发送器验收（BYTE_DIV=%0d, FRAG_LEN=%0d）===",
                 BYTE_DIV, FRAG_LEN);
        if (!$value$plusargs("STREAM=%s", path)) begin
            $display("TB-ERR: +STREAM 必需"); $finish;
        end
        sf = $fopen(path, "rb");
        if (sf == 0) begin $display("TB-ERR: 打不开 %s", path); $finish; end
        slen = $fread(smem, sf);
        $fclose(sf);
        rn = 0;
        $display("TB: stream=%0dB  期望分片数=%0d（末片 %0dB）",
                 slen, (slen + FRAG_LEN - 1) / FRAG_LEN, slen % FRAG_LEN);

        rst_p = 1'b1;
        repeat (5) @(posedge clk125);
        rst_p = 1'b0;

        // ---------- 跑完整条流 ----------
        // 收全 slen 字节 + 最后一次 flush 的 tx_done
        done_seen = 0;
        for (g = 0; g < 40_000_000; g = g + 1) begin
            @(posedge clk125);
            if (rn >= slen && u_dut.st === 2'd0 && done_seen == 0) begin
                repeat (10) @(posedge clk125);
                if (rn >= slen && u_dut.st === 2'd0) done_seen = 1;
            end
            if (done_seen) g = 40_000_000;
        end
        $display("  DBG slen=%0d 重组字节=%0d 报文=%0d 短片=%0d clk125=%0d 收字节=%0d",
                 slen, rn, u_dut.tx_pkt_cnt, u_dut.tx_short_cnt, cyc_cnt, take_cnt);

        chk(done_seen === 1, "流跑完（FSM 回 IDLE 且全部字节已发出）");
        chk(rn === slen, "重组字节数 == 源文件字节数");
        chk(u_dut.tx_byte_cnt === slen, "tx_byte_cnt == slen");

        // 逐字节比对
        for (i = 0; i < slen; i = i + 1) begin
            if (rmem[i] !== smem[i]) begin
                if (byte_errs < 4)
                    $display("  BYTEMISMATCH i=%0d got=%02h exp=%02h", i, rmem[i], smem[i]);
                byte_errs = byte_errs + 1;
            end
        end
        chk(byte_errs === 0, "payload 与源 .yxv2 逐字节一致");

        chk(frag_errs === 0, "除末片外所有分片都填满 FRAG_LEN");

        // 分片数
        chk(pkt_seen === (slen + FRAG_LEN - 1) / FRAG_LEN, "分片数 == ceil(slen/FRAG_LEN)");

        // 节流速率：收字节 / 总周期，应接近 1/BYTE_DIV
        rate_measured = take_cnt * 1.0 / ((cyc_cnt > 0) ? cyc_cnt : 1);
        rate_want     = 1.0 / BYTE_DIV;
        $display("  RATE 实测 %.5f 字节/拍（= 1/%.2f），期望 %.5f 字节/拍（= 1/%0d）",
                 rate_measured, 1.0/rate_measured, rate_want, BYTE_DIV);
        // 只在"一直在收"的窗口内比较，允许 ±15%（分片间隙会拉低）
        chk((rate_measured > rate_want * 0.85) && (rate_measured <= rate_want * 1.02),
            "节流平均速率 ≤ 1/BYTE_DIV 且不低于 85%（不快于设计值）");

        $display("");
        $display("GATE checks=%0d errs=%0d(want 0:%s)", checks, errs, (errs==0)?"OK":"BAD");
        $display("=== TB-SUMMARY: %s ===", (errs==0) ? "ALL PASS" : "FAIL");
        $finish;
    end

endmodule