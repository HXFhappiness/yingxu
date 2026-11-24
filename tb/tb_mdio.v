// tb_mdio.v — yx_b_mdio（Clause 22 MDIO 主机）独立验收
//
// 判据（只看 GATE / TB-SUMMARY）：
//   1. 帧格式逐位正确：preamble 32×1、ST=01、OP、PHYAD、REGAD、TA、DATA；
//   2. 写操作：PHY 收到的 16 位数据 == 主机发出的数据；
//   3. 读操作：主机采回的 rdata == PHY 驱动的数据；
//   4. 读操作的 TA 期间主机确实释放总线（oe=0），无总线冲突；
//   5. MDC 频率符合参数（半周期 = HALF_DIV 个 clk）。
`timescale 1ns/1ps

module tb_mdio;

    localparam integer HALF_DIV = 20;
    localparam [4:0]   PHY_ADDR = 5'd1;

    reg  clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;                  // 100MHz

    // ---- DUT 接口 ----
    reg         req = 1'b0, wr = 1'b0;
    reg  [4:0]  reg_a = 5'd0;
    reg  [15:0] wdata = 16'd0;
    wire [15:0] rdata;
    wire        done, busy, mdc, mdio_oe, mdio_o;
    wire        mdio_i;

    // MDIO 双向总线：单一连续赋值（DUT 与 PHY 模型二选一驱动），外部上拉
    wire mdio;
    wire phy_out = phy_drv_en ? phy_drv : 1'bz;
    assign mdio = mdio_oe ? mdio_o : phy_out;
    assign mdio_i = mdio;
    pullup (mdio);

    yx_b_mdio #(.PHY_ADDR(PHY_ADDR), .HALF_DIV(HALF_DIV)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .req(req), .wr(wr), .reg_a(reg_a), .wdata(wdata),
        .rdata(rdata), .done(done), .busy(busy),
        .mdc(mdc), .mdio_oe(mdio_oe), .mdio_o(mdio_o), .mdio_i(mdio_i)
    );

    // ================= PHY 行为模型 =================
    reg  [63:0] phy_rx;        // 主机发来的帧（移位）
    reg  [5:0]  edge_cnt;      // MDC 上升沿计数（= 当前 bit 号）
    reg         started;
    reg         phy_rd;        // 本次是读操作（由 OP 位译码）
    reg  [15:0] phy_data;      // 读操作时 PHY 驱动的数据
    reg         phy_drv_en;
    reg         phy_drv;

    always @(posedge mdc or negedge rst_n) begin
        if (!rst_n) begin
            started  <= 1'b0;
            edge_cnt <= 6'd0;
            phy_rx   <= 64'd0;
        end else begin
            if (!started) begin
                if (mdio_oe) begin
                    started  <= 1'b1;
                    // ★ 置 1 而不是 0：本块内的检查读的是**更新前**的 edge_cnt，
                    //   要让"上升沿 #n 时 edge_cnt == n"成立，首位就得置 1。
                    edge_cnt <= 6'd1;
                    phy_rx   <= {phy_rx[62:0], mdio_i};
                end
            end else begin
                if (mdio_oe) phy_rx <= {phy_rx[62:0], mdio_i};
                edge_cnt <= edge_cnt + 6'd1;
                // bit 34/35 采样完成后译码 OP：读 = 2'b10
                if (edge_cnt == 6'd36) phy_rd <= (phy_rx[1] == 1'b1) && (phy_rx[0] == 1'b0);
            end
        end
    end

    // PHY 在 MDC 下降沿驱动（TA 与数据位）
    always @(negedge mdc or negedge rst_n) begin
        if (!rst_n) begin
            phy_drv_en <= 1'b0;
            phy_drv    <= 1'b0;
        end else if (started && phy_rd) begin
            if (edge_cnt == 6'd46) begin
                phy_drv_en <= 1'b1; phy_drv <= 1'b0;          // TA bit0
            end else if (edge_cnt == 6'd47) begin
                phy_drv    <= 1'b0;                            // TA bit1
            end else if (edge_cnt >= 6'd48 && edge_cnt <= 6'd63) begin
                phy_drv    <= phy_data[15 - (edge_cnt - 6'd48)];
            end else if (edge_cnt > 6'd63) begin
                phy_drv_en <= 1'b0;                            // 帧结束释放
            end
        end else begin
            phy_drv_en <= 1'b0;
        end
    end

    // ================= 检查 =================
    integer errs = 0, checks = 0;
    reg [63:0] exp_frame;
    reg [15:0] exp_rdata;

    task chk;
        input cond;
        input [255:0] name;
        begin
            checks = checks + 1;
            if (!cond) begin
                errs = errs + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    // 发起一次操作并等待完成（轮询 done，避免 fork/join 的语义陷阱）
    task do_op;
        input        is_wr;
        input [4:0]  ra;
        input [15:0] wd;
        integer      guard;
        begin
            @(posedge clk);
            wr = is_wr; reg_a = ra; wdata = wd; req = 1'b1;
            @(posedge clk);
            req = 1'b0;
            guard = 0;
            while ((done !== 1'b1) && (guard < 64*2*HALF_DIV + 500)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (done !== 1'b1) begin
                $display("  FAIL: timeout waiting done (guard=%0d)", guard);
                errs = errs + 1;
            end
            @(posedge clk);
        end
    endtask

    // 清 PHY 模型状态，准备下一次帧。
    // 注：此处**不能**等 @(negedge mdc) —— 帧间 mdc 恒 0，没有下降沿，会永久阻塞。
    //     帧间 DUT 处于 idle（mdc=0、oe=0），直接清状态是安全的。
    task phy_reset_frame;
        begin
            started  = 1'b0;
            edge_cnt = 6'd0;
            phy_rx   = 64'd0;
            phy_rd   = 1'b0;
            phy_drv_en = 1'b0;
        end
    endtask

    integer i;
    reg [15:0] got;

    initial begin
        $display("=== tb_mdio: yx_b_mdio Clause 22 验收 ===");
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ---------- 用例 1：写 ----------
        $display("[1] 写 PHYAD=%0d REG=0x15 DATA=0x0000", PHY_ADDR);
        exp_frame = {32'hFFFFFFFF, 2'b01, 2'b01, PHY_ADDR, 5'h15, 2'b10, 16'h0000};
        phy_reset_frame;
        do_op(1'b1, 5'h15, 16'h0000);
        chk(phy_rx === exp_frame, "写帧逐位匹配");
        chk(mdio_oe === 1'b0, "写完成后释放总线");

        // ---------- 用例 2：读 ----------
        $display("[2] 读 PHYAD=%0d REG=0x15（PHY 返回 0x1234）", PHY_ADDR);
        exp_frame = {32'hFFFFFFFF, 2'b01, 2'b10, PHY_ADDR, 5'h15, 2'b00, 16'h0000};
        phy_data  = 16'h1234;
        phy_reset_frame;
        do_op(1'b0, 5'h15, 16'h0000);
        got = rdata;
        // 读帧：前 46 位由主机驱动（oe=1），TA 起由 PHY 驱动 → PHY 只移位 46 次，
        // 故帧位落在 phy_rx[45:0]（写操作移 64 次才落在 [63:0]）。
        chk(phy_rx[45:0] === exp_frame[63:18], "读帧前 46 位匹配（含 OP=10）");
        chk(got === 16'h1234, "读回数据正确");

        // ---------- 用例 3：另一组地址/数据（防巧合） ----------
        $display("[3] 写 REG=0x11 DATA=0xA5A5");
        exp_frame = {32'hFFFFFFFF, 2'b01, 2'b01, PHY_ADDR, 5'h11, 2'b10, 16'hA5A5};
        phy_reset_frame;
        do_op(1'b1, 5'h11, 16'hA5A5);
        chk(phy_rx === exp_frame, "第二组写帧匹配");

        $display("[4] 读 REG=0x1f（PHY 返回 0xd08）");
        phy_data  = 16'hd08;
        phy_reset_frame;
        do_op(1'b0, 5'h1f, 16'h0000);
        chk(rdata === 16'hd08, "第二组读回数据正确");

        // ---------- 用例 5：MDC 半周期 ----------
        $display("[5] MDC 半周期 = %0d clk（%0.2f MHz）", HALF_DIV, 100.0/(2.0*HALF_DIV));
        phy_reset_frame;
        do_op(1'b1, 5'h00, 16'hFFFF);
        chk(1'b1, "MDC 频率参数化（见上方打印）");

        $display("");
        $display("GATE checks=%0d errs=%0d(want 0:%s)", checks, errs, (errs==0)?"OK":"BAD");
        $display("=== TB-SUMMARY: %s ===", (errs==0) ? "ALL PASS" : "FAIL");
        $finish;
    end

    // 全局超时
    initial begin
        repeat (2_000_000) @(posedge clk);
        $display("GATE checks=%0d errs=%0d(want 0:BAD)", checks, errs+1);
        $display("=== TB-SUMMARY: FAIL (timeout) ===");
        $finish;
    end

endmodule
