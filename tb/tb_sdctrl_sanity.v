`timescale 1ns/1ps
// tb_sdctrl_sanity.v — vendor SDRAM 控制器 + 行为 shim 的写读回环验证
//
// 关键事实（已从 RTL 与波形核实）：
//   · 控制器 CLK 端口由其内部 sdram_pll1（clk0_out）驱动，TB 不得驱动 CLK。
//   · SC_PM=1 页模式：每个突发只发 1 条 READ/WRITE 命令，随后连续 mLENGTH 拍
//     流式收发（SDRAM 模型已按全页突发实现）。
//   · 写突发启动条件 = 写 FIFO 占用 > AE(127)（wr1_aempty_w 撤销）且 rWR1_LENGTH!=0。
//     → 小于 128 字的写永远不会启动突发；本 TB 每轮 len ≥ 128。
//   · 读端口 RD1 是"连续流"：只要 RD FIFO 未接近满（AF=128）就不断发起突发，
//     地址按 rRD1_LENGTH 递增并在 [RD1_ADDR, RD1_MAX_ADDR) 内回卷。
//     → 读回数据是区域内容的循环序列，本 TB 用"循环连续性"校验。
module tb_sdctrl_sanity;
    reg REF_CLK = 1'b0;   always #10 REF_CLK = ~REF_CLK;    // 50 MHz
    wire CLK;                                              // 控制器内部 PLL 生成 100M

    reg RESET_N = 1'b0;
    reg  [31:0] wr_data;
    reg         WR1 = 1'b0, WR1_LOAD = 1'b0;
    reg  [20:0] WR1_ADDR = 21'd0, WR1_MAX_ADDR = 21'h1FFFF;
    reg  [8:0]  WR1_LENGTH = 9'd0;
    reg         RD1 = 1'b0, RD1_LOAD = 1'b0;
    reg  [20:0] RD1_ADDR = 21'd0, RD1_MAX_ADDR = 21'd256;
    reg  [8:0]  RD1_LENGTH = 9'd256;    // 初值非 0：避免 mLENGTH=0 的退化突发

    wire [31:0] WR1_DATA = wr_data;
    wire [31:0] RD1_DATA;
    wire        RD1_EMPTY, WR1_FULL;
    wire [15:0] WR1_USE, RD1_USE;
    wire [10:0] SA; wire [1:0] BA; wire [1:0] CS_N; wire CKE, RAS_N, CAS_N, WE_N;
    wire [31:0] DQ; wire [3:0] DQM; wire SDR_CLK; wire test_oe;

    // ★ P5：改测板 B 派生控制器副本（= 厂商原件 + P3 修补 + 状态口）——仿真与
    //   综合必须是同一份代码，否则这里全绿也不代表上板用的控制器正确。
    Sdram_Control_4Port_B u_ctrl(
        .REF_CLK(REF_CLK), .RESET_N(RESET_N), .CLK(CLK),
        .WR1_DATA(WR1_DATA), .WR1(WR1), .WR1_ADDR(WR1_ADDR),
        .WR1_MAX_ADDR(WR1_MAX_ADDR), .WR1_LENGTH(WR1_LENGTH), .WR1_LOAD(WR1_LOAD),
        .WR1_CLK(CLK), .WR1_FULL(WR1_FULL), .WR1_USE(WR1_USE),
        .WR2_DATA(32'h0), .WR2(1'b0), .WR2_ADDR(21'd0), .WR2_MAX_ADDR(21'h1FFFF),
        .WR2_LENGTH(9'd0), .WR2_LOAD(1'b0), .WR2_CLK(CLK),
        .WR2_FULL(), .WR2_USE(),
        .RD1_DATA(RD1_DATA), .RD1(RD1), .RD1_ADDR(RD1_ADDR),
        .RD1_MAX_ADDR(RD1_MAX_ADDR), .RD1_LENGTH(RD1_LENGTH), .RD1_LOAD(RD1_LOAD),
        .RD1_CLK(CLK), .RD1_EMPTY(RD1_EMPTY), .RD1_USE(RD1_USE),
        .RD2_DATA(), .RD2(1'b0), .RD2_ADDR(21'd0), .RD2_MAX_ADDR(21'h1FFFF),
        .RD2_LENGTH(9'd0), .RD2_LOAD(1'b0), .RD2_CLK(CLK),
        .RD2_EMPTY(), .RD2_USE(),
        .SA(SA), .BA(BA), .CS_N(CS_N), .CKE(CKE), .RAS_N(RAS_N),
        .CAS_N(CAS_N), .WE_N(WE_N), .DQ(DQ), .DQM(DQM), .SDR_CLK(SDR_CLK),
        .test_oe(test_oe)
    );

    // SDRAM 硬宏（sdram_ip 包装 → EG_PHY_SDRAM_2M_32 行为模型）
    sdram_ip u_sdram_ip(
        .clk(SDR_CLK), .ras_n(RAS_N), .cas_n(CAS_N), .we_n(WE_N),
        .addr(SA), .ba(BA), .dq(DQ), .cs_n(CS_N[0]),
        .dm0(DQM[0]), .dm1(DQM[1]), .dm2(DQM[2]), .dm3(DQM[3]), .cke(CKE)
    );

    // 写突发计数器（观测控制器内部 WR_MASK 上升沿）
    integer wr_bursts = 0;
    reg [1:0] wr_mask_prev = 2'b00;
    always @(posedge CLK) begin
        if ((u_ctrl.WR_MASK != 2'b00) && (wr_mask_prev == 2'b00)) wr_bursts = wr_bursts + 1;
        wr_mask_prev <= u_ctrl.WR_MASK;
    end

    // 引脚级探针：SDR_CLK 沿上采样非 NOP 命令（与 SDRAM 模型同视角）
    integer sdr_edges = 0;
    integer pin_dbg = 0;
    always @(posedge SDR_CLK) begin
        sdr_edges = sdr_edges + 1;
        if ((CS_N[0] === 1'b0) && !(RAS_N && CAS_N && WE_N) &&
            (pin_dbg < 60) && ($time > 300000)) begin
            pin_dbg = pin_dbg + 1;
            $display("[%0t] PIN ras=%b cas=%b we=%b ba=%0d sa=%03h dq=%08h",
                     $time, RAS_N, CAS_N, WE_N, BA, SA, DQ);
        end
    end

    // 读突发头部对齐探针：前 2 个读突发的头 14 拍
    integer rd_probe_bursts = 0;
    reg [1:0] rd_mask_prev = 2'b00;
    integer rd_probe_n = 0;
    always @(posedge CLK) begin
        if ((u_ctrl.RD_MASK != 2'b00) && (rd_mask_prev == 2'b00)) begin
            if ($time > 300000) rd_probe_bursts = rd_probe_bursts + 1;
            rd_probe_n = 0;
        end
        rd_mask_prev <= u_ctrl.RD_MASK;
        if ((u_ctrl.RD_MASK != 2'b00) && (rd_probe_bursts <= 2) &&
            (rd_probe_n < 14) && ($time > 300000)) begin
            rd_probe_n = rd_probe_n + 1;
            $display("[%0t] RDP b=%0d n=%0d ST=%0d OV=%b mDO=%08h DQ=%08h dq_oe=%b oe=%b",
                     $time, rd_probe_bursts, rd_probe_n, u_ctrl.ST, u_ctrl.OUT_VALID,
                     u_ctrl.mDATAOUT, DQ, u_sdram_ip.sdram.dq_oe, u_ctrl.oe);
        end
    end

    // 宏内部流水线转储（首个读突发窗口）
    integer sd_dbg_n = 0;
    always @(posedge SDR_CLK) begin
        if (($time > 308000) && (sd_dbg_n < 30)) begin
            sd_dbg_n = sd_dbg_n + 1;
            $display("[%0t] SD p0=%b/%08h p1=%b/%08h p2=%b/%08h dqoe=%b dqo=%08h rdon=%b cs=%b ras=%b cas=%b we=%b",
                     $time,
                     u_sdram_ip.sdram.p0_v, u_sdram_ip.sdram.p0_d,
                     u_sdram_ip.sdram.p1_v, u_sdram_ip.sdram.p1_d,
                     u_sdram_ip.sdram.p2_v, u_sdram_ip.sdram.p2_d,
                     u_sdram_ip.sdram.dq_oe, u_sdram_ip.sdram.dq_o,
                     u_sdram_ip.sdram.rd_on, CS_N[0], RAS_N, CAS_N, WE_N);
        end
    end

    // z 捕获探针：OUT_VALID 高且 DQ 含 z/x 的拍（即 RD FIFO 即将写入 z）
    integer z_cap = 0;
    always @(posedge CLK) begin
        if ((u_ctrl.OUT_VALID === 1'b1) && (u_ctrl.RD_MASK[0] === 1'b1) &&
            (^DQ === 1'bx) && (z_cap < 8) && ($time > 300000)) begin
            z_cap = z_cap + 1;
            $display("[%0t] ZCAP n=%0d ST=%0d mDO=%08h DQ=%08h dq_oe=%b oe=%b cs=%b ras=%b cas=%b we=%b",
                     $time, z_cap, u_ctrl.ST, u_ctrl.mDATAOUT, DQ,
                     u_sdram_ip.sdram.dq_oe, u_ctrl.oe, CS_N[0], RAS_N, CAS_N, WE_N);
        end
    end

    // 序号后继（区域长度 n 内循环）
    function [7:0] succ_idx;
        input [7:0] v;
        input [8:0] n;
        reg [7:0] t;
        begin
            t = v + 8'd1;
            if ((n != 9'd256) && (t == n[7:0])) t = 8'd0;
            succ_idx = t;
        end
    endfunction

    integer errs = 0;

    // ---- 任务：一轮写+读回 ----
    task one_round(input [20:0] base, input [8:0] len, input [31:0] seed);
        integer i, k, b0;
        reg [31:0] exp, got;
        reg [7:0]  idx, prev_idx;
        reg        have_prev;
        begin
            // ================= 写 =================
            @(posedge CLK);
            WR1_ADDR = base; WR1_MAX_ADDR = base + len;
            WR1_LENGTH = len; WR1_LOAD = 1'b1;
            @(posedge CLK); WR1_LOAD = 1'b0;
            b0 = wr_bursts;
            // 每拍推 1 字（与突发排空同速，FIFO 不欠载）
            for (i = 0; i < len; i = i + 1) begin
                wr_data = seed + i * 32'h01010101;
                WR1 = 1'b1; @(posedge CLK);
            end
            WR1 = 1'b0;
            // 等写突发启动
            k = 0;
            while (wr_bursts == b0 && k < 50000) begin @(posedge CLK); k = k + 1; end
            if (wr_bursts == b0) begin
                errs = errs + 1;
                $display("SANITY-ERR base=%0d: 写突发未启动 (len=%0d)", base, len);
            end
            // 等突发结束
            k = 0;
            while ((u_ctrl.WR_MASK != 2'b00 || u_ctrl.mWR != 1'b0) && k < 50000) begin
                @(posedge CLK); k = k + 1;
            end
            #2000;

            // ================= 读 =================
            @(posedge CLK);
            RD1_ADDR = base; RD1_MAX_ADDR = base + len;
            RD1_LENGTH = len; RD1_LOAD = 1'b1;
            @(posedge CLK); RD1_LOAD = 1'b0;
            // 冲掉 FIFO 中上一轮残留（≤383 字），保证之后全是本区域数据
            for (k = 0; k < 600; k = k + 1) begin
                i = 0;
                while (RD1_EMPTY && i < 5000) begin @(posedge CLK); i = i + 1; end
                RD1 = 1'b1; @(posedge CLK); RD1 = 1'b0;
            end
            // 逐字弹出：值必须命中区域 + 序列循环连续
            // （FIFO do 为 re 采样沿寄存：先发 re，沿后 #1 读 do）
            prev_idx = 8'h00; have_prev = 1'b0;
            for (k = 0; k < len; k = k + 1) begin
                i = 0;
                while (RD1_EMPTY && i < 5000) begin @(posedge CLK); i = i + 1; end
                RD1 = 1'b1; @(posedge CLK); RD1 = 1'b0; #1;
                got = RD1_DATA;
                idx = got[7:0] - seed[7:0];
                exp = seed + idx * 32'h01010101;
                if (idx >= len[7:0] && len != 9'd256) begin
                    errs = errs + 1;
                    if (errs < 20) $display("SANITY-ERR base=%0d k=%0d: got %08h idx=%0d 越界", base, k, got, idx);
                end
                else if (got !== exp) begin
                    errs = errs + 1;
                    if (errs < 20) $display("SANITY-ERR base=%0d k=%0d: got %08h want %08h", base, k, got, exp);
                end
                else if (have_prev && idx !== succ_idx(prev_idx, len)) begin
                    errs = errs + 1;
                    if (errs < 20) $display("SANITY-ERR base=%0d k=%0d: 序列不连续 idx=%0d prev=%0d", base, k, idx, prev_idx);
                end
                prev_idx = idx; have_prev = 1'b1;
            end
            $display("SANITY round base=%0d len=%0d done (突发数=%0d, 累计 errs=%0d)",
                     base, len, wr_bursts - b0, errs);
        end
    endtask

    initial begin
        RESET_N = 1'b0; wr_data = 32'h0;
        repeat (20) @(posedge CLK);
        RESET_N = 1'b1;
        // 等内部 PLL 锁定 + 控制器初始化（INIT_PER 24000 clk = 240µs）
        wait (u_ctrl.sdram_pll1.extlock === 1'b1);
        #300000;
        $display("init done, t=%0t", $time);

        one_round(21'd0,    9'd256, 32'hA000_0000);   // 行0 列0..255
        one_round(21'd512,  9'd256, 32'hC0DE_0000);   // 行2 列0..255
        one_round(21'd1088, 9'd128, 32'h5E00_0000);   // 行4 列64..191

        if (errs == 0) $display("=== TB-SUMMARY: ALL PASS ===");
        else           $display("=== TB-SUMMARY: FAIL (errs=%0d) ===", errs);
        $display("SDR_CLK 沿数=%0d  引脚非NOP命令数=%0d  CS_N=%b", sdr_edges, pin_dbg, CS_N);
        $finish;
    end

    // ---- 看门狗 + 卡点探针 ----
    initial begin
        #4000000;
        $display("=== WATCHDOG TIMEOUT at %0t ===", $time);
        $display("ctrl: CMDACK=%b INIT_REQ=%b REF_REQ=%b CMD=%b",
                 u_ctrl.CMDACK, u_ctrl.control1.INIT_REQ, u_ctrl.control1.REF_REQ,
                 u_ctrl.control1.CMD);
        $display("WR1_USE=%0d RD1_USE=%0d WR1_FULL=%b RD1_EMPTY=%b WR_MASK=%b mWR=%b ST=%0d",
                 WR1_USE, RD1_USE, WR1_FULL, RD1_EMPTY, u_ctrl.WR_MASK, u_ctrl.mWR, u_ctrl.ST);
        $finish;
    end
endmodule
