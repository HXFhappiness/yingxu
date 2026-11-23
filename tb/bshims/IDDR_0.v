`timescale 1ns / 1ps
// IDDR_0 行为模型（仿真 shim，tb/bshims/）
// 厂商原语 al_ip/IDDR_0/IDDR_0.v 内部例化 EG_LOGIC_IDDR（ASYNCRST + PIPED）。
// 仿真语义：DDR 输入采样——q0 在时钟上升沿采 d，q1 在下降沿采 d；
// reset 高有效异步清零。PIPEMODE 的额外流水级不建模（相位由 TB 对齐）。
// 用途：rgmii_to_gmii 的 4 位数据 + rxdv（RGMII 模式）。
module IDDR_0 (
    output reg  q1,
    output reg  q0,
    input  wire d,
    input  wire clk,
    input  wire rst
);
    always @(posedge clk or posedge rst)
        if (rst) q0 <= 1'b0;
        else     q0 <= d;

    always @(negedge clk or posedge rst)
        if (rst) q1 <= 1'b0;
        else     q1 <= d;
endmodule
