`timescale 1ns/1ps
// tb_eth_rx.v — 板 B 以太网入口独立验收 TB（秒级编译，快速迭代）
//
// 链路：YXV2 文件 → UDP 分包 → GMII 帧发生器（125M）→ yx_b_eth_rx
//       → 字节流（100M，带反压）→ 逐字节对拍源文件
//
// 用例（单次运行全跑）：
//   1) 干净传输：全部包 CRC 正确 → 字节流必须逐字节等于源文件；
//   2) 坏包：第 BAD_IDX 包 FCS 故意写错 → 厂商核 pkt_error → 本层整包丢弃
//      （drop_cnt=1，字节流跳过该包载荷）；
//   3) 错端口：第 PORT_IDX 包 dst_port 错 → 厂商核在 UDP 头阶段丢帧，
//      无 payload、无描述符（字节流同样跳过该包载荷）；
//   4) 广播 MAC：第 BC_IDX 包 dst_mac=FF..FF → 必须被接收（好包）；
//   5) 背压：消费者 ready 有 1/5 拍停顿，验证 FIFO 上游回压/无丢字节。
//
// 判据：cmp_errs=0 且 out_bytes=预期（源文件 − 坏包载荷 − 错端口载荷）
//       且 drop_cnt=1 且 ok_cnt=N−2。
// 说明：本 TB 只验"传输层 → 字节流"的正确性；解码/显示链由 bboard_sys_eth 覆盖。
module tb_eth_rx;

    // ---------------- 时钟 ----------------
    reg gmii_clk = 1'b0;           // 125M（8ns）
    always #4 gmii_clk = ~gmii_clk;
    reg clk100 = 1'b0;             // 100M（10ns）——与 125M 异步（真实 CDC 场景）
    always #5 clk100 = ~clk100;

    reg rst_n = 1'b0;

    // ---------------- DUT ----------------
    localparam [47:0] LOCAL_MAC  = 48'h00_0a_35_02_00_01;
    localparam [31:0] LOCAL_IP   = 32'hc0_a8_00_64;   // 192.168.0.100
    localparam [15:0] LOCAL_PORT = 16'd5000;
    localparam [47:0] SRC_MAC    = 48'h00_0a_35_01_fe_c0;
    localparam [31:0] SRC_IP     = 32'hc0_a8_00_02;   // 192.168.0.2
    localparam [15:0] SRC_PORT   = 16'd5000;

    reg  [7:0] gmii_rxd  = 8'h00;
    reg        gmii_rxdv = 1'b0;

    wire        stream_valid, stream_ready;
    wire [7:0]  stream_data;
    wire [15:0] pkt_ok_cnt, pkt_drop_cnt, fifo_room;
    wire [31:0] byte_cnt;
    wire        rx_clk125;

    // 消费者反压：每 5 拍停 1 拍
    reg  [2:0] rc = 3'd0;
    always @(posedge clk100) rc <= rc + 3'd1;
    wire cmp_ready = (rc != 3'd0);

    yx_b_eth_rx #(
        .USE_RGMII (0),
        .FIFO_AW   (13)
    ) u_dut (
        .clk100        (clk100),
        .rst_n         (rst_n),
        .local_mac     (LOCAL_MAC),
        .local_ip      (LOCAL_IP),
        .local_port    (LOCAL_PORT),
        .gmii_rx_clk   (gmii_clk),
        .gmii_rxd      (gmii_rxd),
        .gmii_rxdv     (gmii_rxdv),
        .rgmii_rx_clk  (1'b0),
        .rgmii_rxd     (4'd0),
        .rgmii_rxdv    (1'b0),
        .stream_valid  (stream_valid),
        .stream_data   (stream_data),
        .stream_ready  (cmp_ready),
        .pkt_ok_cnt    (pkt_ok_cnt),
        .pkt_drop_cnt  (pkt_drop_cnt),
        .byte_cnt      (byte_cnt),
        .fifo_room     (fifo_room),
        .rx_clk125     (rx_clk125)
    );

    // ---------------- 源文件 ----------------
    localparam SMAX = 1024*1024;
    reg  [7:0] smem [0:SMAX-1];
    integer slen = 0;
    reg [255:0] path;

    // ---------------- 参数 ----------------
    integer PLEN    = 1024;        // 每包 UDP 载荷（+PLEN= 覆盖）
    integer BAD_IDX  = 20;         // 坏 CRC 包
    integer PORT_IDX = 30;         // 错端口包
    integer BC_IDX   = 10;         // 广播 MAC 包（好包）
    integer NPKT = 0;

    // ---------------- 帧缓冲 ----------------
    localparam FMAX = 2048;
    reg [7:0] fb [0:FMAX-1];

    // ---------------- 期望比对 ----------------
    integer exp_p   = 0;           // 源文件期望偏移
    integer out_bytes = 0;
    integer cmp_errs  = 0;
    integer holes_from [0:7];
    integer holes_len  [0:7];
    integer nh = 0;
    integer kk, moved;
    integer badexp = 0;            // 坏包载荷长度（用于报告）

    wire [7:0] s_data_unused = stream_data;   // 仅避免"未使用"提示

    // ---------------- 记录"洞"（不进入字节流的载荷）----------------
    task add_hole(input integer off, input integer len);
    begin
        holes_from[nh] = off;
        holes_len[nh]  = len;
        nh = nh + 1;
    end
    endtask

    // 期望指针跳过洞
    task skip_holes;
        integer k;
        begin
            moved = 1;
            while (moved) begin
                moved = 0;
                for (k = 0; k < nh; k = k + 1) begin
                    if (exp_p >= holes_from[k] && exp_p < holes_from[k] + holes_len[k]) begin
                        exp_p = holes_from[k] + holes_len[k];
                        moved = 1;
                    end
                end
            end
        end
    endtask

    // ---------------- 字节比对 ----------------
    always @(posedge clk100) begin
        if (rst_n && stream_valid && cmp_ready) begin
            skip_holes;
            if (exp_p < slen) begin
                if (stream_data !== smem[exp_p]) begin
                    cmp_errs = cmp_errs + 1;
                    if (cmp_errs <= 8)
                        $display("ETHCMP-ERR out=%0d exp[%0d]=%02h got=%02h",
                                 out_bytes, exp_p, smem[exp_p], stream_data);
                end
                exp_p = exp_p + 1;
            end else begin
                cmp_errs = cmp_errs + 1;
                if (cmp_errs <= 8) $display("ETHCMP-ERR 多余字节 out=%0d", out_bytes);
            end
            out_bytes = out_bytes + 1;
        end
    end

    // ---------------- 发送侧 CRC（复用厂商件，保证与 RX 同口径）----------------
    reg  [7:0]  txcrc_dat = 8'h00;
    reg         txcrc_en  = 1'b0;
    reg         txcrc_init = 1'b0;
    wire [31:0] txcrc_val;

    crc32_d8 u_txcrc (
        .clk        (gmii_clk),
        .reset_p    (1'b0),
        .data       (txcrc_dat),
        .crc_init   (txcrc_init),
        .crc_en     (txcrc_en),
        .crc_result (txcrc_val)
    );

    // ---------------- GMII 驱动基元 ----------------
    task gmii_byte(input [7:0] b);
    begin
        @(negedge gmii_clk);
        gmii_rxdv = 1'b1;
        gmii_rxd  = b;
    end
    endtask

    task gmii_idle(input integer n);
        integer i;
        begin
            @(negedge gmii_clk);
            gmii_rxdv = 1'b0;
            gmii_rxd  = 8'h00;
            for (i = 0; i < n; i = i + 1) @(negedge gmii_clk);
        end
    endtask

    // ---------------- 帧发送 ----------------
    integer ipid  = 0;

    task send_pkt(input integer off, input integer len,
                  input integer bad, input integer wrongport, input integer bcast);
        integer i;
        reg [15:0] tot, id16, udplen;
        reg [31:0] suma, sumb;
        reg [15:0] sumc, ipck;
        reg [31:0] fcs;
        reg [47:0] dmac;
        reg [15:0] dport;
        begin
            tot   = 16'd20 + 16'd8 + len[15:0];
            id16  = ipid[15:0]; ipid = ipid + 1;
            udplen = 16'd8 + len[15:0];
            dmac  = bcast ? 48'hff_ff_ff_ff_ff_ff : LOCAL_MAC;
            dport = wrongport ? (LOCAL_PORT + 16'd1) : LOCAL_PORT;

            // ---- Eth 头 ----
            for (i = 0; i < 6; i = i + 1) fb[i] = dmac  >> (8*(5-i));
            for (i = 0; i < 6; i = i + 1) fb[6+i] = SRC_MAC >> (8*(5-i));
            fb[12] = 8'h08; fb[13] = 8'h00;
            // ---- IP 头 ----
            fb[14] = 8'h45; fb[15] = 8'h00;
            fb[16] = tot[15:8]; fb[17] = tot[7:0];
            fb[18] = id16[15:8]; fb[19] = id16[7:0];
            fb[20] = 8'h40; fb[21] = 8'h00;          // DF
            fb[22] = 8'd64; fb[23] = 8'h11;          // TTL / UDP
            // 校验和（与 ip_checksum.v 同公式）
            suma = 32'h0000_4500 + tot + id16 + 32'h0000_4000 +
                   32'h0000_4011 + SRC_IP[31:16] + SRC_IP[15:0] +
                   LOCAL_IP[31:16] + LOCAL_IP[15:0];
            sumb = suma[31:16] + suma[15:0];
            sumc = sumb[16] + sumb[15:0];
            ipck = ~sumc;
            fb[24] = ipck[15:8]; fb[25] = ipck[7:0];
            for (i = 0; i < 4; i = i + 1) fb[26+i] = SRC_IP   >> (8*(3-i));
            for (i = 0; i < 4; i = i + 1) fb[30+i] = LOCAL_IP >> (8*(3-i));
            // ---- UDP 头 ----
            fb[34] = SRC_PORT[15:8]; fb[35] = SRC_PORT[7:0];
            fb[36] = dport[15:8];    fb[37] = dport[7:0];
            fb[38] = udplen[15:8];   fb[39] = udplen[7:0];
            fb[40] = 8'h00; fb[41] = 8'h00;          // UDP 校验和=0（厂商核不查）
            // ---- 载荷 ----
            for (i = 0; i < len; i = i + 1) fb[42+i] = smem[off+i];

            // ---- FCS：用厂商同一 CRC 件算（口径一致，无约定歧义）----
            // ★ 脉冲必须跨过时钟沿的 delta：`sig=1; @(posedge); sig=0;` 中
            //   "=0" 可能与 DUT always 块竞争（沿处理前就撤销）→ 寄存器永不
            //   初始化/累加（实测 reg=xxxx）。#1 让沿处理先完成。
            txcrc_init = 1'b1;
            @(posedge gmii_clk); #1;
            txcrc_init = 1'b0;
            for (i = 0; i < 42 + len; i = i + 1) begin
                txcrc_dat = fb[i]; txcrc_en = 1'b1;
                @(posedge gmii_clk); #1;
            end
            txcrc_en = 1'b0;
            @(posedge gmii_clk); #1;                 // 让末字节 CRC 结果稳定
            fcs = txcrc_val;
            if (bad) fcs = fcs ^ 32'h0000_0001;      // 故意破坏 FCS

            // ---- 上线路（前导 7×55 + SFD D5 + 帧 + FCS，LSB 字节先发）----
            for (i = 0; i < 7; i = i + 1) gmii_byte(8'h55);
            gmii_byte(8'hD5);
            for (i = 0; i < 42 + len; i = i + 1) gmii_byte(fb[i]);
            gmii_byte(fcs[7:0]);
            gmii_byte(fcs[15:8]);
            gmii_byte(fcs[23:16]);
            gmii_byte(fcs[31:24]);
            gmii_idle(12);                            // IFG
        end
    endtask

    // ---------- CRC 件自检（+CRCTEST：隔离任务/实例问题）----------
    initial begin : crctest
        integer j;
        if ($test$plusargs("CRCTEST")) begin
            repeat (10) @(posedge gmii_clk);
            txcrc_init = 1'b1;
            @(posedge gmii_clk); #1;
            txcrc_init = 1'b0;
            #1 $display("CRCTEST init: reg=%08h val=%08h", u_txcrc.crc_result_o, txcrc_val);
            for (j = 0; j < 4; j = j + 1) begin
                txcrc_dat = 8'h11 * (j + 1); txcrc_en = 1'b1;
                @(posedge gmii_clk);
            end
            txcrc_en = 1'b0; @(posedge gmii_clk); #1;
            $display("CRCTEST 4B: reg=%08h val=%08h", u_txcrc.crc_result_o, txcrc_val);
            $finish;
        end
    end

    // ---------------- 主流程 ----------------
    integer pi, poff, plen_cur;
    integer exp_total;

    initial begin
        if (!$value$plusargs("STREAM=%s", path)) begin
            $display("TB-ERR: +STREAM 必需"); $finish;
        end
        if (!$value$plusargs("PLEN=%d", PLEN)) PLEN = 1024;

        if ($test$plusargs("NOINJECT")) begin
            BAD_IDX = -1; PORT_IDX = -1;      // 纯干净流（可选）
        end

        begin : load
            integer sf;
            sf = $fopen(path, "rb");
            if (sf == 0) begin $display("TB-ERR: 打不开 %s", path); $finish; end
            slen = $fread(smem, sf);
            $fclose(sf);
        end
        $display("TB: stream=%0dB PLEN=%0d", slen, PLEN);

        NPKT = (slen + PLEN - 1) / PLEN;
        $display("TB: packets=%0d bad_idx=%0d port_idx=%0d bc_idx=%0d",
                 NPKT, BAD_IDX, PORT_IDX, BC_IDX);

        rst_n = 1'b0;
        repeat (40) @(posedge clk100);
        rst_n = 1'b1;
        repeat (400) @(posedge clk100);     // 厂商核 IDLE 锁配置

        // 发送（按 DUT room 节流；等价于"按消费能力发送"的发送端）
        for (pi = 0; pi < NPKT; pi = pi + 1) begin
            poff = pi * PLEN;
            plen_cur = (poff + PLEN <= slen) ? PLEN : (slen - poff);

            // 等 FIFO 有足够空间（125M 域观测）
            while (fifo_room < (plen_cur + 128)) @(negedge gmii_clk);

            if (pi == BAD_IDX)  add_hole(poff, plen_cur);
            if (pi == PORT_IDX) add_hole(poff, plen_cur);

            send_pkt(poff, plen_cur,
                     (pi == BAD_IDX),
                     (pi == PORT_IDX),
                     (pi == BC_IDX));

            if (pi % 50 == 0 || pi == NPKT-1)
                $display("PKT %0d/%0d off=%0d len=%0d room=%0d", pi, NPKT-1, poff, plen_cur, fifo_room);
        end

        // 等消费完
        exp_total = slen;
        for (kk = 0; kk < nh; kk = kk + 1) exp_total = exp_total - holes_len[kk];

        while ((out_bytes < exp_total) && ($time < 40000000)) @(posedge clk100);
        repeat (200) @(posedge clk100);

        $display("ETHRX sent_pkts=%0d out_bytes=%0d exp_bytes=%0d cmp_errs=%0d",
                 NPKT, out_bytes, exp_total, cmp_errs);
        $display("ETHRX ok=%0d drop=%0d byte_cnt=%0d (want ok=%0d drop=1)",
                 pkt_ok_cnt, pkt_drop_cnt, byte_cnt, NPKT-2);
        $display("=== TB-SUMMARY: %s ===",
                 ((cmp_errs == 0) && (out_bytes == exp_total) &&
                  (pkt_drop_cnt == 16'd1) && (pkt_ok_cnt == NPKT-2) &&
                  (byte_cnt == exp_total)) ? "ALL PASS" : "FAIL");
        $finish;
    end

    // 看门狗
    initial begin
        #50000000;
        $display("=== WATCHDOG: out_bytes=%0d exp=%0d cmp_errs=%0d drops=%0d ===",
                 out_bytes, exp_total, cmp_errs, pkt_drop_cnt);
        $display("=== TB-SUMMARY: FAIL (watchdog) ===");
        $finish;
    end

endmodule
