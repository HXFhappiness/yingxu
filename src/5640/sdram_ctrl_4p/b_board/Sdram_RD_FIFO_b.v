/************************************************************\
 **  Copyright (c) 2011-2021 Anlogic, Inc.
 **  All Right Reserved.
\************************************************************/
// =============================================================================
// Sdram_RD_FIFO_b.v — 板 B 派生副本（源：同级 ../Sdram_RD_FIFO.v）
//   唯一改动：aflush 水线 AF 参数化（AF_W），并把 CDC 参数透传给 EG_LOGIC_FIFO
//   —— CDC 只对仿真模型有意义（真实 EG_LOGIC_FIFO 是硬 FIFO，双时钟天然安全），
//   故仅在 YINGXU_SIM 下传入，避免综合工具抱怨未知参数。
// =============================================================================
`timescale 1ns / 1ps

module Sdram_RD_FIFO_B #(
    parameter CDC  = 0,
    parameter AF_W = 128
) (
	rst,
	di, clkw, we,
	do, clkr, re,
	empty_flag,
	full_flag, afull_flag 
);

	input rst;
	input [31:0] di;
	input clkw, we;
	input clkr,re;

	output [31:0] do;
	output empty_flag;
	output full_flag, afull_flag;

EG_LOGIC_FIFO #(
 	.DATA_WIDTH_W(32),
	.DATA_WIDTH_R(32),
	.DATA_DEPTH_W(512),
	.DATA_DEPTH_R(512),
	.ENDIAN("BIG"),
	.RESETMODE("ASYNC"),
	.E(0),
	.F(512),
	.ASYNC_RESET_RELEASE("SYNC"),
	.AF(AF_W)
`ifdef YINGXU_SIM
	, .CDC(CDC)
`endif
)
logic_fifo(
	.rst(rst),
	.di(di),
	.clkw(clkw),
	.we(we),
	.csw(3'b111),
	.do(do),
	.clkr(clkr),
	.re(re),
	.csr(3'b111),
	.ore(1'b0),
	.empty_flag(empty_flag),
	.aempty_flag(),
	.full_flag(full_flag),
	.afull_flag(afull_flag)

);

endmodule