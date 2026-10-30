`timescale 1ns / 1ps
// yx8_prom.v — program memory for the YX-8 CPU
//
// Sync write, ASYNCHRONOUS read. The async read is deliberate: the CPU decodes
// `instr` in the same cycle as `pc`, so a BRAM with a registered output would
// shift every instruction by one cycle and the core would derail.
// 1024 x 24 = 24 Kb fits the EG4S20 distributed RAM (LUTRAM).
module yx8_prom #(
    parameter integer DW = 24,
    parameter integer N  = 1024
)(
    input  wire                  wclk,
    input  wire                  we,
    input  wire [$clog2(N)-1:0]  waddr,
    input  wire [DW-1:0]         wdata,
    input  wire [$clog2(N)-1:0]  raddr,
    output wire [DW-1:0]         rdata
);
    reg [DW-1:0] ram [0:N-1];

    always @(posedge wclk) begin
        if (we) ram[waddr] <= wdata;
    end

    assign rdata = ram[raddr];
endmodule
