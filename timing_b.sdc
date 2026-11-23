# =============================================================================
# 映序 B 板（VQ 视频协处理）timing 约束 — P5 骨架（2026-11-23）
#
# ★ 状态：**骨架**。时钟定义/异步组已按 RTL 实例写全；引脚绑定与 I/O 延时
#   待 **AC601 引脚表**（见 docs/YX_BBOARD_P5_TD_20261123.md）。
#   拿到引脚表后只需补本文件 §5（I/O 延时与 PIN 约束）与工程 .al 的引脚分配。
#
# 顶层：src/user_source/hdl_source/media/vp/yingxu_vq_board_top.v
# 时钟域（4 个）：
#   ref_clk   50M   （板载晶振，输入）
#   100M      由 Sdram_Control_4Port 内部 Sdram_PLL clk0 产生（控制器 + 全部视频逻辑）
#   73.33M    由 pll_hdmi1_4b clk1 产生（像素域：扫出/取数/AXIS）
#   366.67M   由 pll_hdmi1_4b clk2 产生（TMDS 串行域，仅 EMIT_HDMI=1）
#   （125M RGMII 由 PHY 提供 eth_rxc，接入 yx_b_eth_rx 后为第 5 个域，见 §3）
# 引脚：见 IO_b.adc（B 板与 A 板同构，引脚等同 A 板 IO.adc；SDRAM 走专用硬接口）
# =============================================================================

# -----------------------------------------------------------------------------
# 1. 主时钟与派生
# -----------------------------------------------------------------------------
create_clock -name b_ref_clk_50m -period 20.000 -waveform {0.000 10.000} [get_ports {ref_clk}]

# 自动派生两个 PLL 的输出时钟（Sdram_PLL: clkc0=100M/clkc1=100M@相移；
# pll_hdmi1_4b: 仅用 clk1_out=73.33M 与 clk2_out=366.67M，无 clk0）
derive_pll_clocks

# ★★ 危险：RTL 只接 clk1_out / clk2_out，真 IP 可能把它们映射到 clkc[0]/[1]，
#   而非 clkc[1]/[2]。若时钟名错位，所有异步组会声明错对象且不报错（最危险）。
# ★★ 红线：首份 report_qor -step place 后务必打印 "Clock name" 列表，逐条核对
#   下面 glob 是否命中正确时钟；不对立即按实际名称改 glob 或用 -of_objects。
#   例：若真名为 *pll_inst*clk1_out，则 get_clocks {*u_hdmi_pll*pll_inst*clk1_out}。

# -----------------------------------------------------------------------------
# 2. 异步时钟组（跨域均由设计内 CDC 承载，逐条注明依据）
# -----------------------------------------------------------------------------
# 2.1 SDRAM PLL 两输出之间（厂商控制器内部约定）
set_clock_groups -name b_cdc_sdram_pll -asynchronous \
    -group [get_clocks {*sdram_pll1*clkc[0]}] \
    -group [get_clocks {*sdram_pll1*clkc[1]}]
# 注：TD 的派生时钟命名可能是 clkc[0]/clkc[1] 或 plkc[0]/plkc[1]，
#     首次 report_qor -step place 后按 "Clock name" 列表校正（A 板 sdc 用 clkc）。

# 2.2 板级 50M ↔ SDRAM 域：ref_clk 只进两个 PLL，无直接数据通路
set_clock_groups -name b_cdc_ref_sdram -asynchronous \
    -group [get_clocks {b_ref_clk_50m}] \
    -group [get_clocks {*sdram_pll1*clkc*}]

# 2.3 100M ↔ 73.33M 像素域：RD1 显示 FIFO 为厂商真双时钟 FIFO（格雷码+2FF）
# ★ RTL 只用 pll_hdmi1_4b 的 clk1_out(73.33M)；若真 IP 映射为 clkc[0] 而非 clkc[1]，
#   本组会声明"100M 与 100M 异步"（无意义），而真正需要的 100M↔73.33M 变成被分析。
#   首份 report_qor 后按实际时钟名修正此处 glob。
set_clock_groups -name b_cdc_sdram_hdmi -asynchronous \
    -group [get_clocks {*sdram_pll1*clkc[0]}] \
    -group [get_clocks {*u_hdmi_pll*pll_inst*clkc[1]}]

# 2.4 50M ↔ HDMI 域（ref_clk → pll_hdmi1_4b 输入）
set_clock_groups -name b_cdc_ref_hdmi -asynchronous \
    -group [get_clocks {b_ref_clk_50m}] \
    -group [get_clocks {*u_hdmi_pll*pll_inst*clkc*}]

# 2.5 像素 73.33M ↔ 串行 366.67M：lane_lvds_10_1 设计内 CDC
#     （S_odd_even 2FF 同步、S_load_en 三级延迟、数据稳定后加载；两钟同 VCO 5:1）。
#     A 板同类豁免实测通过（timing.sdc:13-18）。
# ★ 若真 IP 时钟名为 clk1_out / clk2_out 而非 clkc[1]/[2]，改用实际名或 -of_objects。
set_clock_groups -name b_cdc_hdmi_pix_serial -asynchronous \
    -group [get_clocks {*u_hdmi_pll*pll_inst*clkc[1]}] \
    -group [get_clocks {*u_hdmi_pll*pll_inst*clkc[2]}]

