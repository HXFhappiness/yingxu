# YX_BBOARD_P4_ETH_20261123 — 板 B 以太网 UDP 入口（P4）

> 会话：2026-11-23（P4 实现与验收）
> 前置：`docs/HANDOFF_20261123.md`（状态/复现/硬约束）、
>       `docs/YX_BBOARD_P3_DISPLAY_20261121.md`（P3 显示链）
> 结论：见 §7（验收表）。本文件同时是 P4 的设计依据与已踩坑记录。

## 1. 目标与范围

把板 B 的码流入口从"TB 文件直推"升级为**真实以太网 UDP 入口**：
上位机/ A 板 → UDP 分包 → PHY → `yx_b_eth_rx` → 与既有 `stream_valid/data/ready`
完全同构的字节流 → （P3 链路）解码/渲染/扫描/HDMI。

范围内：`media/vp/yx_b_eth_rx.v`（新）、vendor 原语 shim（BUFG_0/IDDR_0）、
独立 GMII TB、全链路 TB 的 `-DBBOARD_ETH` 模式、run_sim 入口。
范围外：以太网发送（B 板不需要）、UDP 重传/ARQ、IP 分片重组、802.3x PAUSE、
P5 的引脚/综合（待 AC601 引脚表）。

## 2. 复用件（零改动）

| 文件 | 作用 |
|---|---|
| `src/eth_udp_rx_gmii.v`（厂商） | 前导/SFD 检测、Eth/IP/UDP 头解析与校验、IP 校验和、CRC32 整帧校验 |
| `src/ip_checksum.v`、`src/crc32_d8.v` | 厂商头校验和 / CRC 件（TB 的 FCS 生成复用同一件，保证口径一致） |
| `src/rgmii_to_gmii.v` | RGMII→GMII（`USE_RGMII=1` 时启用；TD 原语 IDDR） |
| `al_ip/BUFG_0`、`al_ip/IDDR_0` | 厂商原语（仿真用 `tb/bshims/` 同名行为模型） |

## 3. yx_b_eth_rx 架构

```
GMII 125M ── eth_udp_rx_gmii ── payload_valid/dat（1B/拍，**无 ready**）
                                  │
                    写侧(125M)：包边界跟踪 + 字节入 FIFO + 包级提交
                                  │  字节异步 FIFO 8KB（格雷码 + 2FF 同步）
                                  │  描述符 FIFO 8 深（{err,len}）
                                  ▼
                    读侧(100M)：按描述符转发 / 整段丢弃
                                  ▼
                    stream_valid/data/ready → hdr_parse
```

### 3.1 为什么必须加这一层

1. **时钟域**：PHY 125M，B 板视频逻辑 100M（Sdram_PLL clk0）；
2. **无背压**：厂商 `payload_valid_o` 没有 ready，不能直接挂到带反压的
   `hdr_parse`（`in_ready` 会在 skid 满时拉低）；
3. **坏包不能进解码链**：厂商 CRC 在整帧收完的 `PKT_CHECK` 拍才判
   `pkt_error`，而 payload 早已流出。本层**包级提交**：坏包描述符 `err=1`，
   100M 侧整段弹掉不转发；
4. **无流控**：若上层长时间停顿（渲染/扫描背压）导致 FIFO 满，本层跳过该包
   剩余字节并把该包标 `err`（同时拉高厂商 `data_overflow_i`），计入
   `pkt_drop_cnt`。UDP 无重传——**丢一包即整段码流失效**，须发送端重发
   （`hdr_parse` 的 magic/参数校验会拦截错位流，不会静默出错图）。

### 3.2 接口

```verilog
yx_b_eth_rx #(.USE_RGMII(0), .FIFO_AW(13), .DESC_AW(3))
  .clk100, .rst_n                     // 100M 域；rst_n 低有效（内部转厂商 reset_p 高有效）
  .local_mac, .local_ip, .local_port  // 静态配置
  .gmii_rx_clk, .gmii_rxd[7:0], .gmii_rxdv      // 125M
  .rgmii_rx_clk, .rgmii_rxd[3:0], .rgmii_rxdv   // USE_RGMII=1
  .stream_valid, .stream_data[7:0], .stream_ready   // 100M → hdr_parse
  .pkt_ok_cnt, .pkt_drop_cnt, .byte_cnt, .fifo_room, .rx_clk125
```

