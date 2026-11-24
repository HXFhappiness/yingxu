// yx_b_phy_init.v — RTL8211F 上电配置序列（P5）
//
// 目的：把 PHY 的 RGMII RX 内部延时**关掉**。
//
// 为什么必须关：本板 PHY = RTL8211F-CG，其 RGMII RX 延时 strap = RXD0，
// 原理图上被 4.7K 上拉到 ETH_DVDDH。若该 strap 含义为"使能"，PHY 会给 RXC
// 再加 ~2ns，则本设计的采样点变成
//     采样时刻 = T + 2(PHY) + 3.705(FPGA 时钟插入延时) = T + 5.705ns
// 而数据眼只有 [T+1.075, T+5.075]（4ns 宽）→ 落到眼外，上板功能失败。
// 关掉之后采样点回到 T+3.705（眼内 66%，余量 0.97~1.37ns）。
// 详见 docs/YX_BBOARD_P5_PHY1_20261124.md §3。
//
// 寄存器（来自 Linux 内核 realtek_main.c，权威）：
//   页选择      寄存器 0x1f（RTL821x_PAGE_SELECT）
//   RGMII 扩展页 0xd08（RTL8211F_RGMII_PAGE）
//   RX 延时     页 0xd08 / 寄存器 0x15（RXCR）/ bit3（RTL8211F_RX_DELAY）
//
// 序列（读-改-写，避免动到 RXCR 的其他位）：
//   1. 写 0x1f = 0xd08        切到 RGMII 扩展页
//   2. 读 0x15                取回 RXCR 现值
//   3. 写 0x15 = 现值 & ~bit3 清 RX 延时位
//   4. 写 0x1f = 0x0000       回到页 0（不留在扩展页）
//
// 安全保护：
//   · 读回 0xffff 视为"PHY 未响应"（MDIO 总线空闲上拉即为全 1），**跳过写**，
//     避免把垃圾值写进 PHY；
//   · 清 bit3 本身是幂等的——若 strap 已把该位置 0，写回同值无副作用。
//
// 时序：复位释放后等 PHY_INIT_WAIT 个 clk 再开始（PHY 上电初始化需要时间）。
module yx_b_phy_init #(
    parameter [4:0]  PHY_ADDR     = 5'd1,       // RTL8211F strap PHYAD0=1 → 地址 1
    parameter [15:0] RGMII_PAGE   = 16'hd08,    // RTL8211F_RGMII_PAGE
    parameter [4:0]  RXCR_REG     = 5'h15,      // RTL8211F_RXCR
    parameter [15:0] RX_DLY_MASK  = 16'h0008,   // RTL8211F_RX_DELAY = BIT(3)
    parameter [4:0]  PAGE_REG     = 5'h1f,      // RTL821x_PAGE_SELECT
    parameter [23:0] PHY_INIT_WAIT= 24'd100_000 // 复位释放后等待（clk 周期）
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- MDIO 主机接口 ----
    output reg         req,
    output reg         wr,
    output reg  [4:0]  reg_a,
    output reg  [15:0] wdata,
    input  wire [15:0] rdata,
    input  wire        done,
    input  wire        busy,

    // ---- 观测 ----
    output reg  [15:0] rxcr_r,      // 读回的 RXCR 原值（0xffff = 未响应）
    output reg         cfg_done,    // 序列跑完（含跳过写的情况）
    output reg         cfg_skip     // 1=因 PHY 未响应跳过了写
);
    localparam S_WAIT   = 4'd0,
               S_PAGE   = 4'd1,  S_PAGE_W = 4'd2,
               S_RD     = 4'd3,  S_RD_W   = 4'd4,
               S_WR     = 4'd5,  S_WR_W   = 4'd6,
               S_REST   = 4'd7,  S_REST_W = 4'd8,
               S_DONE   = 4'd9;

    reg [3:0]  st;
    reg [23:0] wait_cnt;

    // ★ 必须"发命令 → 等 done"成对：MDIO 主机的 busy 比 req 晚一拍才起来，
    //   若发完就发下一条，会把上一条覆盖掉（早期版本踩过）。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_WAIT;
            wait_cnt  <= 24'd0;
            req       <= 1'b0;
            wr        <= 1'b0;
            reg_a     <= 5'd0;
            wdata     <= 16'd0;
            rxcr_r    <= 16'd0;
            cfg_done  <= 1'b0;
            cfg_skip  <= 1'b0;
        end else begin
            req <= 1'b0;                    // req 默认 0，只在需要的拍置 1

            case (st)
            S_WAIT: begin
                if (wait_cnt == PHY_INIT_WAIT) st <= S_PAGE;
                else                           wait_cnt <= wait_cnt + 24'd1;
            end
            // ---- 1. 写页选择 = 0xd08 ----
            S_PAGE: begin
                req <= 1'b1; wr <= 1'b1;
                reg_a <= PAGE_REG; wdata <= RGMII_PAGE;
                st    <= S_PAGE_W;
            end
            S_PAGE_W: if (done) st <= S_RD;
            // ---- 2. 读 RXCR ----
            S_RD: begin
                req <= 1'b1; wr <= 1'b0;
                reg_a <= RXCR_REG;
                st    <= S_RD_W;
            end
            S_RD_W: if (done) begin
                rxcr_r <= rdata;
                st     <= (rdata == 16'hffff) ? S_REST : S_WR;   // 未响应则跳过写
            end
            // ---- 3. 写 RXCR（清 bit3）----
            S_WR: begin
                req <= 1'b1; wr <= 1'b1;
                reg_a <= RXCR_REG; wdata <= rxcr_r & ~RX_DLY_MASK;
                st    <= S_WR_W;
            end
            S_WR_W: if (done) st <= S_REST;
            // ---- 4. 页选择回 0 ----
            S_REST: begin
                req <= 1'b1; wr <= 1'b1;
                reg_a <= PAGE_REG; wdata <= 16'h0000;
                st    <= S_REST_W;
            end
            S_REST_W: if (done) st <= S_DONE;
            S_DONE: begin
                cfg_done <= 1'b1;
                if (rxcr_r == 16'hffff) cfg_skip <= 1'b1;
            end
            default: st <= S_WAIT;
            endcase
        end
    end
endmodule