# 2.6 串行 366.67M ↔ SDRAM / 以太网域：串行钟只在 lane_lvds_10_1 内部用，
#     无与外部域的数据通路，但需声明避免 STA 报未约束路径。
set_clock_groups -name b_cdc_serial_others -asynchronous \
    -group [get_clocks {*u_hdmi_pll*pll_inst*clkc[2]}] \
    -group [get_clocks {*sdram_pll1*clkc[0]}]

# -----------------------------------------------------------------------------
# 3. 以太网域（RGMII 125M，PHY 提供 eth_rxc）
# -----------------------------------------------------------------------------
# ★ 生效前提：TD 构建带 -DUSE_ETH（顶层才有 eth_rxc 端口）。
#   不带该宏时本节 get_ports 会报错 → 用 Tcl 条件化：
if {[llength [get_ports -quiet eth_rxc]] > 0} {

create_clock -name b_eth_rxc_125m -period 8.000 [get_ports {eth_rxc}]

# 3.1 RGMII 接收：源同步 DDR。数据与 rxc 由同一 PHY 发出，板级走线延迟决定
#     采样窗口；先给占位值，**上板后用实测/PHY 手册校准**（RGMII 典型 1~2ns，
#     若 PHY 内部已加 RXC delay 则接近 0）。
#     ★ RGMII 是 DDR，需约束上升沿与下降沿各一组（-clock_fall -add_delay）。
set_input_delay -clock b_eth_rxc_125m -max 2.000 [get_ports {eth_rxd[*]}]
set_input_delay -clock b_eth_rxc_125m -min 0.500 [get_ports {eth_rxd[*]}]
set_input_delay -clock b_eth_rxc_125m -clock_fall -max 2.000 -add_delay [get_ports {eth_rxd[*]}]
set_input_delay -clock b_eth_rxc_125m -clock_fall -min 0.500 -add_delay [get_ports {eth_rxd[*]}]
set_input_delay -clock b_eth_rxc_125m -max 2.000 [get_ports {eth_rxdv}]
set_input_delay -clock b_eth_rxc_125m -min 0.500 [get_ports {eth_rxdv}]
set_input_delay -clock b_eth_rxc_125m -clock_fall -max 2.000 -add_delay [get_ports {eth_rxdv}]
set_input_delay -clock b_eth_rxc_125m -clock_fall -min 0.500 -add_delay [get_ports {eth_rxdv}]

# 3.2 125M ↔ 100M（SDRAM/视频逻辑域）：yx_b_eth_rx 异步字节 FIFO 承担跨域
set_clock_groups -name b_cdc_eth_sdram -asynchronous \
    -group [get_clocks {b_eth_rxc_125m}] \
    -group [get_clocks {*sdram_pll1*clkc[0]}]

# 3.3 125M ↔ 73.33M / 50M：无直接数据通路（eth 只进 100M 域），一并声明
set_clock_groups -name b_cdc_eth_others -asynchronous \
    -group [get_clocks {b_eth_rxc_125m}] \
    -group [get_clocks {*u_hdmi_pll*pll_inst*clkc*}] \
    -group [get_clocks {b_ref_clk_50m}]

# 3.4 PHY 控制引脚（eth_rst_n / eth_mdc / eth_mdio）：纯静态电平，无需时序约束。

# } —— 以太网域条件化结束

}  ; # if {[llength [get_ports -quiet eth_rxc]] > 0}

# -----------------------------------------------------------------------------
# 4. SDRAM 引脚（沿用 A 板做法：不设 output delay，由控制器内部时序保证）
# -----------------------------------------------------------------------------
# 若首份 STA 报 SDRAM 引脚建立/保持余量不足，再按 AC601 走线补：
# set_output_delay -clock [get_clocks {*sdram_pll1*clkc[0]}] -max 1.500 [get_ports {DRAM_*}]
# set_output_delay -clock [get_clocks {*sdram_pll1*clkc[0]}] -min 0.500 [get_ports {DRAM_*}]

# -----------------------------------------------------------------------------
# 附加约束：异步复位与静态信号
# -----------------------------------------------------------------------------
# rst_n 是异步复位，直连各域复位端（无同步器），需 false_path 避免
# recovery/removal 违例。若后续改为各域加复位同步器，可移除此条改约束同步链。
set_false_path -from [get_ports {rst_n}]

# -----------------------------------------------------------------------------
# 5. HDMI TMDS 输出与 DDC
# -----------------------------------------------------------------------------
# TMDS 由 lane_lvds_10_1 的 DDR 输出级直接送 IO（A 板同款），不做 output delay；
# 引脚（IO_b.adc）：tmds_ch0_p=D11 / ch1_p=C11 / ch2_p=F10 / clk_p=B10，LVDS33_E。
# DDC（tmds_ddc_scl / tmds_ddc_sda）当前不启用（I_edid_read_trig 恒 0），
# 接入后需在 IO_b.adc 补引脚并注意 SDA 为 inout、外部上拉。
