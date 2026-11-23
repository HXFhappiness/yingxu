# YX_BBOARD_P5_TD_20261123 — 板 B TD 综合与 STA（P5）

> 会话：2026-11-23（P5 首轮综合打通 + 时钟红线核对 + 资源评估）
> 前置：`docs/HANDOFF_20261123.md`、`docs/YX_BBOARD_P4_ETH_20261123.md`
> 状态：**综合链路已打通并出报告**；时序无法评估（资源超限，见 §8）。
> 结论摘要：时钟约束已按实测校正（修掉两个真实缺陷）；设计**装不下**
> （MSlice 14152 / 上限 4900），热点是三块被映射成分布式 RAM 的存储器。

## 1. 硬件构型（已确认）

- **B 板 = AC601 核心板 + AC201 载板，与 A 板同构 → 引脚等同 A 板**；
- 仓库根 `IO.adc`（A 板，128 行）已含全部所需条目与电平标准；
- **SDRAM 不占通用引脚**：EG4S20 专用 SDRAM 硬接口，`sdram_ip.v` 内
  `EG_PHY_SDRAM_2M_32` 由 TD 自动映射（综合报告里显示为 `pad 21`）；
- 加密 HDMI 核 `hdmi_1_4b_transmitter_core_wrapper.enc.v` 已本地导入
  （按红线不入库，`.gitignore` 屏蔽）；TD 能正常解出其中的子模块。

## 2. TD 构建入口（关键：不能再直接拿 `yingxu_vq_board_top` 当顶层）

### 2.1 板级包装 `media/vp/yingxu_vq_board_b.v`（新增）

只引出 `IO_b.adc` 里的板级引脚，内部例化 `yingxu_vq_board_top`
`#(.SIM_ABSTRACT(0))`。原因：

- 原顶层默认为**仿真模式**（`SIM_ABSTRACT=1`），且带一堆 TB 观测/抽象口
  （`stream_*`、`ix_wr_*`、`cp_*`、`band_rd_*`、`video_*`、`dbg_*`），
  直接综合会得到一个跟验收过的设计完全不同的东西；
- 顶层带 `YINGXU_B_BOARD_BUILD_REQUIRES_DEFINE_*` 守卫：**必须**定义
  `EMIT_HDMI` 与 `USE_ETH`，否则显式报错（防止无声地综合被大面积裁剪的设计）。

### 2.2 宏怎么传

- 非工程流（本会话实际用的）：`analyze -file <f> -define "EMIT_HDMI USE_ETH"`。
- `add_define`/`set_defines` **在非工程流不生效**（实测 elaborate 时守卫仍触发）。
- 工程流下 `set_defines` 同样未生效（待查 .al 的宏字段）；因此本轮用非工程流。

## 3. 三个「不可综合」的真实缺陷（都已修）

### 3.1 层次引用（TD 完全不支持）

最小用例实证：`u_sub.r` 在非工程流与工程流都报
`HDL-8007 ... external connection to net ... is not allowed`。
原顶层有 **8 处 `u_sdram.*` + 7 处 `u_band.*`**。用户侧最初只看到
`write_fifo1.logic_fifo.SAMEDOM.rp_bin` 一处，是因为 TD 对同一模块只报首条。

处置：

| 引用 | 处置 |
|---|---|
| `u_sdram.IN_REQ / WR_MASK / RD_MASK / OUT_VALID / mWR_DONE / mWR` | 派生控制器副本加 `st_*` 状态输出口（见 §4） |
| `u_band.base_l` / `u_band.pend_cnt` | `yx_vp_band` 加 `frame_base` / `pend_cnt_o` 输出 |
| `u_band.frame_start` / `render_no` | 本来就已是输出端口，改用端口名 |

### 3.2 同一 reg 被两个 always 块驱动

`yx_vp_ixbuf.v` 的 `pf_ov/pf_od`（主 FSM 复位分支 + 补丁输出寄存器块）。
iverilog 当竞态容忍，TD 报 `HDL-8007 ... constantly driven from multiple places`。
两处复位值相同 → 删掉主块里重复的那份，零行为变化。

### 3.3 时钟网多驱动（★ 最隐蔽，仿真完全看不出来）

`yx_b_scanout` 的 `rd1_clk` 是**输出**（`assign rd1_clk = pixel_clk;`），
顶层又写 `.rd1_clk(pixel_clk_w)` 把它接回**同一根**网 → 与 PLL 输出构成多驱动。
仿真因两值恒等而毫无症状；TD 报：

