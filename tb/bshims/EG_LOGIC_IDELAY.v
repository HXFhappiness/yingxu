`timescale 1ns / 1ps
// EG_LOGIC_IDELAY 行为模型（仿真 shim，tb/bshims/）
//
// 厂商原语（TD 安装目录 sim_release/eg4/eg_logic_io.v:20）在 EG4 上是 IOB 输入的
// 可编程延时链：INDEL = 1~32，基础 0.52ns，每档 +0.12ns。
// 用法见 src/rgmii_to_gmii.v（RGMII RX 数据对齐）。
//
// ★ 仿真语义 = **直通**（无附加延时）。理由：
//   1. IDELAY 只改变数据相对时钟的**到达时刻**，不改变任何逻辑值——直通在功能上
//      是精确等价的，不会放宽任何判据（字节对拍 / 金标判据全部不变）；
//   2. 仿真里没有真实时钟插入延时（TD 实测 RXC→IDDR.clk 为 3.705ns、
//      RXD→IDDR.d 为 1.075ns）。若在仿真里也加 0.6ns 数据延时，反而会**伪造**
//      "数据比时钟晚"的关系——物理上恰恰相反（时钟更晚）。所以直通是更忠实的
//      选择，加延时才是失真；
//   3. 该延时的真实效果只能由 TD 的 STA 报告体现（Data Path Delay），或上板实测。
module EG_LOGIC_IDELAY #(
    parameter INDEL = 1
)(
    input  wire i,
    output wire o
);
    assign o = i;
endmodule
