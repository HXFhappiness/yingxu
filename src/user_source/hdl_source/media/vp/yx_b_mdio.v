// yx_b_mdio.v — Clause 22 MDIO 主机（P5）
//
// 背景：板 B 的 PHY 是 RTL8211F-CG（U14）。此前顶层把 eth_mdc/eth_mdio 恒置 1
// （"未实现 MDIO 配置"），导致：
//   · 无法读回 PHY 状态（例如 RGMII RX 延时是否使能）；
//   · 无法覆盖 strap 配置（RTL8211F 的 RX 延时 strap = RXD0，本板被 4.7K 上拉，
//     若为"使能"则 PHY 会给 RXC 再加 ~2ns，本设计的采样点会落到 4ns 数据眼外）。
// 本模块提供最小的 Clause 22 读写能力，供上电配置序列使用。
//
// 帧格式（IEEE 802.3 Clause 22）：
//   bit  0..31  preamble  32 × 1
//   bit 32..33  ST        2'b01
//   bit 34..35  OP        2'b01=写 / 2'b10=读
//   bit 36..40  PHYAD     5 位
//   bit 41..45  REGAD     5 位
//   bit 46..47  TA        写:2'b10；读:MAC 释放总线（高阻），PHY 驱动 0
//   bit 48..63  DATA      16 位
//
// 时序：每个 bit 两个相位——低相位 MAC 更新 mdio_o（PHY 在随后的上升沿采样），
// 高相位 MAC 采样 mdio_i（读操作的数据位）。MDC 半周期 = HALF_DIV 个 clk。
//   clk = 100MHz、HALF_DIV = 20 → MDC = 2.5MHz（Clause 22 上限）。
//
// 时钟域：用 clk100（来自 Sdram_PLL，只依赖板载 50M 晶振）——**不依赖 PHY 的
// RXC**，这样即使 PHY 上电后 RXC 未就绪也能完成配置。
//
// 用法：req 给 1 拍脉冲发起一次操作；busy 期间不可再发；done 为 1 拍完成脉冲，
// 读操作的 rdata 在 done 拍有效。
module yx_b_mdio #(
    parameter [4:0] PHY_ADDR = 5'd1,    // RTL8211F strap PHYAD0=1 → 地址 1
    parameter [7:0] HALF_DIV = 8'd20    // MDC 半周期（clk 周期数）
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 命令接口 ----
    input  wire        req,             // 1 拍脉冲：发起一次操作
    input  wire        wr,              // 1=写，0=读
    input  wire [4:0]  reg_a,
    input  wire [15:0] wdata,
    output reg  [15:0] rdata,
    output reg         done,            // 1 拍脉冲
    output reg         busy,

    // ---- MDIO 引脚 ----
    output reg         mdc,
    output reg         mdio_oe,         // 1=驱动 mdio_o，0=释放（高阻）
    output reg         mdio_o,
    input  wire        mdio_i
);
    localparam [5:0] LAST_BIT = 6'd63;

    // 帧位索引
    localparam [5:0] B_ST     = 6'd32;  // 起始码
    localparam [5:0] B_OP     = 6'd34;  // 操作码
    localparam [5:0] B_PHY    = 6'd36;  // PHY 地址
    localparam [5:0] B_REG    = 6'd41;  // 寄存器地址
    localparam [5:0] B_TA     = 6'd46;  // 转向
    localparam [5:0] B_DATA   = 6'd48;  // 数据

    reg  [5:0] bit_idx;
    reg        phase;                   // 0=低相位（MDC=0），1=高相位（MDC=1）
    reg  [7:0] hcnt;
    reg        rd_op;                   // 本次操作是否为读（锁存，防 req 撤销）

    // 帧第 idx 位应驱动的值（★ 必须按索引取值：下降沿推进 bit_idx 时要取**下一位**，
    //   早期版本直接取当前 bit_idx 的组合值，导致输出整体落后一位）
    function bit_val;
        input [5:0] idx;
        input       is_rd;
        begin
            if (idx < B_ST)          bit_val = 1'b1;                        // preamble
            else if (idx < B_OP)     bit_val = (idx == B_ST) ? 1'b0 : 1'b1; // ST = 2'b01
            else if (idx < B_PHY)    bit_val = is_rd ? (idx == B_OP)        // OP
                                                     : (idx != B_OP);       // 读=10 写=01
            else if (idx < B_REG)    bit_val = PHY_ADDR[4 - (idx - B_PHY)];
            else if (idx < B_TA)     bit_val = reg_a[4 - (idx - B_REG)];
            else if (idx < B_DATA)   bit_val = (idx == B_TA);               // 写 TA = 2'b10
            else                     bit_val = wdata[15 - (idx - B_DATA)];
        end
    endfunction

    // 该位是否由主机驱动（读操作从 TA 起释放总线）
    function bit_oe;
        input [5:0] idx;
        input       is_rd;
        begin
            bit_oe = !(is_rd && (idx >= B_TA));
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_idx <= 6'd0;
            phase   <= 1'b0;
            hcnt    <= 8'd0;
            mdc     <= 1'b0;
            mdio_oe <= 1'b0;
            mdio_o  <= 1'b1;
            rdata   <= 16'd0;
            done    <= 1'b0;
            busy    <= 1'b0;
            rd_op   <= 1'b0;
        end else begin
            done <= 1'b0;

            if (!busy) begin
                mdc     <= 1'b0;
                mdio_oe <= 1'b0;
                hcnt    <= 8'd0;
                phase   <= 1'b0;
                if (req) begin
                    busy    <= 1'b1;
                    rd_op   <= ~wr;
                    bit_idx <= 6'd0;
                    rdata   <= 16'd0;
                    mdio_oe <= 1'b1;
                    mdio_o  <= bit_val(6'd0, ~wr);   // preamble 首位
                end
            end else if (hcnt == HALF_DIV - 8'd1) begin
                hcnt <= 8'd0;
                if (!phase) begin
                    // 低 → 高：MDC 上升沿。PHY 在此采样 MAC 输出；
                    // 读操作在此采样 PHY 输出的数据位。
                    phase <= 1'b1;
                    mdc   <= 1'b1;
                    if (rd_op && (bit_idx >= B_DATA))
                        rdata <= {rdata[14:0], mdio_i};
                end else begin
                    // 高 → 低：MDC 下降沿。推进到下一位并更新输出（取**下一位**的值）。
                    phase <= 1'b0;
                    mdc   <= 1'b0;
                    if (bit_idx == LAST_BIT) begin
                        busy    <= 1'b0;
                        done    <= 1'b1;
                        mdio_oe <= 1'b0;
                    end else begin
                        bit_idx <= bit_idx + 6'd1;
                        mdio_oe <= bit_oe(bit_idx + 6'd1, rd_op);
                        mdio_o  <= bit_val(bit_idx + 6'd1, rd_op);
                    end
                end
            end else begin
                hcnt <= hcnt + 8'd1;
            end
        end
    end
endmodule
