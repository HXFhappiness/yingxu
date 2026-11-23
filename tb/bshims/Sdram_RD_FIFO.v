/************************************************************\
 **  EG_LOGIC_FIFO CDC-passthrough shim (tb/bshims/)
 **  Vendor copy: src/5640/sdram_ctrl_4p/Sdram_RD_FIFO.v（TD 构建用，零改动）。
 **  本副本仅仿真：新增 CDC 参数并透传 EG_LOGIC_FIFO——P3 显示 FIFO 为真双
 **  时钟（clkw=100M / clkr=73.33M 像素域），bshims 控制器的 read_fifo1 传
 **  CDC=1（格雷码+同步），其余实例默认 0（同域二进制，基线零扰动）。
\************************************************************/
`timescale 1ns / 1ps

module Sdram_RD_FIFO #(
    parameter CDC = 0,
    parameter AF_W = 128            // ★ P3：afull 水线透传（RD1 显示=300）
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
	.AF(AF_W),
	.CDC(CDC))
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