```
SYN-5066 CRITICAL-WARNING: Disconnect the driver 'u_top/u_hdmi_pll/pll_inst'
          of the multi-driven net 'u_top/u_scanout/rd1_clk'
SYN-5013 WARNING: Undriven net ... rd1_clk
SYN-5025 WARNING: Using 0 for all undriven pins and nets
```

后果：`rd1_clk` 被当常 0 → **整个像素域（扫出/播放/视频源/HDMI 核输入）
被判为死逻辑清除**，报告里 `b_pix_clk` 端点=0、`u_scanout` 从层次表消失。
修复：`rd1_clk` 单独一根线 `rd1_clk_w`，并同时用于控制器 `RD1_CLK`。

> 教训：这类问题只有"时钟清单 + 端点计数"能抓到。任何一次 RTL 改动后
> 都必须重跑 §6 的核对，不能只看"综合成功"。

## 4. 控制器：仿真与综合必须是同一份代码（新增派生副本）

事实：`tb/bshims/Sdram_Control_4Port.v` 在厂商原件上打了 P3 三处修补，
而 `src/5640/sdram_ctrl_4p/` 里的厂商原件没有：

1. `CS_N` 端口标量 → `[1:0]`（内部本就是 2 位 reg）；
2. RD1（显示）读 FIFO afull 水线 128 → 300；
3. `rd1_turn` 仲裁轮转 + 「RD1 兜底」分支（防显示被写端饿死）。

若按厂商原件综合，上板行为就是**没有 P3 修补的旧版**（disp_stall 上升、
像素流相位撕裂）——仿真全绿也没意义。

处置：新增 `src/5640/sdram_ctrl_4p/b_board/`

- `Sdram_Control_4Port_b.v`（module `Sdram_Control_4Port_B`）=
  厂商原件 + P3 三处 + `st_in_req/st_out_valid/st_wr_mask/st_rd_mask/
  st_wr_done/st_wr` 六个状态输出口；
- `Sdram_RD_FIFO_b.v`（module `Sdram_RD_FIFO_B`）= 厂商原件 + `AF_W` 参数
  （CDC 参数只在 `YINGXU_SIM` 下透传给 EG_LOGIC_FIFO 仿真模型，真实硬 FIFO 无此参数）。

厂商原件与 A 板**零改动**。仿真源单已切到该副本（`run_sim.ps1`，
`sdctrl_sanity` 也改测它），宏 `YINGXU_SIM` 仅用于 CDC 透传。

## 5. `timing_b.sdc`：按实测重写（★ 红线执行结果）

### 5.1 TD 的 SDC 不吃 Tcl 条件化

原骨架用 `if {[llength [get_ports -quiet eth_rxc]] > 0} { ... }` 包裹以太网段。
实测 `optimize_rtl` 直接报 `USR-8001 ERROR: Tcl error: missing close-brace`，
整条约束流程失败。**结论：SDC 里不要写 Tcl 控制流**；本文件改为
「该 SDC 只适用于定义 `USE_ETH` 的构建」，写死在注释里。

### 5.2 空 `-group` 会让整条 `set_clock_groups` 失效

`USR-8225 ... only one -group remains valid ultimately. This entire command
turns out invalid.`——即：glob 写错不会报错，只会**静悄悄失效**。
这是最危险的一类错误，必须靠 §6 的核对。

### 5.3 实测时钟清单（首轮综合后打印，7 个）

| 时钟名 | 周期 | 归属 |
|---|---|---|
| `b_ref_clk_50m` | 20.000ns | 板载晶振 |
| `b_eth_rxc_125m` | 8.000ns | PHY RGMII 接收钟 |
| `u_top/u_hdmi_pll/pll_inst.clkc[0]` | 10.000ns | HDMI PLL C0（仅 IP 内部反馈） |
| `u_top/u_hdmi_pll/pll_inst.clkc[1]` | 13.643ns | **像素域 73.33M** |
| `u_top/u_hdmi_pll/pll_inst.clkc[2]` | 2.727ns | HDMI 串行 366.67M |
| `u_top/u_sdram/sdram_pll1/pll_inst.clkc[0]` | 10.000ns | SDRAM 100M |
| `u_top/u_sdram/sdram_pll1/pll_inst.clkc[1]` | 10.000ns | SDRAM 100M 相移 |

**与骨架假设的差异（这就是红线要查的东西）**：

- 骨架里写的 `*u_hdmi_pll*pll_inst*clkc[1]` 在修复 §3.3 之前**根本不存在**，
  两条 HDMI 相关异步组因此是全空组 → 静默失效；
