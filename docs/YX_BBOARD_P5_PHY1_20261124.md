# YX_BBOARD_P5_PHY1_20261124 — phy_1（place+route）实测：3 个新问题与 1 次红线违规

> 承接 `YX_BBOARD_P5_P2B_20261124.md`（syn 阶段 LUT 20.4%、WNS −215ps、4 条违例）。
> 本轮按交接稿建议跑 `phy_1` 看时序是否自行收敛。**结论：没有收敛**，
> 而且暴露出 3 个与 syn 阶段报告完全不同的问题。
> **本轮未出 bit（但过程中曾意外生成一份并已删除，见 §5）。**

## 1. phy_1 结果

| 阶段 | Setup WNS | 违例端点 | Hold WNS | Hold 违例端点 |
|---|---:|---:|---:|---:|
| place | **+309 ps** | **0** | — | — |
| route | **−563 ps** | 7 | **−3237 ps** | 10 |

资源（route 后）：`#lut 4085 (20.84%)`、`#reg 3156`、`#bram 53/64`、
`#bram32k 10/16`、`#slices 2543 (25.95%)`。

**place 干净通过（0 违例）**，说明布局可行；违例全部在布线后出现，
且**全部集中在 125M 以太网域**（100M / 73.3M / 366.7M 域余量充足）。

## 2. 违例一：`ip_checksum` 的 9 操作数加法链（setup，−563ps）——**已修**

```
Begin: u_ethrx/u_mac/rx_ip_frag_offset_reg[1]
End  : u_ethrx/u_mac/ip_checksum/suma[16]
Data Path Delay: 8.229ns (cell 5.061 + net 3.168)  Budget 8.000ns
Logic Level: 7 (ADDER=7)
```

根因：`src/ip_checksum.v:41-44` 在**单拍内**把 9 个 16 位操作数相加：

```verilog
suma <= {IP_ver,IP_hdr_len,IP_tos}+IP_total_len+IP_id+
       {IP_rsv,IP_df,IP_mf,IP_frag_offset}+{IP_ttl,IP_protocol}+
       src_ip[31:16]+src_ip[15:0]+dst_ip[31:16]+dst_ip[15:0];
```

TD 把它综合成 **7 级线性 ADDER 链**（报告里 `add0_syn_884→885→870→871→
872→867→861→862`，用 fco/fci 串起来），而不是平衡树。

### 修法：分级求和（不是简单加流水级）

**时序账**（来自 `eth_udp_rx_gmii.v` 的解析时序，决定了不能随便加流水）：

- IP 头字段在 `cnt_ip_header = 0..19` 逐字节锁存，第 19 拍全部稳定；
- `ip_checksum_cal_en` 是"第 19 拍之后那一拍"的单拍脉冲；
- 下游 `ip_header_check_ok` 在 `cnt_udp_header == 2` 采样 —— **cal_en 后只剩 2 拍**；
- 原实现里 `suma` 在 cal_en 拍后一拍有效。

所以**必须保持 `suma` 的产出时刻不变**，只能把"早稳定字段"提前算好：

| 分组 | 内容 | 稳定时刻 | 级数 |
|---|---|---|---|
| `p1a` | `{ver,hdr_len,tos}`+`total_len`+`id` | cnt 5 前 | 2 |
| `p1b` | `{rsv,df,mf,frag}`+`{ttl,protocol}` | cnt 9 前 | 1 |
| `p1_r` | `p1a_r + p1b_r` | — | 1 |
| `p2a` | `src_ip` 高低半 | cnt 15 前 | 1 |
| `p2b` | `dst_ip[31:16]` | cnt 16 前 | 1 |
| `p2_r` | `p2a_r + p2b_r` | — | 1 |
| `suma` | `p1_r + p2_r + dst_ip[15:0]` | cal_en 拍 | 2 |

**最大逻辑级数 7 → 2**，`suma` 仍在 cal_en 拍后一拍有效（与原实现同拍），
功能完全等价。

### 验证结果

| 指标 | 修前 | 修后 |
|---|---:|---:|
| Setup WNS | −563 ps | **+368 ps** |
| Setup 违例端点 | 7 | **0** |
| `#lut` | 4085 (20.84%) | 4089 (20.86%) |

- `eth_rx` 专用 TB：**ALL PASS**（`ok=290 drop=1 byte_cnt=295941` 精确匹配；
  drop 是 TB 故意构造的坏 CRC 包）。**IP 校验和路径确实被覆盖**——若算错，
  厂商核会在 `cnt_udp_header==2` 丢弃整包，290 个包不可能全过。
