`timescale 1ns/1ps
// EG_PHY_SDRAM_2M_32 行为模型（仿真 shim，tb/bshims/）
// EG4S20 片内 SDRAM 硬宏无公开仿真模型；本模型实现命令级行为：
//   · 命令集：ACT / READ / WRITE / PRE(PALL) / REF / MRS（标准 SDR SDRAM 编码）
//   · 4 bank × 2048 行 × 256 列(32bit) = 2M 字；线性地址 = {ba, row, col}
//     与控制器地址映射一致（ROWSTART 8/ROWSIZE 11、COLSTART 0/COLSIZE 8、
//     BANKSTART 19/BANKSIZE 2 → 用户 21 位地址 {bank, row, col}）
//   · CAS 延迟 3（控制器 SC_CL=3）；读数据自命令采样沿 +3 拍出现，之后每拍 1 字
//   · 【页模式】控制器 SC_PM=1 + MRS 全页突发：每个突发只发 1 条 READ/WRITE 命令，
//     之后连续 mLENGTH 拍数据流式收发，直到 PRE/PALL 终止。本模型据此实现：
//       - READ 后：列地址自动 +1，每拍输出下一列（列回卷按 256 列页边界，同真实器件）
//       - WRITE 后：命令沿写首字，之后每拍写下一列，PRE/PALL 沿不再写
//   · dm 4 位按字节屏蔽（低有效）
//   · 刷新/模式寄存器命令接收但不改变行为（功能仿真）
module EG_PHY_SDRAM_2M_32 (
    input               clk,
    input               ras_n,
    input               cas_n,
    input               we_n,
    input  [10:0]       addr,
    input  [1:0]        ba,
    inout  [31:0]       dq,
    input               cs_n,
    input               dm0,
    input               dm1,
    input               dm2,
    input               dm3,
    input               cke
);
    reg [31:0] mem [0:(1<<21)-1];
    reg        opened [0:3];
    reg [10:0] open_row [0:3];

    // 读流水（CL=3）：命令沿入 stage0，+3 拍驱动 dq
    reg        p0_v, p1_v, p2_v;
    reg [31:0] p0_d, p1_d, p2_d;
    reg [31:0] dq_o;
    reg        dq_oe;

    // 页模式流式状态
    reg        rd_on;       // 读流进行中（列自动递增）
    reg [7:0]  rd_col;      // 下一个待取列
    reg        wr_on;       // 写流进行中
    reg [7:0]  wr_col;      // 下一个待写列

    wire [31:0] dq_in = dq;
    wire [31:0] wmask = {{8{~dm3}}, {8{~dm2}}, {8{~dm1}}, {8{~dm0}}};

    assign dq = dq_oe ? dq_o : 32'hzzzz_zzzz;

    integer i;
    localparam DBG = 1'b0;   // 命令级调试输出（sanity 调试用，默认关）

    always @(posedge clk) begin
        // ---- 读流水推进 ----
        p2_v <= p1_v;  p2_d <= p1_d;
        p1_v <= p0_v;  p1_d <= p0_d;
        p0_v <= 1'b0;
        // dq 驱动级：stage2 → 引脚（读写共用，命令分支可覆写 dq_oe）
        dq_o  <= p2_d;
        dq_oe <= p2_v;

        if (!cs_n) begin
            if (!ras_n && cas_n && we_n) begin
                // ---- ACT：开行，终止任何流 ----
                if (DBG && ($time > 300000)) $display("[%0t] SDRAM ACT   ba=%0d row=%03h", $time, ba, addr);
                opened[ba]    <= 1'b1;
                open_row[ba]  <= addr;
                rd_on <= 1'b0;
                wr_on <= 1'b0;
                dq_oe <= 1'b0;
            end
            else if (ras_n && !cas_n && we_n) begin
                // ---- READ：首字入流水 + 启动列自增流 ----
                if (DBG && ($time > 300000)) $display("[%0t] SDRAM READ  ba=%0d col=%0d", $time, ba, addr[7:0]);
                rd_on  <= 1'b1;
                wr_on  <= 1'b0;
                rd_col <= addr[7:0] + 8'd1;
                p0_v   <= 1'b1;
                p0_d   <= mem[{ba, open_row[ba], addr[7:0]}];
            end
            else if (ras_n && !cas_n && !we_n) begin
                // ---- WRITE：命令沿写首字 + 启动列自增流 ----
                if (DBG && ($time > 300000)) $display("[%0t] SDRAM WRITE ba=%0d col=%0d dq=%08h", $time, ba, addr[7:0], dq_in);
                if (opened[ba])
                    mem[{ba, open_row[ba], addr[7:0]}] <=
                        (dq_in & wmask) | (mem[{ba, open_row[ba], addr[7:0]}] & ~wmask);
                wr_on  <= 1'b1;
                wr_col <= addr[7:0] + 8'd1;
                rd_on  <= 1'b0;
                dq_oe  <= 1'b0;      // 写期间不驱动读数据（防总线冲突）
            end
            else if (!ras_n && cas_n && !we_n) begin
                // ---- PRE / PALL：终止取数，流水线自然排空 ----
                // （真实器件突发终止后 CAS 流水仍交付残余数据；立即清 dq_oe 会
                //   杀死本沿应输出的字并使流水残留字迟到 → 控制器窗口错位）
                if (DBG && ($time > 300000)) $display("[%0t] SDRAM PRE   ba=%0d a10=%b", $time, ba, addr[10]);
                rd_on <= 1'b0;
                wr_on <= 1'b0;
                if (addr[10]) begin
                    for (i = 0; i < 4; i = i + 1) opened[i] <= 1'b0;
                end else begin
                    opened[ba] <= 1'b0;
                end
            end
            else begin
                // ---- NOP：流继续 ----
                if (rd_on) begin
                    p0_v   <= 1'b1;
                    p0_d   <= mem[{ba, open_row[ba], rd_col}];
                    rd_col <= rd_col + 8'd1;
                end
                if (wr_on) begin
                    if (opened[ba])
                        mem[{ba, open_row[ba], wr_col}] <=
                            (dq_in & wmask) | (mem[{ba, open_row[ba], wr_col}] & ~wmask);
                    wr_col <= wr_col + 8'd1;
                end
            end
        end
        else begin
            // ---- CS 高：无新命令，突发流继续（真实器件突发不受 CS 影响）----
            if (rd_on) begin
                p0_v   <= 1'b1;
                p0_d   <= mem[{ba, open_row[ba], rd_col}];
                rd_col <= rd_col + 8'd1;
            end
            if (wr_on) begin
                if (opened[ba])
                    mem[{ba, open_row[ba], wr_col}] <=
                        (dq_in & wmask) | (mem[{ba, open_row[ba], wr_col}] & ~wmask);
                wr_col <= wr_col + 8'd1;
            end
        end
    end

    initial begin
        for (i = 0; i < 4; i = i + 1) opened[i] = 1'b0;
        dq_oe = 1'b0;
        rd_on = 1'b0;
        wr_on = 1'b0;
    end
endmodule