- 修复 §3.3 后 `derive_pll_clocks` 能正确派生 `clkc[1]`（×1.4667），
  不再需要手写 `create_clock`（手写会与派生冲突：`USR-8195`）；
- `pll_hdmi1_4b` 的 C0 也派生了一个时钟（10ns），它只驱动 IP 内部反馈 BUFG。

派生时钟的**触发条件**：`clkc[1]` 只有在它真正有负载时才被派生——
多驱动/无驱动会让 TD 认为它没有负载而跳过，且**不报错**。

### 5.4 异步组（全部实测非空）

`b_cdc_sdram_pll` / `b_cdc_ref_sdram` / `b_cdc_sdram_hdmi` /
`b_cdc_ref_pix` / `b_cdc_pix_serial` / `b_cdc_serial_others` /
`b_cdc_eth_sdram` / `b_cdc_eth_others`，外加 RGMII 双沿 input delay
（2.0/0.5ns 占位，上板按 PHY 手册校准）与 `set_false_path -from [get_ports {rst_n}]`。

### 5.5 时钟端点分布（判定"域是否真被分析"）

| 域 | 端点 |
|---|---:|
| 50M 族（含 SDRAM/HDMI 派生） | 7408 |
| 125M 以太网 | 2594 |

像素域在修复 §3.3 前是 **0**，修复后并入 50M 族统计（7408 中含其 1244 个）。

## 6. 每次 RTL 改动后的核对动作（固化为流程）

```tcl
# 1) 打印时钟清单与周期
foreach c [get_clocks -quiet *] { puts "CLK <$c> period=[get_property -quiet period $c]" }
# 2) 打印端点分布（某域 0 端点 = 该域被优化掉了）
report_clock_summary -file clk.rpt
# 3) 扫描"静默失效"类告警
#    USR-8130 无匹配时钟 / USR-8225 组失效 / USR-8195 重复定义
#    SYN-5066 多驱动 / SYN-5013 无驱动 / SYN-5025 用 0 代替
```

基线（本轮）：7 个时钟、端点 7408 + 2594、上述告警**全部为零**。

## 7. 首份综合结果（非工程流，`out/p5td/p5_syn_final4.log`）

- elaborate / read_adc / read_sdc / optimize_rtl / optimize_gate 全通过；
- 层次表完整：`u_top` 下 eth / hdr / fetch / seq_wr / band / ixbuf / ixdec /
  scanout(+play,vsrc) / hdmi_core / hdmi_phy / sdram 全在；
- `IO 17`（8 入 8 出 1 双向），`bram 45/64`（38 bram9k + 7 fifo9k），
  `reg 3089/19600`，`pll 2/4`，`gclk 2/16`。

## 8. ★ 资源：装不下（这是本轮最重要的结论）

`place` 直接拒绝：

```
PHY-9009 ERROR: Design's mslice number = 14152, exceeds the limit 4900.
```

即需要约 **2.9 倍** 的 MSlice。`report_area` 同步给出
`#lut 56801 / 19600 = 289.8%`（A 板量产设计是 54.88%，同一口径）。

热点（LUT 当量）：

| 实例 | LUT | BRAM | 原因 |
|---|---:|---:|---|
| `u_band`（`ln` 行缓冲 8×1280×16） | 20474 | 30 | **组合双读** → 无法进 BRAM，落到分布式 RAM |
| `u_ixdec`（`map_ram` 128K×1） | 16276 | 0 | **一字节拆成 8 次单 bit 写 + 组合读** → 分布式 RAM |
| `REAL_IX$u_ethrx/u_bfifo`（8KB 字节 AFIFO） | 15710 | 0 | 推断式跨时钟 FIFO 未进 BRAM |
| 其余（含 HDMI 核 849、控制器 627、scanout 171…） | ~4300 | 15 | — |

三块存储器合计 ≈ 42460 LUT 当量（占 75%）。**它们本该是 BRAM**
（`book` 256Kbit 已经正确进了 30 块 BRAM，可作对照）。

改造方向（按收益排序，均需仿真门禁保持全绿）：

0. **已落地**：`yx_vp_ixdec` 的 `map_ram` 按真实索引范围声明
   （131072 → `NB`=57600 位；写 `mcnt*8+k` 最大 NB-1、读 `blk<NB`）。
   全设计 LUT 当量 **56801 → 48777**，`u_ixdec` **16276 → 8249**。功能零变化。

### 8.1 为什么改写法没用（10 组 TD 实验）

