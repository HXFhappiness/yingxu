# =============================================================================
# 映序 B 板（VQ 视频协处理）timing 约束 — P5
#
# 顶层：src/user_source/hdl_source/media/vp/yingxu_vq_board_b.v（板级包装）
#       → yingxu_vq_board_top.v
# 构建前提：TD 工程定义 EMIT_HDMI 与 USE_ETH（顶层才有 eth_rxc 端口、
#           HDMI 核才被例化）。本文件**不做 Tcl 条件化**——实测 TD 的约束
#           应用阶段不支持 `if {...} {...}`（报 USR-8001 missing close-brace），
#           且带方括号的 pin 名在条件表达式里会被当命令替换。
#
# ★ 所有时钟名均已用 report 实测核对（P5 首轮综合，见
#   docs/YX_BBOARD_P5_TD_20261123.md §7）。改实例名会立刻失效，改完必须重跑
#   "打印时钟清单"核对。
#
# 实测时钟（7 个，全部由 create_clock/derive_pll_clocks 产生，无手写 pin 时钟）：
#   b_ref_clk_50m                                20.000ns  板载晶振
#   b_eth_rxc_125m                                8.000ns  PHY RGMII 接收钟
#   u_top/u_hdmi_pll/pll_inst.clkc[0]            10.000ns  HDMI PLL C0（仅 IP 内部反馈）
#   u_top/u_hdmi_pll/pll_inst.clkc[1]            13.643ns  像素域 73.33M（派生）
#   u_top/u_hdmi_pll/pll_inst.clkc[2]             2.727ns  HDMI 串行域 366.67M
#   u_top/u_sdram/sdram_pll1/pll_inst.clkc[0]    10.000ns  SDRAM 100M
#   u_top/u_sdram/sdram_pll1/pll_inst.clkc[1]    10.000ns  SDRAM 100M 相移
# =============================================================================

# -----------------------------------------------------------------------------
# 1. 主时钟与派生
# -----------------------------------------------------------------------------
create_clock -name b_ref_clk_50m  -period 20.000 -waveform {0.000 10.000} [get_ports {ref_clk}]
create_clock -name b_eth_rxc_125m -period  8.000                          [get_ports {eth_rxc}]

# 两个 PLL 的输出时钟自动派生（实测 5 个：sdram clkc[0]/clkc[1]、hdmi clkc[0]/[1]/[2]）
#
# ★★ 注意（P5 踩过）：若像素时钟网存在多驱动（例如 yx_b_scanout 的 rd1_clk 是
#   输出、顶层又把它接回 pixel_clk_w），TD 会断开驱动源把该网当无驱动常 0，
#   于是 clkc[1] 因"无负载"**不被派生**，整个像素域静悄悄地不进 STA。
#   现象是 b_pix_clk 端点=0、u_scanout 从层次表消失。修掉多驱动后派生即正常。
#   → 每次改完 RTL，务必重跑本文件的"打印时钟清单 + 端点计数"核对。
derive_pll_clocks

# -----------------------------------------------------------------------------
# 2. 异步时钟组（跨域均由设计内 CDC 承载，逐条注明依据）
#    注：任一 -group 为空会使整条 set_clock_groups 失效（USR-8225），
#        所以只写实测存在的时钟名。
# -----------------------------------------------------------------------------
# 2.1 SDRAM PLL 两输出之间（厂商控制器内部约定：clk0 逻辑域 / clk1 SDRAM 域）
set_clock_groups -name b_cdc_sdram_pll -asynchronous \
    -group [get_clocks {*sdram_pll1*clkc[0]}] \
    -group [get_clocks {*sdram_pll1*clkc[1]}]

# 2.2 板级 50M ↔ SDRAM 域：ref_clk 只进两个 PLL，无直接数据通路
set_clock_groups -name b_cdc_ref_sdram -asynchronous \
    -group [get_clocks {b_ref_clk_50m}] \
    -group [get_clocks {*sdram_pll1*clkc*}]

