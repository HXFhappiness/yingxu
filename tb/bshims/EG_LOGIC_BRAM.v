`timescale 1ns / 1ps
// ============================================================================
// EG_LOGIC_BRAM 行为模型（仿真 shim，tb/bshims/）
//   厂商原语：D:\Anlogic\TD_...\arch\eagle_macro.v:986（EG4 块 RAM，真双口）
//   本 shim 只实现工程用到的子集：
//     · DP 模式（两口共享一块存储），端口 A 写、端口 B 读；
//     · 读为**同步读**：地址在时钟沿打入，数据在**下一个**时钟沿出现在 do；
//       与真实 BRAM 的 1 拍读延迟一致（这是改用 BRAM 后必须重构流水的原因）。
//     · ce/we/rst 语义按原语：ce 使能、we 写、rst 清输出寄存器。
//     · bea/beb 字节使能：BYTE_ENABLE=0 时为 1 位"整字使能"，此处按位宽全写。
//     · INIT_FILE 不支持（工程里没有 BRAM 初始化需求；码本由 hdr_parse 灌）。
//
//   为什么需要它：TD 对 RTL 推断的存储器在这套流程里一律映射成分布式 RAM
//   （实测 10 种写法全部 0 BRAM，组合读更是不可能进 BRAM），必须显式例化原语。
// ============================================================================
module EG_LOGIC_BRAM (
    // 端口 A（写）
    input  wire [DATA_WIDTH_A-1:0] dia,
    input  wire [ADDR_WIDTH_A-1:0] addra,
    input  wire                    cea, ocea, clka, wea, rsta,
    input  wire [BYTE_A-1:0]       bea,
    // 端口 B（读）
    input  wire [DATA_WIDTH_B-1:0] dib,
    input  wire [ADDR_WIDTH_B-1:0] addrb,
    input  wire                    ceb, oceb, clkb, web, rstb,
    input  wire [BYTE_B-1:0]       beb,
    // 输出
    output reg  [DATA_WIDTH_A-1:0] doa,
    output reg  [DATA_WIDTH_B-1:0] dob
);
    parameter DATA_WIDTH_A   = 9;
    parameter DATA_WIDTH_B   = DATA_WIDTH_A;
    parameter ADDR_WIDTH_A   = 10;
    parameter ADDR_WIDTH_B   = ADDR_WIDTH_A;
    parameter DATA_DEPTH_A   = 2 ** ADDR_WIDTH_A;
    parameter DATA_DEPTH_B   = 2 ** ADDR_WIDTH_B;
    parameter BYTE_ENABLE    = 0;
    parameter BYTE_A         = BYTE_ENABLE == 0 ? 1 : DATA_WIDTH_A / BYTE_ENABLE;
    parameter BYTE_B         = BYTE_ENABLE == 0 ? 1 : DATA_WIDTH_B / BYTE_ENABLE;
    parameter MODE           = "DP";
    parameter REGMODE_A      = "NOREG";
    parameter REGMODE_B      = "NOREG";
    parameter WRITEMODE_A    = "NORMAL";
    parameter WRITEMODE_B    = "NORMAL";
    parameter RESETMODE      = "ASYNC";
    parameter DEBUGGABLE     = "NO";
    parameter PACKABLE       = "NO";
    parameter FORCE_KEEP     = "OFF";
    parameter INIT_FILE      = "NONE";
    parameter FILL_ALL       = "NONE";
    parameter IMPLEMENT      = "9K";

    // 真双口：两口共享存储（DP 模式下两口数据宽度必须一致）
    reg [DATA_WIDTH_A-1:0] mem [0:DATA_DEPTH_A-1];

    // ---- 端口 A ----
    always @(posedge clka) begin
        if (cea) begin
            if (wea) mem[addra] <= dia;
            if (REGMODE_A == "OUTREG") begin
                if (ocea) doa <= wea ? dia : mem[addra];
            end else begin
                doa <= wea ? dia : mem[addra];
            end
        end
    end
    always @(posedge rsta) doa <= {DATA_WIDTH_A{1'b0}};

    // ---- 端口 B（同步读：地址打入 → 下一沿出数）----
    always @(posedge clkb) begin
        if (ceb && !web) begin
            if (REGMODE_B == "OUTREG") begin
                if (oceb) dob <= mem[addrb];
            end else begin
                dob <= mem[addrb];
            end
        end
    end
    always @(posedge rstb) dob <= {DATA_WIDTH_B{1'b0}};

endmodule
