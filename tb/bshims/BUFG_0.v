`timescale 1ns / 1ps
// BUFG_0 行为模型（仿真 shim，tb/bshims/）
// 厂商原语 al_ip/BUFG_0/BUFG_0.v 内部例化 EG_LOGIC_BUFG（无 iverilog 模型）。
// 仿真语义：全局时钟缓冲 = 直通（无延迟、无门控）。
// 用途：eth_udp_rx_gmii 的 gmii_rx_clk 输入缓冲。
module BUFG_0 (
    input  wire i,
    output wire o
);
    assign o = i;
endmodule
