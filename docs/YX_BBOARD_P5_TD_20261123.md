# YX_BBOARD_P5_TD_20261123 — 板 B TD 综合与 STA（P5）

> 会话：2026-11-23（P5 准备；引脚事实已确认）
> 前置：`docs/HANDOFF_20261123.md`、`docs/YX_BBOARD_P4_ETH_20261123.md`
> 状态：**骨架与约束就绪**；正式综合只差「安路 IP 库里的加密 HDMI 核」。

## 1. 硬件构型（已确认）

- **B 板 = AC601 核心板 + AC201 载板，与 A 板同构 → 引脚等同 A 板**，
  不需要另找引脚表；
- 仓库根 `IO.adc`（A 板，128 行）已含全部所需条目与电平标准；
- **SDRAM 不占通用引脚**：EG4S20 专用 SDRAM 硬接口，`sdram_ip.v` 内
  `EG_PHY_SDRAM_2M_32` 由 TD 自动映射；
- 原始数据（核对用）：`C:\Users\HXF\Desktop\YX-tool\AC201-EG4S20管脚信息表.xlsx`、
  `D:\pin_table.txt`、厂商示例 `AC201_AL_board_test/IO.adc` 与 `timing.sdc`。

**仍然缺的一项**：加密 HDMI 核 `hdmi_1_4b_transmitter_core_wrapper.enc.v`
（按红线已从历史移除、不得再入库），本地综合需从安路 IP 库导入。仿真构建
不依赖它（`ifdef EMIT_HDMI` 门控）。

## 2. 本轮交付的骨架

### 2.1 EMIT_HDMI 分支补全（`media/vp/yingxu_vq_board_top.v`）

P3 遗留块把 PHY 输出接到**未声明的内部 wire**（`tmds_chN_p_w`）、且缺 DDC 端口。
现补齐：

- 顶层常驻端口：`tmds_ch0_p / ch1_p / ch2_p / clk_p`、`tmds_ddc_scl`(out)、
  `tmds_ddc_sda`(inout)；
- `EMIT_HDMI=1`：AXIS → 加密核（A 板同参数：1650×750、HSA40/HFP110/HBP220、
  VSA5/VFP5/VBP20、VIC69、RGB、TPG Disable、48K）→
  `hdmi_phy_wrapper #(.DEVICE("EG"))` → TMDS 端口；DDC 接核；
- `EMIT_HDMI=0`（仿真）：TMDS/DDC_SCL 恒 0，DDC_SDA 高阻。

验证：用与厂商核/`lane_lvds_10_1` 端口一致的临时 stub（`out/p5_stub_hdmi.v`，
不入库）做 `-DEMIT_HDMI -s yingxu_vq_board_top` elaboration → 通过。**只证明
本顶层连线正确，不是加密核功能验收。**

### 2.2 引脚约束 `IO_b.adc`（仓库根，新增）

按"B 板引脚 = A 板"从 `IO.adc` 裁剪，端口名对齐 B 顶层（`ref_clk`、`tmds_*` 无 `O_` 前缀）：

| 组 | 条目 |
|---|---|
| 时钟/复位 | `ref_clk`=K14、`rst_n`=H14 |
| HDMI TMDS | `tmds_ch0_p`=D11、`ch1_p`=C11、`ch2_p`=F10、`clk_p`=B10（**LVDS33_E**） |
| 以太网 RGMII | `eth_rxc`=F9、`eth_rxd[3:0]`=F12/H16/G16/F15、`eth_rxdv`=E12 |
| PHY 控制 | `eth_rst_n`=C15、`eth_mdc`=C16、`eth_mdio`=D14 |

删除的 A 板专有项：I2S、camera_*、SRAM、seg7、IIC、SD、UART、LED、KEY、SW、
BEEP、IR、gpio_*、TFT。**SDRAM 不写**（专用硬接口）。
DDC 两脚暂不约束（当前 `I_edid_read_trig` 恒 0），启用时再补（SDA 为 inout + 外部上拉）。

### 2.3 顶层以太网接入（`-DUSE_ETH`，默认关闭）

P4 的 `yx_b_eth_rx` 原先只在 TB 里例化。现按编译宏门控接进顶层：

- 新增端口：`eth_rxc / eth_rxd[3:0] / eth_rxdv`（输入）、
  `eth_rst_n / eth_mdc / eth_mdio`（输出）；
- `-DUSE_ETH`：`yx_b_eth_rx #(.USE_RGMII(1))` 例化在 `REAL_IX` 内，
  RGMII → GMII（IDDR）→ 异步 FIFO → `hdr_parse`；`stream_*` 端口置 0；
  PHY 复位跟随 `rst_n`，MDC/MDIO 空闲高；
- **不定义 `USE_ETH`**：与 P4 验收基线**逐位一致**（码流仍由 `stream_*` 外部驱动）。

验证：默认构建 `bboard_key` 回归 ALL PASS；`-DEMIT_HDMI -DUSE_ETH` 用 stub
elaboration 通过（RGMII 路径含 `rgmii_to_gmii` + IDDR shim）。

### 2.4 时钟约束 `timing_b.sdc`（更新）

