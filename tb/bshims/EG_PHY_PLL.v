`timescale 1ns/1ps
// EG_PHY_PLL 行为模型（仿真 shim，tb/bshims/）
// 频率规则（从 Sdram_PLL 与 pll_hdmi1_4b 两个 wrapper 反推并交叉验证）：
//   FEEDBK_PATH = "VCO_PHASE_0"：VCO = FIN × FBCLK_DIV / REFCLK_DIV
//   FEEDBK_PATH = "CLKC0_EXT"：VCO = FIN × FBCLK_DIV × CLKC0_DIV / REFCLK_DIV
//     （外部反馈经 clkc0，环路增益含 CLKC0 分频）
//   clkcx = VCO / CLKCx_DIV
// 相位规则：相对 clkc0 的延迟 = (CLKCx_DIV-1-CLKCx_CPHASE + CLKCx_FPHASE/8) × T_vco
//   （交叉验证：HDMI PLL clkc2 DIV3/CPHASE2/FPHASE6 → 0.68ns @ T_vco 0.909ns = 90°，
//     与 IP 配置的 90° 吻合）
// 厂商原文件零改动；仅仿真用。
module EG_PHY_PLL #(
    parameter DPHASE_SOURCE = "DISABLE",
    parameter DYNCFG        = "DISABLE",
    parameter FIN           = "50.000000",
    parameter FEEDBK_MODE   = "NOCOMP",
    parameter FEEDBK_PATH   = "VCO_PHASE_0",
    parameter STDBY_ENABLE  = "DISABLE",
    parameter PLLRST_ENA    = "ENABLE",
    parameter SYNC_ENABLE   = "DISABLE",
    parameter GMC_GAIN      = 4,
    parameter ICP_CURRENT   = 13,
    parameter KVCO          = 4,
    parameter LPF_CAPACITOR = 1,
    parameter LPF_RESISTOR  = 4,
    parameter REFCLK_DIV    = 1,
    parameter FBCLK_DIV     = 20,
    parameter CLKC0_ENABLE  = "ENABLE",
    parameter CLKC0_DIV     = 10,
    parameter CLKC0_CPHASE  = 9,
    parameter CLKC0_FPHASE  = 0,
    parameter CLKC1_ENABLE  = "ENABLE",
    parameter CLKC1_DIV     = 10,
    parameter CLKC1_CPHASE  = 6,
    parameter CLKC1_FPHASE  = 0,
    parameter CLKC2_ENABLE  = "DISABLE",
    parameter CLKC2_DIV     = 4,
    parameter CLKC2_CPHASE  = 0,
    parameter CLKC2_FPHASE  = 0,
    parameter REF_PERIOD_NS = 20.0          // 参考时钟周期（两处 wrapper 均为 50M）
)(
    input               refclk,
    input               reset,
    input               stdby,
    output reg          extlock,
    input               load_reg,
    input               psclk,
    input               psdown,
    input               psstep,
    input  [2:0]        psclksel,
    output              psdone,
    input               dclk,
    input               dcs,
    input               dwe,
    input  [7:0]        di,
    input  [5:0]        daddr,
    output [7:0]        do,
    input               fbclk,
    output reg [4:0]    clkc
);
    // VCO 周期
    real t_vco;
    // 各输出周期与首沿延迟
    real t_c0, t_c1, t_c2;
    real d_c0, d_c1, d_c2;

    initial begin
        if (FEEDBK_PATH == "CLKC0_EXT")
            t_vco = REF_PERIOD_NS * REFCLK_DIV / (FBCLK_DIV * CLKC0_DIV);
        else
            t_vco = REF_PERIOD_NS * REFCLK_DIV / FBCLK_DIV;

        t_c0 = t_vco * CLKC0_DIV;
        t_c1 = t_vco * CLKC1_DIV;
        t_c2 = t_vco * CLKC2_DIV;
        d_c0 = (CLKC0_DIV-1-CLKC0_CPHASE + CLKC0_FPHASE/8.0) * t_vco;
        d_c1 = (CLKC1_DIV-1-CLKC1_CPHASE + CLKC1_FPHASE/8.0) * t_vco;
        d_c2 = (CLKC2_DIV-1-CLKC2_CPHASE + CLKC2_FPHASE/8.0) * t_vco;

        if (CLKC0_ENABLE == "ENABLE") begin
            clkc[0] = 1'b0;
            #(d_c0);
            forever begin
                clkc[0] = 1'b1; #(t_c0/2.0);
                clkc[0] = 1'b0; #(t_c0/2.0);
            end
        end else begin
            clkc[0] = 1'b0;
        end
    end

    initial begin
        if (CLKC1_ENABLE == "ENABLE") begin
            clkc[1] = 1'b0;
            #(d_c1);
            forever begin
                clkc[1] = 1'b1; #(t_c1/2.0);
                clkc[1] = 1'b0; #(t_c1/2.0);
            end
        end else begin
            clkc[1] = 1'b0;
        end
    end

    initial begin
        if (CLKC2_ENABLE == "ENABLE") begin
            clkc[2] = 1'b0;
            #(d_c2);
            forever begin
                clkc[2] = 1'b1; #(t_c2/2.0);
                clkc[2] = 1'b0; #(t_c2/2.0);
            end
        end else begin
            clkc[2] = 1'b0;
        end
    end

    initial begin
        clkc[4] = 1'b0;
        clkc[3] = 1'b0;
    end

    // 锁定指示：2 µs 后拉高（复位同步逻辑依赖）
    initial begin
        extlock = 1'b0;
        #2000;
        extlock = 1'b1;
    end

    // 动态配置/移相接口：仿真忽略
    assign do     = 8'h00;
    assign psdone = 1'b0;
endmodule