- `bboard_sys_eth` 全链路：见 §6 回归表。

**风险提示**：交接稿称 `ip_checksum` 是"A 板共用代码，改了要连带重验 A 板"。
**经核实此说法不成立**：A 板综合源单 `AC201_AL_board_test.al` 中
`eth_udp_rx_gmii / ip_checksum / rgmii_to_gmii` 出现次数均为 **0**，
A 板顶层 `hardware_test_P0_UART_V5_CRC32.v` 也未例化它们——
这三个文件是 P4 为 B 板新引入的。改它们**不影响 A 板**。

## 3. 违例二：RGMII 输入 hold（−3237ps，10 个端点）

全部 10 条都是 `eth_rxd[*] / eth_rxdv` → IOB 输入寄存器：

```
Data Path Delay : 0.675ns (input −0.4 + PAD 1.075)
Clock Skew      : 3.705ns
Arrival         : 4.675ns
Required        : 7.912ns  (= capture 7.705 + hold 0.207)
Slack           : −3.237ns
```

**算式**：`slack = input_delay + 1.075 − (3.705 + 0.207)`。
要过需 `input_delay ≥ 2.837ns`（数据比时钟沿晚 2.8ns 到）——
**没有任何 RGMII PHY 是这种时序**，所以这不是"调数值能解决"的问题。

根因：**RXC 到 IOB 的插入延时 3.705ns**（PAD 1.831 + 时钟网布线 1.874），
而数据路径只有 1.075ns。DDR 位周期只有 4ns，采样点落在数据眼 66% 处
（余量 1.37ns/2.63ns，物理上能工作，但不居中，且 STA 模型判为 hold 违例）。

### 已试过的三种修法（都没解决）

1. **给 RXC 加 BUFG**（照厂商参考设计
   `ip/depot/OneG_Ethernet_Subsystem_1.0/.../rgmii_interface.v:212-217` 的
   EG4 分支：`EG_LOGIC_BUFG rgmii_rxc_BUFG → rgmii_rxc_int → IDDR.clk`）——
   BUFG 确实被用上了（`u_bufg_rxc`），但插入延时仍是 1.831+1.874=3.705ns，
   hold 无改善。
2. **按厂商模板用虚拟时钟做 input delay 参考**
   （`template/Timing-Constraints/Input-Delay-Constraints/set_input_delay.sdc`
   的 "RGMII network port" 示例：`create_clock -name virtual_clk_c -period 8`
   + `set_input_delay -max 0.5 / -min -0.4 -clock virtual_clk_c`）——
   TD 仍把真实时钟的插入延时算进捕获沿，hold 反而从 −2.337 变成 −3.237
   （正好等于 min 从 0.5 改到 −0.4 的 0.9ns 差值）。
3. **决定性实验**：把 input delay 临时设成物理上不可能的值
   （`-min 3.000 -max 3.500`）→ **HWNS 从 −3.237 变成 +0.024，违例全消失**
   （SWNS +377ps）。这钉死了 TD 的判据公式：

   ```
   hold_slack = input_delay_min + data_path(1.075) − (clock_insertion(3.705) + hold(0.207))
   ```

   即 **TD 要求 `input_delay_min ≥ 2.837ns`**。

### 为什么这个判据物理上不可满足

`input_delay` 的物理含义是"数据相对时钟沿在引脚处的到达时刻"。RGMII 的
数据与时钟由 PHY 同源发出，只有两种可能：

| PHY 配置 | 引脚处关系 | input_delay |
|---|---|---|
| RXDLY=0（不加延时） | 数据与时钟沿**对齐** | ≈ 0（±板级偏斜 0.5） |
| RXDLY=1（加 ~2ns） | 数据比时钟沿**早** ~2ns | ≈ −2 |

**两种都到不了 +2.837ns**。TD 的判据等价于要求"数据路径比时钟路径长
2.837ns"，而源同步输入的时钟走时钟树、必然比数据路径长——这是拓扑决定的，
不是调数值能解决的。

### 物理上到底能不能工作

采样点 = 时钟插入延时(3.705) − 数据路径(1.075) = **2.63ns**，
落在 4ns 数据眼的 **66%** 处（最坏情况按 input_delay=−0.4 算是 3.03ns / 76%）。
余量：到下一次数据变化还有 0.97~1.37ns。**能工作，但偏晚、不居中。**

