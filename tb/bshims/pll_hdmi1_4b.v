`timescale 1ns / 1ps
// pll_hdmi1_4b 仿真 shim（tb/bshims/）——TD 构建换真 PLL IP（A 板同款 megafunction）。
// 端口与 A 板 design_top_wrapper 例化一致：refclk/reset/extlock/clk1_out/clk2_out。
//   clk1_out = 73.33MHz 像素时钟（720p59.3：1650×750×59.3 ≈ 73.3M，半周期 6.818ns 实数延迟）
//   clk2_out = 366.67MHz 串行时钟（×5，仿真仅存在，加密核不进仿真构建）
//   extlock  = 复位后 ~8 个 refclk 置 1（像素域复位释放依据）
module pll_hdmi1_4b (
    input  wire refclk,
    input  wire reset,
    output wire extlock,
    output reg  clk1_out,
    output reg  clk2_out
);
    initial clk1_out = 1'b0;
    initial clk2_out = 1'b0;
    // 73.33M：半周期 6.818ns（实数延迟，iverilog 支持）
    always #(6.818) clk1_out = ~clk1_out;
    // 366.67M：半周期 1.3636ns
    always #(1.3636) clk2_out = ~clk2_out;

    reg [3:0] lock_cnt = 4'd0;
    always @(posedge refclk or posedge reset) begin
        if (reset) begin
            lock_cnt <= 4'd0;
        end else if (lock_cnt != 4'd8) begin
            lock_cnt <= lock_cnt + 4'd1;
        end
    end
    assign extlock = (lock_cnt == 4'd8);
endmodule