# 2.3 100M ↔ 73.33M 像素域：RD1 显示 FIFO 为 EG_LOGIC_FIFO 真双时钟 FIFO
set_clock_groups -name b_cdc_sdram_hdmi -asynchronous \
    -group [get_clocks {*sdram_pll1*clkc[0]}] \
    -group [get_clocks {*u_hdmi_pll*pll_inst*clkc[1]}]

# 2.4 50M ↔ 像素域（ref_clk → pll_hdmi1_4b 输入）
set_clock_groups -name b_cdc_ref_pix -asynchronous \
    -group [get_clocks {b_ref_clk_50m}] \
    -group [get_clocks {*u_hdmi_pll*pll_inst*clkc[1]}]

# 2.5 像素 73.33M ↔ 串行 366.67M：lane_lvds_10_1 设计内 CDC
#     （S_odd_even 2FF 同步、S_load_en 三级延迟后加载；两钟同 VCO 5:1，
#       相位确定）。A 板同类豁免实测通过（timing.sdc:13-18）。
set_clock_groups -name b_cdc_pix_serial -asynchronous \
    -group [get_clocks {*u_hdmi_pll*pll_inst*clkc[1]}] \
    -group [get_clocks {*u_hdmi_pll*pll_inst*clkc[2]}]

# 2.6 串行域 ↔ 其余：串行钟只在 lane_lvds_10_1 内部使用
set_clock_groups -name b_cdc_serial_others -asynchronous \
    -group [get_clocks {*u_hdmi_pll*pll_inst*clkc[2]}] \
    -group [get_clocks {*sdram_pll1*clkc[0]}] \
    -group [get_clocks {b_ref_clk_50m}]

# -----------------------------------------------------------------------------
# 3. 以太网域（RGMII 125M，PHY 提供 eth_rxc；只收不发）
# -----------------------------------------------------------------------------
# 3.1 RGMII 接收：DDR 源同步，数据直接进 IDDR（rgmii_to_gmii.v）。
#     ★★ 按厂商模板（TD 安装目录 template/Timing-Constraints/Input-Delay-Constraints/
#        set_input_delay.sdc 的 "RGMII network port" 示例）：
#        · 用**虚拟时钟**做 input delay 的参考，而不是端口时钟本身。用端口时钟做
#          参考时，TD 会把 FPGA 内部时钟插入延时（实测 RXC 到 IOB 3.705ns：
#          PAD 1.831 + 普通布线 1.874）算进捕获沿，hold 需求被推到 2.837ns，
#          而数据路径只有 1.075ns —— 必然违例且无法通过调整数值解决。
#        · 数据窗口取厂商值：max 0.5 / min −0.4（min 为负是正常的：数据与时钟
#          边沿对齐，±0.5ns 为板级偏斜）。
#     ★ 厂商模板另用 PLL 的 90° 相移时钟做数据中心对齐采样；本设计 IDDR 直接用
#       RXC，是否需要在 PHY 侧开 RXC 内部延时，**上板按 PHY 手册确认**。
create_clock -name b_eth_virtual_125m -period 8.000
set_input_delay -clock b_eth_virtual_125m -max 0.500 [get_ports {eth_rxd[*]}]
set_input_delay -clock b_eth_virtual_125m -min -0.400 [get_ports {eth_rxd[*]}]
set_input_delay -clock b_eth_virtual_125m -clock_fall -max 0.500 -add_delay [get_ports {eth_rxd[*]}]
set_input_delay -clock b_eth_virtual_125m -clock_fall -min -0.400 -add_delay [get_ports {eth_rxd[*]}]
set_input_delay -clock b_eth_virtual_125m -max 0.500 [get_ports {eth_rxdv}]
set_input_delay -clock b_eth_virtual_125m -min -0.400 [get_ports {eth_rxdv}]
set_input_delay -clock b_eth_virtual_125m -clock_fall -max 0.500 -add_delay [get_ports {eth_rxdv}]
set_input_delay -clock b_eth_virtual_125m -clock_fall -min -0.400 -add_delay [get_ports {eth_rxdv}]