### 3.3 关键实现点

- **字节 FIFO**：写侧 125M、读侧 100M，格雷码指针 + 双拍同步；占用用模减
  （写域偏大→full 提前；读域偏小→empty 提前，均安全方向）；读侧带预取
  （稳态 1B/拍无气泡）。
- **描述符**：`{err, len[14:0]}`，`len` = 实际写入 FIFO 的字节数（跳过字节时
  小于 UDP 载荷长度，读侧只弹 `len`，FIFO 一致性不破）。
- **包首准入（健壮性）**：只有"字节 FIFO 能整包容纳（`room ≥ rx_len+16`）且
  描述符 FIFO 有空位"时才接收该包；否则一个字节都不写、不产生描述符、计入
  `pkt_drop_cnt`。仅做逐字节满判断不够——小包（如 18B 载荷）每个只占很少
  字节空间，可能在 8KB 里积压数百包而把 8 深的描述符 FIFO 写爆。
- **复位**：异步置位 / 各域同步释放（2FF）。
- **计数器跨域**：包 ok/drop 用 toggle + 2FF 同步到 100M（包间隔远大于同步
  延迟，无丢失风险）。

## 4. 已踩的坑（改代码前必读）

| # | 坑 | 现象/证据 | 处理 |
|---|---|---|---|
| 1 | TB 里 `sig=1; @(posedge clk); sig=0;` 与 DUT always 块**delta 竞争** | CRC 件寄存器始终 X（`debug_crc_check=xxxxxxxx`），全部包判错 | 脉冲撤除必须跨过时钟沿：`@(posedge); #1; sig=0;`（或改用 negedge 驱动）|
| 2 | TB 的 FEED 探针用 `sent<12` 作门 | ETH 模式下 `sent` 恒 0 → **每拍打印一行**，日志 2.4MB/s | 探针改用独立 `feed_cnt`，且必须检查 `s_valid` |
| 3 | 厂商 RX 核 `payload_valid` 无背压 | 直接接 `hdr_parse` 会静默丢字节 | 本层 FIFO + 描述符（§3.1）|
| 4 | 厂商 CRC 在整帧末才判，坏包字节已流出 | 坏包会污染码流 | 包级提交：err=1 的描述符整段丢弃 |
| 5 | 两板复位极性相反 | 厂商核 `reset_p` 高有效（异步），B 板 `rst_n` 低有效 | `yx_b_eth_rx` 内部 `rst_p=~rst_n`；勿把 rst_n 直接接 reset_p |
| 6 | LOAD 不得落控制器 POR 窗 | `control_interface.v`：`init_timer < INIT_PER+200` 期间 `LOAD_MODE` 被强制 0，LOAD 被丢弃 | ETH 发送进程以 `init_done`（顶层 `#250000` 之后）为门；与文件直推同语义 |
| 7 | UDP 载荷 < 18 字节会踩厂商 `RX_DATA→RX_DRP_DATA` 分支（空转 64K 拍） | 厂商既有缺陷 | 本协议只用大包（PLEN=1024）；TB 不发小包。接入真实发送端时须保证 ≥18B |
| 8 | 消费者 ready 长期为低时 FIFO 必满 | 无 PAUSE/无流控 | 发送端必须按 `fifo_room` 节流（TB 已实现），否则整段重发 |

## 5. 仿真入口

```powershell
# 独立以太网入口（秒级，~5ms sim 时间）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\sim\run_sim.ps1 -Entry eth_rx
# 全链路：UDP → 解码 → 渲染 → 扫描 → HDMI AXIS
powershell -NoProfile -ExecutionPolicy Bypass -File tools\sim\run_sim.ps1 -Entry bboard_sys_eth
```