| 写法 | LUT | BRAM |
|---|---:|---:|
| 双时钟 8b×8192，条件读（现 eth AFIFO） | 8072 | 0 |
| 双时钟 8b×8192，无条件读 + 读地址打拍 | 8072 | 0 |
| 单 bit×128K，一字节拆 8 次单 bit 写 + 组合读（原 map_ram） | 16315 | 0 |
| 16b×16K，单写 + 组合双读（现行缓冲） | 61172 | 0 |
| 16b×16K，单写 + 同步双读 | 61172 | 0 |
| 16b×16K，读写分两个 always 块（book 的写法） | 31140 | 0 |
| 16b×16K，读写分块 + 读地址打拍 | 31140 | 0 |

结论：**TD 在这套流程里把 RTL 推断的存储器一律映射成分布式 RAM**；
真正决定它用不用 BRAM 的是"全局预算 + 是否可映射"两条：

- `SYN-2599 : Bram u_top/u_band/ln_syn_12 will be implemented by dram for
  resource limit` —— 预算不够时把最大的降级；
- 把 `book` 临时减半、空出 29 块 BRAM 后，`ln` **仍然**没进 BRAM
  → 决定性证据：**组合读（`assign scan_rd = ln[scan_ra]`）无法映射到 BRAM**。

### 8.2 剩下两项的正确解法（都需要显式例化存储器原语）

TD 提供的原语：`EG_LOGIC_BRAM`（真双口，`IMPLEMENT` 可选 "9K"/"32K"）、
`EG_PHY_BRAM/BRAM32K`、`EG_LOGIC_FIFO`（硬 FIFO）。
仿真侧已备好行为模型 `tb/bshims/EG_LOGIC_BRAM.v`（**尚未加入任何构建源单**，
下轮改造时随源单一起加）。

1. **`u_ethrx` 的 8KB 字节 FIFO**（现 15710 LUT，0 BRAM）
   - 存储换 `EG_LOGIC_BRAM`（A 口写 125M / B 口读 100M，8b×8192）；
   - ★ 关键难点：BRAM 读是"地址打入 → 下一沿出数"，比原数组多 1~2 拍。
     原 `yx_b_afifo` 的读侧预取（`dout_r <= mem[rptr_nxt]`，1 字节/拍）
     必须改成"请求-到达 3 级流水 + 输出暂存"，**峰值吞吐必须保持 1 字节/拍**
     （125M 写 / 100M 读本来就吃紧）。改错会直接体现在 `GATE-ETH drop` 上。
   - 验证：`eth_rx` 专用 TB（1 分钟）→ `bboard_sys_eth`（30 分钟）。
   - 备选（更省事但语义要重做）：换 `EG_LOGIC_FIFO` 硬 FIFO，但入包准入
     `fifo_room >= rx_len+16` 依赖占用数，必须改为用 FIFO 自身的
     conservative 占用或重设计准入，**会动 P4 验收语义**，风险更高。

2. **`u_band` 的 `ln` 行缓冲**（现 20474 LUT，含 book 的 30 块 BRAM）
   - `scan_ra`/`scan_rb = scan_ra+1`，且顶层 `sc_ra` 恒为偶数 → 2 像素
     **打包成 32bit 单字**（深度 5120×32，位数不变），一个读口即可；
   - 写侧：渲染器逐像素写 16bit → 用 `EG_LOGIC_BRAM` 的字节使能
     （`BYTE_ENABLE=16`）写半个字；
   - 读侧改同步 1 拍 → **顶层扫描推数流水必须补 1 级对齐**
     （`sc_ra` 地址提前一拍出，`sc_wdata` 晚一拍收）；
   - 预计 −20.5K LUT，+5 块 32K BRAM。

预计两项完成后 ≈ **12.6K LUT（64%）**，`place` 才能过，之后才有真实时序。


> 注意：`#lut` 与 `#Total_luts`（物理 LUT 数 14341）是两个口径；
> 判"能否装下"以 `PHY-9009` 的 MSlice / `#lut out of 19600` 为准。

## 9. 本轮回归状态（全部 ALL PASS，数字与 P4 基线逐项一致）

| 入口 | 结果 |
|---|---|
| `sdctrl_sanity`（改测派生控制器） | ALL PASS（控制器写读回环 errs=0） |
| `bboard_key` | ALL PASS：`ax_errs=0 ax_beats=3491854 ax_lines=2728 disp_stall=6950` |
| `bboard_sys` | ALL PASS：`ax_errs=0 ax_beats=4501760 ax_lines=3517 cpdeliv=166212` |
| `GATE-WR1`（新增等价性门禁） | `eq_errs=0`（两个入口都跑） |

