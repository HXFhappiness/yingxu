// tb_phy_init.v — yx_b_phy_init（RTL8211F 上电配置序列）独立验收
//
// 判据（只看 GATE / TB-SUMMARY）：
//   1. 序列按序执行：写页 0xd08 → 读 0x15 → 写 0x15(清 bit3) → 页回 0；
//   2. 序列结束后 PHY 模型里 RXCR 的 bit3 == 0（RX 延时确实被关掉）；
//   3. RXCR 的其他位不被破坏（读-改-写）；
//   4. PHY 未响应（读回全 1）时**跳过写**，不把垃圾写进 PHY；
//   5. 结束时页选择回到 0（不留在扩展页）。
`timescale 1ns/1ps

module tb_phy_init;

    localparam integer HALF_DIV = 20;
    localparam [4:0]   PHY_ADDR = 5'd1;
    localparam [15:0]  RGMII_PAGE = 16'hd08;
    localparam [4:0]   RXCR_REG = 5'h15;
    localparam [4:0]   PAGE_REG = 5'h1f;

    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;                 // 100MHz

    // ---- MDIO 主机 <-> 配置序列 ----
    wire        req, wr, done, busy;
    wire [4:0]  reg_a;
    wire [15:0] wdata, rdata;
    wire        mdc, mdio_oe, mdio_o, mdio_i;
    wire [15:0] rxcr_r;
    wire        cfg_done, cfg_skip;

    wire mdio;
    wire phy_out = phy_drv_en ? phy_drv : 1'bz;
    assign mdio = mdio_oe ? mdio_o : phy_out;
    assign mdio_i = mdio;
    pullup (mdio);

    yx_b_mdio #(.PHY_ADDR(PHY_ADDR), .HALF_DIV(HALF_DIV)) u_mdio (
        .clk(clk), .rst_n(rst_n),
        .req(req), .wr(wr), .reg_a(reg_a), .wdata(wdata),
        .rdata(rdata), .done(done), .busy(busy),
        .mdc(mdc), .mdio_oe(mdio_oe), .mdio_o(mdio_o), .mdio_i(mdio_i)
    );

    yx_b_phy_init #(
        .PHY_ADDR(PHY_ADDR), .RGMII_PAGE(RGMII_PAGE),
        .RXCR_REG(RXCR_REG), .RX_DLY_MASK(16'h0008),
        .PAGE_REG(PAGE_REG), .PHY_INIT_WAIT(24'd50)
    ) u_init (
        .clk(clk), .rst_n(rst_n),
        .req(req), .wr(wr), .reg_a(reg_a), .wdata(wdata),
        .rdata(rdata), .done(done), .busy(busy),
        .rxcr_r(rxcr_r), .cfg_done(cfg_done), .cfg_skip(cfg_skip)
    );

    // ================= PHY 行为模型（带寄存器文件）=================
    reg  [15:0] regs_p0    [0:31];   // 页 0
    reg  [15:0] regs_rgmii [0:31];   // 页 0xd08
    reg  [15:0] cur_page;
    reg         phy_alive = 1'b1;    // 0 = 模拟"PHY 不响应"

    reg         frame_started;        // 已检测到 preamble，处于帧内
    reg  [63:0] phy_rx;
    reg  [6:0]  edge_cnt;            // ★ 7 位：帧尾要能表示 64（6 位会回绕成 0，
                                     //   使 `edge_cnt > 63` 的释放分支永不成立）
    reg  [5:0]  ones_cnt;            // 连续采样到 1 的个数（preamble 检测）
    reg         phy_drv_en;
    reg         phy_drv;
    reg  [15:0] rd_val;              // 本次读要驱动的值
    reg         frame_is_rd;
    reg  [4:0]  frame_rega;
    reg  [4:0]  frame_phya;
    reg  [15:0] frame_data;
    integer     wr_cnt = 0, rd_cnt = 0;   // 观测：写/读次数

    // ★ 帧开始检测用 **preamble**（连续 ≥32 个 1 后遇到 0 = ST 首位），
    //   不能用 mdio_oe 的沿——mdio_oe 只在 MDC 沿之间变化，靠 MDC 域采样会漏掉，
    //   导致 edge_cnt 跨帧累加（实测 192 mod 64 = 0，译码条件永不命中）。
    //
    // ★ edge_cnt 必须**无条件**递增（只要帧已开始），不能整个块都套在 mdio_oe 里：
    //   读操作从 TA（bit46）起主机释放总线（mdio_oe=0），若计数器同时冻住，
    //   PHY 端 `edge_cnt 48..63` 的数据驱动条件永不成立，读回值恒为 0
    //   （实测 rxcr_r=0000 而非 0x1238，进而把 RXCR 其他位全部写成 0）。
    always @(posedge mdc or negedge rst_n) begin
        if (!rst_n) begin
            edge_cnt      <= 7'd0;
            ones_cnt      <= 6'd0;
            phy_rx        <= 64'd0;
            frame_is_rd   <= 1'b0;
            frame_started <= 1'b0;
        end else begin
            // ---- 采样：只有主机驱动总线（oe=1）的位才进移位寄存器 ----
            if (mdio_oe) begin
                phy_rx   <= {phy_rx[62:0], mdio_i};
                ones_cnt <= mdio_i ? (ones_cnt + 6'd1) : 6'd0;
            end

            // ---- 帧边界与外设时序（与 oe 无关）----
            if (mdio_oe && !mdio_i && (ones_cnt >= 6'd32)) begin
                // ST 首位（bit32）刚采完 → 下一位是 bit33
                edge_cnt      <= 7'd33;
                frame_started <= 1'b1;
                $display("  DBGPRE frame-start detected (ones_cnt=%0d)", ones_cnt);
            end else if (frame_started) begin
                if (edge_cnt >= 7'd64)
                    frame_started <= 1'b0;          // 帧结束，重新等 preamble
                else
                    edge_cnt <= edge_cnt + 7'd1;
                // ★ 译码必须在 bit45 这一拍完成（而不是 bit46）：驱动逻辑要在
                //   "bit46 起始的下降沿"就开始驱动，晚一拍会让 phy_drv_en 永不置位。
                //   此刻 phy_rx[10:0] = bit34..44，mdio_i = bit45，拼起来正好是
                //   {OP(2), PHYAD(5), REGAD(5)}。
                if (edge_cnt == 7'd45) begin
                    $display("  DBGDEC ec=%0d rx=%016h mi=%b", edge_cnt, phy_rx[15:0], mdio_i);
                    // 此刻 phy_rx[0]=bit44 … phy_rx[10]=bit34，mdio_i=bit45
                    //   OP    = {bit34,bit35} = {phy_rx[10], phy_rx[9]}
                    //   PHYAD = bit36..40      = phy_rx[8:4]
                    //   REGAD = bit41..45      = {phy_rx[3:0], mdio_i}
                    frame_is_rd <= (phy_rx[10] == 1'b1) && (phy_rx[9] == 1'b0);
                    frame_phya  <= phy_rx[8:4];
                    frame_rega  <= {phy_rx[3:0], mdio_i};
                    if (phy_rx[10] && !phy_rx[9]) rd_cnt = rd_cnt + 1;
                    $display("  DBGR phya=%0d rega=%02h cur_page=%04h",
                             phy_rx[8:4], {phy_rx[3:0], mdio_i}, cur_page);
                    // 取读数据（页选择生效）
                    if ({phy_rx[3:0], mdio_i} == PAGE_REG)     rd_val <= cur_page;
                    else if (cur_page == RGMII_PAGE)           rd_val <= regs_rgmii[{phy_rx[3:0], mdio_i}];
                    else                                       rd_val <= regs_p0[{phy_rx[3:0], mdio_i}];
                end
                // 写操作：bit63 采完即取数据（此时 phy_rx[14:0]=bit48..62，mdio_i=bit63）
                if ((edge_cnt == 7'd63) && !frame_is_rd) begin
                    frame_data <= {phy_rx[14:0], mdio_i};
                    wr_cnt = wr_cnt + 1;
                    $display("  DBGW phya=%0d rega=%02h data=%04h cur_page=%04h",
                             frame_phya, frame_rega, {phy_rx[14:0], mdio_i}, cur_page);
                    if (frame_phya == PHY_ADDR) begin
                        if (frame_rega == PAGE_REG)      cur_page <= {phy_rx[14:0], mdio_i};
                        else if (cur_page == RGMII_PAGE) regs_rgmii[frame_rega] <= {phy_rx[14:0], mdio_i};
                        else                             regs_p0[frame_rega] <= {phy_rx[14:0], mdio_i};
                    end
                    // ★ 帧尾清零 ones_cnt：否则下一帧 preamble 的连续 1 计数溢出，
                    //   检测条件 `ones_cnt >= 32 && !mdio_i` 永不命中（实测只认出第 1 帧）。
                    ones_cnt <= 6'd0;
                end
            end
        end
    end

    // PHY 在 MDC 下降沿驱动 TA 与数据
    always @(negedge mdc or negedge rst_n) begin
        if (!rst_n) begin
            phy_drv_en <= 1'b0;
            phy_drv    <= 1'b0;
        end else if (frame_is_rd && phy_alive) begin
            if (edge_cnt == 6'd46) begin
                phy_drv_en <= 1'b1; phy_drv <= 1'b0;
            end else if (edge_cnt == 6'd47) begin
                phy_drv    <= 1'b0;
            end else if (edge_cnt >= 6'd48 && edge_cnt <= 6'd63) begin
                phy_drv    <= rd_val[15 - (edge_cnt - 6'd48)];
            end else if (edge_cnt > 6'd63) begin
                phy_drv_en <= 1'b0;
            end
        end else begin
            phy_drv_en <= 1'b0;
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

    integer g;
    reg [15:0] rxcr_before;

    // PHY 模型状态清零。
    // ★ 必须显式调用：`reg rst_n = 1'b0;` 是**初值**而不是跳变，仿真开始时没有
    //   negedge rst_n，`always @(posedge mdc or negedge rst_n)` 的复位分支不执行，
    //   否则 edge_cnt/ones_cnt/phy_rx 恒为 X —— 首帧被整帧漏掉（实测：第 2 帧被
    //   当成第 1 帧检测，命令 1 的写页从未落地）。
    task phy_model_clr;
        begin
            edge_cnt    = 7'd0;
            ones_cnt    = 6'd0;
            phy_rx      = 64'd0;
            frame_is_rd = 1'b0;
            frame_started = 1'b0;
            frame_rega  = 5'd0;
            frame_phya  = 5'd0;
            frame_data  = 16'd0;
            rd_val      = 16'd0;
            phy_drv_en  = 1'b0;
            phy_drv     = 1'b0;
        end
    endtask

    // 诊断：前 40 个 MDC 沿逐拍打印（定位首帧/preamble 对齐用，帧内噪声小）
    integer mdc_edges = 0;
    always @(posedge mdc) begin
        mdc_edges = mdc_edges + 1;
        if (mdc_edges <= 40)
            $display("  DBGE#%0d oe=%b mi=%b ec=%0d ones=%0d", mdc_edges, mdio_oe, mdio_i, edge_cnt, ones_cnt);
    end

    // 诊断：监视配置序列发给 MDIO 主机的命令
    always @(posedge clk) if (req) $display("  DBGREQ wr=%b rega=%02h wdata=%04h", wr, reg_a, wdata);

    // 诊断：配置序列状态机迁移
    reg [3:0] st_d = 4'hf;
    reg       oe_p = 1'b0;
    always @(posedge clk) begin
        st_d <= u_init.st;
        if (u_init.st !== st_d)
            $display("  DBGST %0d -> %0d (done=%b busy=%b)", st_d, u_init.st, done, busy);
    end
    // mdio_oe 上升沿（帧开始的标志）
    always @(posedge clk) begin
        if (mdio_oe && !oe_p) $display("  DBGOE↑ (mdc=%b)", mdc);
        oe_p <= mdio_oe;
    end

    initial begin
        $display("=== tb_phy_init: RTL8211F 上电配置序列验收 ===");
        // 预置寄存器：RXCR 的 bit3 先置 1（模拟 strap 使能），并放一些干扰位
        for (g = 0; g < 32; g = g + 1) begin
            regs_p0[g]    = 16'h0000;
            regs_rgmii[g] = 16'h0000;
        end
        regs_rgmii[RXCR_REG] = 16'h1238;   // bit3=1（延时使能）+ 其他位非零
        cur_page = 16'h0000;
        rxcr_before = regs_rgmii[RXCR_REG];
        phy_model_clr;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;

        // ---------- 用例 1：正常序列 ----------
        $display("[1] 正常序列：RXCR 初值=%04h（bit3=1）", rxcr_before);
        for (g = 0; g < 200000; g = g + 1) begin
            @(posedge clk);
            if (cfg_done) g = 200000;
        end
        chk(cfg_done === 1'b1, "序列完成");
        $display("  DBG mdc_edges=%0d wr_cnt=%0d rd_cnt=%0d edge_cnt=%0d is_rd=%b",
                 mdc_edges, wr_cnt, rd_cnt, edge_cnt, frame_is_rd);
        $display("  DBG cur_page=%04h rxcr=%04h rxcr_r=%04h", cur_page, regs_rgmii[RXCR_REG], rxcr_r);
        chk(cfg_skip === 1'b0, "未跳过写");
        chk(regs_rgmii[RXCR_REG][3] === 1'b0, "RXCR bit3 已清零（RX 延时关闭）");
        chk(regs_rgmii[RXCR_REG][15:4] === rxcr_before[15:4], "RXCR 其他位未被破坏");
        chk(cur_page === 16'h0000, "页选择已回到 0");
        chk(wr_cnt === 3, "写次数 = 3（页/ RXCR / 页）");
        chk(rd_cnt === 1, "读次数 = 1");

        // ---------- 用例 2：PHY 不响应 → 跳过写 ----------
        $display("[2] PHY 不响应：应跳过写、不破坏寄存器");
        phy_alive = 1'b0;
        regs_rgmii[RXCR_REG] = 16'h1238;   // 复位成 bit3=1
        cur_page = 16'h0000;
        wr_cnt = 0; rd_cnt = 0;
        phy_model_clr;
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        for (g = 0; g < 200000; g = g + 1) begin
            @(posedge clk);
            if (cfg_done) g = 200000;
        end
        chk(cfg_done === 1'b1, "序列完成（跳过写后仍走完）");
        chk(cfg_skip === 1'b1, "已标记跳过写");
        chk(rxcr_r === 16'hffff, "读回全 1（未响应）");
        chk(regs_rgmii[RXCR_REG] === 16'h1238, "PHY 寄存器未被垃圾值覆盖");

        $display("");
        $display("GATE checks=%0d errs=%0d(want 0:%s)", checks, errs, (errs==0)?"OK":"BAD");
        $display("=== TB-SUMMARY: %s ===", (errs==0) ? "ALL PASS" : "FAIL");
        $finish;
    end

    initial begin
        repeat (4_000_000) @(posedge clk);
        $display("GATE checks=%0d errs=%0d(want 0:BAD)", checks, errs+1);
        $display("=== TB-SUMMARY: FAIL (timeout) ===");
        $finish;
    end

endmodule