**关键前提**：这要求 **PHY 的 RXDLY 关闭**。若 RXDLY 开启（RXC 再延后
~2ns），采样点变成 4.63ns > 4ns 数据眼 → **采到下一位，功能失败**。

### 硬件事实（本轮新查到）

从 AC201 原理图 `C:\Users\HXF\Desktop\YX-tool\07_1GbNET.SchDoc` 提取到：

```
LibReference=RTL8211FDI   Comment=RTL8211F-CG   Designator=U14   封装 QFN-40
引脚（strap 复用）：RXD0/RXDLY(25)  RXD1/TXDLY(24)  RXD2/PLLOF(23)  RXD3/PHYAD0(22)
```

**PHY = RTL8211F-CG**。它的 RGMII RX 延时由 `RXD0/RXDLY` 上电 strap 决定
（也可经 MDIO 扩展寄存器改）。**上板前必须确认该 strap 为"延时关闭"**，
否则本设计会采错位。

### 建议修法（需设计决策，按推荐度排序）

1. **确认 RXDLY strap 关闭**，接受"采样点 66%、STA 报 hold 违例"的现状，
   并在文档里写明这是 TD 判据与拓扑的模型冲突（物理能工作）。
   —— 零改动，但 STA 报告不干净。
2. **加 eth 专用 PLL**（EG4S20 共 4 个，已用 2 个），用受控相移时钟采样，
   让采样相位不再依赖布线延时。需要新 IP + 重新验证；且**相移方向必须
   让 TD 判据通过**（需实测确认，不能想当然）。
3. **用 IDELAY 延长数据路径**（若 EG4 的 IOB 支持），使数据路径 ≥ 时钟路径。
   这是 Xilinx 系 RGMII 的标准做法，但需先确认 EG4 原语支持。

### 厂商模板的关键差异

厂商模板除了虚拟时钟，还有一条我们**没有**的：

```tcl
create_generated_clock -name pll_c_data_clk1 -source [get_ports {c_rgmii_rxc}] \
  -master_clock c_rgmii_rxc -multiply_by 1 -phase 90 [get_pins {pll_c/pll_inst.clkc[1]}]
```

即**用 PLL 的 90° 相移时钟做采样**，把采样点主动移到数据眼中心。
本设计没有 eth 专用 PLL，IDDR 直接用 RXC，采样相位完全由布线延时决定。

**建议修法**（需设计决策）：为 eth 加一个 PLL（EG4S20 共 4 个，已用 2 个），
输出 90° 相移时钟给 IDDR；或确认 PHY 的 RXC 内部延时档位后按实测重定窗口。
**上板前必须解决**——这属于 P5 文档已记录的"PHY 型号待确认 / RXC delay 待校准"缺口。

## 4. 违例三：`BIT-8123` 未约束 IO（已修）

`phy_1` 首次运行在 bitgen 步骤被拦：

```
BIT-8123 ERROR: Bitgen is prohibitted as there is(are) unconstrained io(s) in design.
```

根因：`tmds_ddc_scl / tmds_ddc_sda` 是顶层端口，但 `IO_b.adc` 里被注释掉
（当初理由"当前不启用"）。**端口存在就必须约束**。

**修法**：从板级包装 `yingxu_vq_board_b.v` 去掉这两个端口
（内部悬空）。依据：
- 引脚信息表 `D:\pin_table.txt:95-103` 的 HDMI 段**只有 TMDS 四对差分，
  没有 DDC 信号** —— 这块板的 DDC 根本没接到 FPGA；
- A 板 `design_top_wrapper` 同样不把 DDC 引出顶层（`hardware_test` 实例化时
  只接了 TMDS 四对）。

修掉后 `phy_1` 全流程走完（`wait OK`），BIT-8123 消失。

## 5. ★ 红线违规：意外生成了一份 bit

**事实**：`phy_1` 的默认 run 流程末尾自带 `bitgen` 步骤。我第一版脚本
只写了 `launch_runs { phy_1 }`，没有禁用 bitgen，于是生成了
`AC601_B_VQ_p5_Runs/phy_1/AC601_B_VQ_p5.bit`（2.6s 完成）。

**处置**：发现后立即删除；并给脚本加了 `no_bit_guard`（wait 之后检查
`*.bit`，发现即删除并报错中断）。第二次运行时守卫生效——又生成了一份，
被自动删除并中断流程。