`map_ram` 缩容后重新跑了 `bboard_key` / `bboard_sys`，**数字与缩容前完全相同**
（存储器内容不变，只是声明范围收紧）。

HDL-8007 的修法（WR1 排空判据）说明：

- 原实现用 `u_sdram.write_fifo1.logic_fifo.SAMEDOM.rp_bin` 影子差分，穿透厂商 IP 内部；
- 改为对 `IN_REQ & WR_MASK[0]`（恰是 `write_fifo1` 的 `.re`）计数，**且必须打一拍**
  （原差分的 `rp_q` 本身滞后一拍，即 pop 后下一拍才累加）。
  不打拍实测会让 FLUSH 提前一拍，改变 SDRAM 仲裁相位 → `bboard_sys` 出现
  `axerr=1603800` 整字错位（`out/sim/bboard_sys_20261123_223420_sim.log`）；
- 为防回归，TB 增加了逐拍等价性门禁 `GATE-WR1 eq_errs=0`：TB 侧复刻原影子差分
  模型，每拍与 DUT 计数比对（也覆盖"空 FIFO 不被读"的前提）。

## 10. 以太网 bring-up 缺口（上板时处理，非综合阻塞）

1. **RGMII 发送未实现**：RGMII 需要 MAC 侧 125MHz TX 时钟（`eth_gtxc`），本板
   现有 PLL 无 125M 输出 → 只收不发。需要发送时在 PLL 加 125M 支路 +
   `gmii_to_rgmii` + txd/txen 引脚。
2. **MDIO 未实现**：当前 MDC/MDIO 恒高。上板前按 PHY 型号补寄存器序列，
   并把 `timing_b.sdc` 的输入 delay 校准到实测值。
3. **PHY 型号待确认**（AC201 载板）：决定 MDIO 表与 RXC delay 方案。
4. **RXC 双缓冲路径**：`eth_rxc` 同时进 `rgmii_to_gmii` 的 IDDR 与
   `eth_udp_rx_gmii` 内的 `BUFG_0`——与 A 板厂商示例同构；若 STA 报偏斜吃紧，
   改为顶层单缓冲后分发。
5. `video_user` / `video_last` 相位：接加密核后按核实际采样点校准。

## 11. TD 源单（本轮实测通过）

```
media/vp/yingxu_vq_board_b.v            ← 顶层
media/vp/yingxu_vq_board_top.v
media/vp/yx_vp_ixdec.v / yx_vp_ixbuf.v / yx_vp_band.v
media/vp/yx_b_hdr_parse.v / yx_b_ix_seq_wr.v / yx_b_ix_fetch.v
media/vp/yx_b_scanout.v / yx_b_scanout_play.v
media/vp/yx_b_eth_rx.v（USE_ETH）
src/eth_udp_rx_gmii.v / ip_checksum.v / crc32_d8.v / rgmii_to_gmii.v（USE_ETH）
video_source_test.v / hdmi_phy_warpper.v / lane_lvds_10_1.v
hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v（EMIT_HDMI）
5640/sdram_ctrl_4p/b_board/Sdram_Control_4Port_b.v ← 派生副本
5640/sdram_ctrl_4p/b_board/Sdram_RD_FIFO_b.v
5640/sdram_ctrl_4p/{sdram_ip,command,control_interface,sdr_data_path,
                    Sdram_PLL,Sdram_WR_FIFO}.v
al_ip/{pll_hdmi1_4b,BUFG_0,IDDR_0}/*.v
```

仿真 shim（`tb/bshims/*`）**不得**进 TD 工程。`tb/bshims/Sdram_Control_4Port.v`
与 `tb/bshims/Sdram_RD_FIFO.v` 已退役（只留历史对照，不再进源单）。

## 12. 下一步（顺序建议）

1. **资源改造三件套**（§8）：行缓冲同步读 → `map_ram` 字节写 → 以太网 FIFO 换 IP；
   每步后跑 `bboard_key` / `bboard_sys` 双回归（门禁数字不允许下降）。
2. 资源进到 ~70% 后重跑 `place` → `report_timing_summary`，出**第一份真实时序**。
3. 用 `report_timing -from ... -to ... -input` 核对 RGMII 双沿 input delay 生效。
4. 工程流宏问题（`.al` 的 define 字段）解决后，把非工程流脚本固化进仓库。