以仓库 A 板 `timing.sdc` 为基础（非厂商示例——厂商只给 pixel/serial 两域，不够）：

- `b_ref_clk_50m`（ref_clk）+ `derive_pll_clocks`；
- 异步组：SDRAM PLL 双输出、50M↔SDRAM、**100M↔73.33M（RD1 真双时钟 FIFO）**、
  50M↔HDMI、73.33M↔366.67M（lane_lvds 设计内 CDC）；
- **新增 125M 以太网域**：`b_eth_rxc_125m`（`eth_rxc` 端口）+ RGMII 输入
  delay 占位（2.0/0.5 ns，上板按 PHY 手册校准）+ **125M↔100M 异步组**
  （`yx_b_eth_rx` 异步 FIFO 承担跨域）+ 125M↔其余域组；
- 注意：§3 生效前提是 `-DUSE_ETH` 构建（否则端口不存在，需注释该节）；
- 首次 TD 运行后须核对 `report_qor` 的派生时钟名（`clkc[*]` vs `plkc[*]`）。

## 3. 拿到加密核后的执行顺序（★ 红线在第 4 步）

1. 建 B 板 TD 工程（EG4S20 / AC201 载板 + AC601 核心板），源单见 §4；
2. 顶层 `yingxu_vq_board_top`，**`-DEMIT_HDMI -DUSE_ETH`**；
3. 导入加密 HDMI 核（安路 IP 库）；
4. **★★ 红线 ★★**：挂 `IO_b.adc` + `timing_b.sdc`，先 `report_qor -step place`
   或 `report_clocks`，**打印实际时钟名列表**，逐条核对 `timing_b.sdc` 里的
   glob 是否命中正确时钟：
   - `*sdram_pll1*clkc[0]` 应为 100M SDRAM 域；
   - `*u_hdmi_pll*pll_inst*clkc[1]` 应为 73.33M 像素域（RTL 只用 `clk1_out`）；
   - `*u_hdmi_pll*pll_inst*clkc[2]` 应为 366.67M 串行域（RTL 只用 `clk2_out`）。
   
   **若真 PLL IP 把 `clk1_out` 映射到 `clkc[0]` 而非 `clkc[1]`，所有 HDMI 相关
   异步组会声明错对象且不报错**（例如"100M 与 100M 异步"无意义，而真正需要的
   100M↔73.33M 变成被时序分析）。不对立即按实际名称改 glob 或用
   `get_clocks -of_objects [get_pins ...]`。
5. 时钟名核对无误后，出首份资源/时序报告（**不烧录、不出 bit**；只报告）；
6. 用 `report_timing -from ... -to ... -input` 核对 RGMII 双沿 input delay 生效。

## 4. TD 源单（建议）

```
yingxu_vq_board_top.v
 yx_vp_band.v / yx_vp_ixbuf.v / yx_vp_ixdec.v
 yx_b_hdr_parse.v / yx_b_ix_seq_wr.v / yx_b_ix_fetch.v
 yx_b_scanout.v / yx_b_scanout_play.v
 yx_b_eth_rx.v                     （-DUSE_ETH）
 eth_udp_rx_gmii.v / ip_checksum.v / crc32_d8.v / rgmii_to_gmii.v   （-DUSE_ETH）
 video_source_test.v / hdmi_phy_warpper.v / lane_lvds_10_1.v
 5640/sdram_ctrl_4p/*.v（sdram_ip/command/control_interface/sdr_data_path/
   Sdram_PLL/Sdram_WR_FIFO/Sdram_RD_FIFO）
 al_ip/*（IP，按 TD 工程方式加入：pll_hdmi1_4b、BUFG_0、IDDR_0、EG_LOGIC_FIFO 等）
```

注意：仿真 shim（`tb/bshims/*`）**不得**加入 TD 工程；TD 用厂商原语。

## 5. 以太网 bring-up 缺口（首板上板时处理，非综合阻塞）

1. **RGMII 发送未实现**：RGMII 需要 MAC 侧 125MHz TX 时钟（`eth_gtxc`），本板
   现有 PLL 无 125M 输出 → 只收不发。需要发送时在 pll_hdmi1_4b 或新增 PLL
   里加 125M 支路，并补 `gmii_to_rgmii` + txd/txen 引脚。
2. **MDIO 未实现**：RGMII PHY 通常需配置寄存器（接口模式、RXC 内部延迟、
   自协商），当前 MDC/MDIO 恒高。上板前按 PHY 型号补 MDIO 写序列，并把
   `timing_b.sdc` 的输入 delay 校准到实测值。
3. **PHY 型号待确认**（AC201 载板）：决定 MDIO 寄存器表与 RXC delay 方案。
4. **RXC 双缓冲路径**：`eth_rxc` 同时进 `rgmii_to_gmii` 的 IDDR（采样）与
   `eth_udp_rx_gmii` 内的 `BUFG_0`（逻辑时钟）——与 A 板厂商示例同构、A 板
   实机已验证；若首份 STA 报两路时钟偏斜吃紧，改为顶层单缓冲后分发。
5. `video_user` / `video_last` 相位：接加密核后按核实际采样点校准
   （实测把 user 一并延迟会引入 4 拍错位）。