# 3.2 125M ↔ 100M（SDRAM/视频逻辑域）：yx_b_eth_rx 异步字节 FIFO 承担跨域
set_clock_groups -name b_cdc_eth_sdram -asynchronous \
    -group [get_clocks {b_eth_rxc_125m}] \
    -group [get_clocks {*sdram_pll1*clkc[0]}]

# 3.3 125M ↔ 像素 / 50M：无直接数据通路（eth 只进 100M 域），一并声明
set_clock_groups -name b_cdc_eth_others -asynchronous \
    -group [get_clocks {b_eth_rxc_125m}] \
    -group [get_clocks {*u_hdmi_pll*pll_inst*clkc[1]}] \
    -group [get_clocks {b_ref_clk_50m}]

# 3.4 PHY 控制引脚（eth_rst_n / eth_mdc / eth_mdio）
#   eth_rst_n : 纯静态电平，无需约束。
#   eth_mdc   : yx_b_mdio 输出，2.5MHz（半周期 20 clk @100MHz = 200ns），由 clk100
#               域寄存器直接驱动，TD 按 clk100 自动分析（裕量 20 个周期）。
#   eth_mdio  : ★ P5 起为三态（原为恒 1 静态电平）。Clause 22 读操作由 PHY 在
#               MDC **下降沿**驱动、FPGA 在 **上升沿**采样 —— 采样点距数据翻转
#               200ns（= 20 个 clk100 周期），相对 RGMII 的 4ns 数据眼是 50 倍裕量。
#               约束按"参考沿 = MDC 下降沿，PHY 输出在其后 5~195ns 内有效"写：
#               真实 Tco 量级 1~10ns，上界 195ns 取得很松（采样沿在 200ns 处）。
#               ★ 为什么 -min 不取真实值（~1ns）：TD 的输入保持模型是
#                 hold_slack = input_delay_min + clk_min − (clk_max + hold)，
#                 要求 input_delay_min ≥ 2.837ns（与 §3.1 RGMII 同一模型）。
#                 取 5.000 既满足模型、又落在物理窗口（0~200ns）之内。
#               ⚠ 待下次 TD 运行核对本段是否按预期通过（P5 只做仿真，未跑 STA）。
create_clock -name b_mdio_virtual -period 400.000
set_input_delay -clock b_mdio_virtual -max 195.000 [get_ports {eth_mdio}]
set_input_delay -clock b_mdio_virtual -min   5.000 [get_ports {eth_mdio}]

# -----------------------------------------------------------------------------
# 4. SDRAM 引脚（沿用 A 板做法：不设 output delay，控制器内部时序保证）
# -----------------------------------------------------------------------------
# 若首份 STA 报 SDRAM 引脚建立/保持不足，再按 AC601 走线补：
# set_output_delay -clock [get_clocks {*sdram_pll1*clkc[0]}] -max 1.500 [get_ports {DRAM_*}]
# set_output_delay -clock [get_clocks {*sdram_pll1*clkc[0]}] -min 0.500 [get_ports {DRAM_*}]
# 注：SDRAM 走 EG4S20 专用硬接口，DRAM_* 引脚不在 IO_b.adc 里。

# -----------------------------------------------------------------------------
# 5. 异步复位与静态信号
# -----------------------------------------------------------------------------
# rst_n 是异步复位，直连各域复位端（无同步器），false_path 避免
# recovery/removal 违例。若后续改为各域复位同步器，可移除此条改约束同步链。
set_false_path -from [get_ports {rst_n}]

# -----------------------------------------------------------------------------
# 6. HDMI TMDS 输出与 DDC
# -----------------------------------------------------------------------------
# TMDS 由 lane_lvds_10_1 的 DDR 输出级直接送 IO（A 板同款），不做 output delay；
# 引脚（IO_b.adc）：tmds_ch0_p=D11 / ch1_p=C11 / ch2_p=F10 / clk_p=B10，LVDS33_E。
# DDC（tmds_ddc_scl / tmds_ddc_sda）当前不启用（I_edid_read_trig 恒 0），
# 接入后需在 IO_b.adc 补引脚并注意 SDA 为 inout、外部上拉。