- `eth_rx`（`tb/tb_eth_rx.v`）：YXV2 文件 → 1024B/包 → GMII 帧；用例：
  第 20 包坏 FCS（整包丢弃）、第 30 包错 dst_port（厂商核丢帧）、第 10 包
  广播 MAC（必须接收）、消费者 1/5 拍反压。判据：逐字节等于源文件、`drop=1`、
  `ok=N−2`、转发字节数=源长度−两个洞。
- `bboard_sys_eth`：bboard_sys 的**全部判据原样保留**（golden/igold/axerr/
  mutex/vblank…），追加传输层判据 `GATE-ETH ok=包数 drop=0 bytes=slen`。

## 6. 与 P5 的接口（待办）

- 顶层接入：当前 `yx_b_eth_rx` 由 TB 例化后驱动顶层 `stream_*`（顶层零改动，
  保证 P3 基线逐位不变）。P5 建 TD 工程时建议在顶层加 `USE_ETH` 参数 +
  GMII/RGMII 引脚（AC601 引脚表到位后），内部 `stream_*` 由本模块驱动；
- PHY：GMII 直连（AC601 板载 PHY 类型待确认）；RGMII 分支已留
  `USE_RGMII` + `rgmii_to_gmii`；
- 时钟：`gmii_rx_clk` 由 PHY 提供（125M），B 板内部 100M 不变；
- 流控：若真实发送端无法节流，P5 需补 802.3x PAUSE（需要 TX 口）或发送端
  整段重传策略。

## 7. 验收

| 入口 | 判定 | 关键证据 |
|---|---|---|
| `eth_rx` | **ALL PASS**（`out/sim/eth_rx_20261123_201952`） | 292 包/295,941 字节逐字节对拍 `cmp_errs=0`；坏 CRC 包丢弃 `drop=1`；错端口包被厂商核丢帧（无描述符）；广播 MAC 接收；消费者 1/5 拍反压零错 |
| `bboard_sys_eth` | **ALL PASS**（`out/sim/bboard_sys_eth_20261123_202054`） | GATE 全项 OK；`GATE-ETH ok=292 drop=0 bytes=297989`；`golden=0 igold=0 cperr=0 cpdeliv=166212`；`ax_errs=0 / ax_lines=2797` |
| `bboard_sys`（回归） | **ALL PASS**（`out/sim/bboard_sys_20261123_195321`） | 与 P3 基线同判据：`ax_errs=0 / ax_lines=3517`、`golden=0 igold=0 cperr=0 cpdeliv=166212` |
| `bboard_key`（回归） | **ALL PASS**（`out/sim/bboard_key_20261123_190131`） | `ax_errs=0 / ax_lines=2728`、GATE 全项 OK |
| `tb_scanout`（独立） | **ALL PASS** | `best_sh=0 errs=0 nlines_bad=0 ng=921600` |

### 7.1 验收中发现并修复的 P3 遗留缺陷（首帧启动）

`bboard_sys_eth` 首跑 `ax_errs=1024`（其余全绿）。定位：**首窗完成（loaded）落在
显示帧中间**时，RD1 尚未做过生效 LOAD（复位期 boot LOAD 落在控制器 POR 窗被
丢弃，见 §4 坑 6），取数核从陈旧 ADDR 预取——1024 = 首个 RD1 FIFO 深度 512 字
×2 像素的垃圾。

修复（`yx_b_scanout.v`）：新增 `armed`——首窗完成后的**第一个帧边界**
（vblank 拍）才置位；`armed` 之前屏蔽 AXIS 三元组（`video_user/valid/last`），
HDMI 表现为首帧黑屏（与 P3 文档"首窗完成前显示黑"的原始设计意图一致）。
armed 之后每帧仍由 vblank LOAD 重新对齐，**判据零放宽**。

副作用（可解释、需记录）：被屏蔽的"首窗完成前半帧/整帧"不再计入
`ax_beats`（key/sys 各减少恰好 921,600 拍 = 一整显示帧的像素数）；
**对拍覆盖不变**（`ax_lines` 与 `ax_errs` 与 P3 基线一致：key 2728、sys 3517，
均 `ax_errs=0`）。此前该帧本就不被对拍（`ax_frm=-1`），只是它的像素进入了
`ax_beats` 统计。
