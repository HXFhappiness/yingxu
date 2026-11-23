`timescale 1ns / 1ps
// EG_LOGIC_FIFO 行为模型（仿真 shim，tb/bshims/）
// 原语无公开仿真模型；本 shim 按以下已确认契约实现：
//   · 双时钟端口。CDC=0（默认）：clkw/clkr 同域，指针用纯二进制 + 直接比较
//     （WR1/WR2/RD2 实例均为同域 clk100）。
//     ★ CDC=1（P3 RD1 显示 FIFO：clkw=100M / clkr=73.33M）：格雷码指针 +
//     双拍同步——多比特二进制指针跨域采样会撕裂（0111→1000 多位同变）；
//     占用估计方向保守（写域 occ 偏大→full/afull 提前；读域 occ 偏小→
//     empty 提前），与真实双时钟 FIFO 的同步滞后行为一致。
//   · 读出：re 采样沿寄存 do（do 在 re 后一拍可见）。
//     实测依据：写链路 IN_REQ 在 (E2,E3) 有效 → re 于 E3 采样；WRITE 命令同在 (E3,E4)
//     被 SDRAM 采样，组合直通 do 会使命令沿读到推进后的 word1（首字丢失）。
//     寄存 do 后 (E3,E4) 期间 do=word0，突发 len 字恰好对齐 col0..col(len-1)。
//   · 标志：empty（读域）/ aempty（读域，cnt<=AE）/ full、afull（写域，cnt>=AF）
//   · 指针 10 位、模 1024 自然回绕，占用 ≤512 <1024，10 位减法即真实占用量
// 用途：B 板集成仿真（Sdram_WR_FIFO / Sdram_RD_FIFO 的原语）。厂商原文件零改动。
module EG_LOGIC_FIFO #(
    parameter DATA_WIDTH_W = 32,
    parameter DATA_WIDTH_R = 32,
    parameter DATA_DEPTH_W = 512,
    parameter DATA_DEPTH_R = 512,
    parameter ENDIAN = "BIG",
    parameter RESETMODE = "ASYNC",
    parameter E = 0,
    parameter F = 512,
    parameter AE = 127,
    parameter AF = 378,
    parameter ASYNC_RESET_RELEASE = "SYNC",
    parameter CDC = 0                      // ★ P3：1=真双时钟（格雷码+同步）
)(
    input                       rst,
    input  [DATA_WIDTH_W-1:0]   di,
    input                       clkw,
    input                       we,
    input  [2:0]                csw,
    output reg [DATA_WIDTH_R-1:0] do,
    input                       clkr,
    input                       re,
    input  [2:0]                csr,
    input                       ore,
    output                      empty_flag,
    output                      aempty_flag,
    output                      full_flag,
    output                      afull_flag
);
    initial begin
        if (DATA_WIDTH_W !== DATA_WIDTH_R || DATA_DEPTH_W !== DATA_DEPTH_R)
            $display("EG_LOGIC_FIFO shim: 对称位宽/深度未支持 (W=%0d/%0d D=%0d/%0d)",
                     DATA_WIDTH_W, DATA_WIDTH_R, DATA_DEPTH_W, DATA_DEPTH_R);
    end

    localparam AW = 9;                      // 512 深度索引位
    localparam PT = AW + 1;                 // 指针 10 位（模 1024 回绕）
    reg [DATA_WIDTH_W-1:0] mem [0:DATA_DEPTH_W-1];

    generate if (CDC == 0) begin : SAMEDOM

        // ============ 同域（既有二进制实现，基线零扰动）============
        reg [AW-1:0] wp = 0, rp = 0;
        reg [PT-1:0] wp_bin = 0, rp_bin = 0;

        wire [PT-1:0] wp_nxt = wp_bin + 1'b1;
        wire [PT-1:0] rp_nxt = rp_bin + 1'b1;

        // 写域
        always @(posedge clkw or posedge rst) begin
            if (rst) begin
                wp_bin <= 0; wp <= 0;
            end else if (we && !full_flag) begin
                mem[wp]  <= di;
                wp       <= wp + 1'b1;
                wp_bin   <= wp_nxt;
            end
        end

        // 读域（re 采样沿寄存 do）
        always @(posedge clkr or posedge rst) begin
            if (rst) begin
                rp_bin <= 0; rp <= 0; do <= 0;
            end else if (re && !empty_flag) begin
                do     <= mem[rp];
                rp_bin <= rp_nxt;
                rp     <= rp + 1'b1;
            end
        end

        // 占用（同域直读，两侧指针一致；模 1024 减 = 真实占用 ≤512）
        wire [PT-1:0] occ = wp_bin - rp_bin;
        assign empty_flag  = (occ == 0);
        assign aempty_flag = (occ <= AE);
        assign full_flag   = (occ >= DATA_DEPTH_W);
        assign afull_flag  = (occ >= AF);

    end else begin : ASYNDOM

        // ============ 真双时钟（格雷码指针 + 双拍同步，P3 RD1 显示 FIFO）============
        // ★ 指针 10 位（PT）→ 格雷码必须同为 PT 位（截到 AW=9 位会丢 bin[9]
        //   种子位，gray2bin 全错——YX6 实测 rbw=639>wb=384、emp/af 全乱）。
        reg [AW-1:0] wp = 0, rp = 0;
        reg [PT-1:0] wbin = 0, rbin = 0;
        reg [PT-1:0] wgray = 0, rgray = 0;

        wire [PT-1:0] wbin_nxt = wbin + 1'b1;
        wire [PT-1:0] wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;
        wire [PT-1:0] rbin_nxt = rbin + 1'b1;
        wire [PT-1:0] rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

        function [PT-1:0] gray2bin(input [PT-1:0] g);
            integer i;
            begin
                gray2bin[PT-1] = g[PT-1];
                for (i = PT-2; i >= 0; i = i - 1)
                    gray2bin[i] = gray2bin[i+1] ^ g[i];
            end
        endfunction

        // 写域：指针推进（full/afull 用保守占用：读指针经同步滞后 → occ 偏大）
        always @(posedge clkw or posedge rst) begin
            if (rst) begin
                wbin <= 0; wp <= 0; wgray <= 0;
            end else if (we && !full_flag) begin
                mem[wp]  <= di;
                wp       <= wp + 1'b1;
                wbin     <= wbin_nxt;
                wgray    <= wgray_nxt;
            end
        end

        // 读域：指针推进（do 为 pop 沿寄存；empty 用保守占用）
        always @(posedge clkr or posedge rst) begin
            if (rst) begin
                rbin <= 0; rp <= 0; rgray <= 0; do <= 0;
            end else if (re && !empty_flag) begin
                do     <= mem[rp];
                rp     <= rp + 1'b1;
                rbin   <= rbin_nxt;
                rgray  <= rgray_nxt;
            end
        end

        // 读→写域：rgray 双拍同步（写域占用）
        reg [PT-1:0] rgray_wq1 = 0, rgray_wq2 = 0;
        always @(posedge clkw or posedge rst)
            if (rst) begin rgray_wq1 <= 0; rgray_wq2 <= 0; end
            else begin rgray_wq1 <= rgray; rgray_wq2 <= rgray_wq1; end
        wire [PT-1:0] rbin_w = gray2bin(rgray_wq2);
        wire [PT-1:0] occ_w  = wbin - rbin_w;               // 保守偏大
        assign full_flag  = (occ_w >= DATA_DEPTH_W);
        assign afull_flag = (occ_w >= AF);

        // 写→读域：wgray 双拍同步（读域占用）
        reg [PT-1:0] wgray_rq1 = 0, wgray_rq2 = 0;
        always @(posedge clkr or posedge rst)
            if (rst) begin wgray_rq1 <= 0; wgray_rq2 <= 0; end
            else begin wgray_rq1 <= wgray; wgray_rq2 <= wgray_rq1; end
        wire [PT-1:0] wbin_r = gray2bin(wgray_rq2);
        // ★ 占用 = 10 位模减（回绕天然正确：占用 ≤512 <1024，减法无借位歧义）。
        //   YX6 实测：加 (wbin_r >= rbin) 守卫会在写指针回绕（1024→0）时把
        //   非空 FIFO 误判空（occ_w=202 vs occ_r=0）→ 显示永久饿死。
        wire [PT-1:0] occ_r  = wbin_r - rbin;
        assign empty_flag  = (occ_r == 0);
        assign aempty_flag = (occ_r <= AE);

    end endgenerate
endmodule