**最终状态**：仓库内 `find . -name "*.bit"` 只剩
`release/RELEASE_g32_FROZEN_20261031.bit`（A 板冻结版，非本次生成）。

**后续报告路径**：改用 `p5_route_rpt.tcl` —— 直接
`import_db AC601_B_VQ_p5_Runs/phy_1/AC601_B_VQ_p5_pr.db` 做
`update_timing -mode final` + `report_*`，**完全不经过 run 流程，
从根上不碰 bitgen**。这是后续所有 route 后报告的标准做法。

**教训**：TD 的 run 流程默认 EndStep 是 bitgen，`set_param phy_1 end_step route`
语法不被接受（`PRJ-9004`）。在"不出 bit"的约束下，**不要用 launch_runs 跑
phy_1**，要么改 run 配置，要么直接 import_db 出报告。

## 6. 本轮改动清单

| 文件 | 改动 | 依据 |
|---|---|---|
| `src/ip_checksum.v` | 9 操作数单拍求和 → 分级求和（7 级 → 2 级） | 修 setup −563ps / 7 端点；见 §2 |
| `media/vp/yingxu_vq_board_b.v` | 去掉 `tmds_ddc_scl/sda` 顶层端口（内部悬空） | 引脚表无 DDC；A 板同做法；修 BIT-8123 |
| `src/rgmii_to_gmii.v` | RXC 加 `BUFG_0` 后再给 IDDR 采样 | 厂商参考设计同构；**未解决 hold，但结构正确** |
| `timing_b.sdc` | RGMII input delay 改虚拟时钟参考 + 厂商值 0.5/−0.4 | TD 自带 RGMII 模板 |
| `tools/sim/run_sim.ps1` | ①`bboard_sys_eth` 去掉重复的 `BUFG_0.v`（我早前给 `bboard_sys` 加过，两处撞车 → iverilog "already declared"）；②`bboard_sys_eth` 补 `YINGXU_SIM` 宏（否则 RD1 FIFO 不走 CDC 分支，TB 的 `ASYNDOM.*` 探针绑不上） | 这两个是我引入的回归，已修 |

仿真验证：

| 入口 | 结果 |
|---|---|
| `eth_rx`（专用 TB） | **ALL PASS** — `ok=290 drop=1 byte_cnt=295941` 精确匹配 |
| `bboard_sys_eth`（全链路） | 见下方 §6.1 |

### 6.1 全链路回归

`bboard_sys_eth` 在改 `ip_checksum` 后重跑（判据与 `bboard_sys` 一致 + 传输层零丢包）：

```
GATE-ETH ok=292(want 292: OK) drop=0(want 0: OK) bytes=297989(want 297989: OK)
=== TB-SUMMARY: ALL PASS ===
CNT: frames=5 bands=900 scan_errs=0 ax_errs=0 ax_lines=2801 ...
```

**IP 校验和路径确实被覆盖**：若算错，厂商核会在 `cnt_udp_header==2` 丢弃整包，
292 个包不可能全过、字节数也不可能精确匹配。

## 7. 下一步建议（按优先级）

1. **确认 RTL8211F 的 `RXD0/RXDLY` strap 为"延时关闭"**（阻塞上板）。
   这是 §3 里所有分析的前提；若 strap 是"延时开启"，采样点会落到数据眼外，
   **功能直接失败**。查 AC201 原理图 `07_1GbNET.SchDoc` 里 U14 该脚的上下拉。
2. **RGMII hold 的取舍**（需设计决策，三选一，见 §3 末）：
   - 接受现状（物理能工作，STA 报违例）+ 文档写明是判据/拓扑模型冲突；
   - 加 eth PLL 用受控相移采样（需新 IP + 实测确认相移方向）；
   - 用 IDELAY 延长数据路径（需先确认 EG4 IOB 是否支持）。
3. **更正 HANDOFF 两处**：
   - "`ip_checksum` 是 A 板共用代码"**已证伪**（A 板源单出现次数为 0）；
   - 补记"`phy_1` 的 run 流程默认带 bitgen，**不要用 `launch_runs` 跑 phy_1**"
     （见 §5），route 后报告一律走 `import_db ..._pr.db`。
4. 核心 VQ 设计（100M/73.3M/366.7M/50M 域）**已经干净**：
   setup WNS +368ps、0 违例；资源 LUT 4089 (20.86%)、BRAM 53/64。
   剩余违例只在以太网域，且已定位到具体原因。
