# 映序 YingXu — 一块国产 FPGA 上的多媒体游戏机

> 全国产 EDA 流程（安路 TD + EG4S20）· 一条 HDMI 输出照片 / 音乐 / 游戏 /
> 自研 8 位 CPU 运行的卡带游戏 · 从 SD 卡"卡带"加载

**English**: YingXu is a multi-function FPGA console built on an Anlogic EG4S20
(Anlogic TD toolchain, fully domestic EDA). One HDMI output carries a photo
browser, an SD-card music player, two cartridge games, and a hardware invaders
game — all on top of a custom 8-bit CPU ("YX-8") with its own assembler and
simulator. Cartridges are loaded from fixed SD-card sectors.

---

## 功能一览

| 类别 | 功能 |
|---|---|
| 多媒体平台 | SD 卡 BMP 照片浏览（K0/K1 翻页、5s 自动轮播、淡入淡出）；SD 卡音乐播放（YXMA 48kHz 立体声，与音效饱和混音） |
| 游戏机 | 卡带《宇宙流浪者》(606 词汇编)、《打砖块》(492 词)；硬件版流浪者（纯 FSM，判定经 1200 帧仿真验证 0 误判）；四种 PSG 事件音效 |
| 计算机 | 自研 YX-8 CPU（73MHz，16 位字/24 位指令）+ 汇编器 yxa + 周期精确模拟器 yxem（与 RTL 余弦仿真金标比对） |
| 平台 | SD SPI 驱动（上电冲洗/重试看门狗）、SDRAM 四端口控制器、HDMI 1.4b 视频音频、UART 遥测 |

## 架构

```
             ┌─────────────────── AC201 + AC601 (EG4S20) ───────────────────┐
 SD 卡 ─────►│ SPI 驱动 → 集成探针(字节流) ─┬→ BMP 加载 → SDRAM 帧缓冲 ─┐    │
             │                             ├→ YXMA 音乐播放器 → 混音器  │    │
             │                             └→ 卡带加载 → YX-8 指令 RAM   │    │
             │                                                            ▼    │
             │ 精灵引擎/图块层（48×48 位图精灵）─────────────────► 视频管线 ──► HDMI
             │ PSG 音效（48kHz 方波四音色）──────────────────────► 饱和混音 ──► HDMI 音频
             │ UART 遥测（CPU/SD/播放器内部量，115200）                    │
             └────────────────────────────────────────────────────────────┘
```

自研部分见 `src/user_source/hdl_source/`（`yingxu_*` / `yx8_*` 前缀）与顶层
`hardware_test_P0_UART_V5_CRC32.v`；厂商示例代码清单见
[docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md)。

## 仓库结构

```
├── AC201_AL_board_test.al   TD 工程（相对路径，克隆即开）
├── hardware_test_*.v        顶层
├── src/                     RTL（user_source=自研，5640=SDRAM 控制器）
├── al_ip/                   PLL 等 TD IP
├── timing.sdc / IO.adc      时序与管脚约束
├── tb/                      测试台 + 仿真音频资产
├── sim/…                    仿真命令见下
├── tools/                   汇编器 / 模拟器 / 写卡 / 遥测 / 画板
├── cartridges/              YX-8 汇编卡带（.asm 源码 + .yxc 镜像）
├── docs/                    设计文档与调试实录（强烈推荐从 HANDOFF_20261027 读起）
├── release/                 冻结固件 bit（SHA256 见 SHA256SUMS.txt）
```

## 0.17.0 · B 板 VQ 视频协处理器（双板「算画分开」）

> 本节为 0.17.0 新增内容。上文的 SD/HDMI/YX-8 是 **A 板产品侧**；本节是
> **B 板协处理侧**——把视频解码与显示从 CPU 板剥离出去，做成一块独立的
> 视频协处理器。两块板通过以太网 UDP 传递码流（A→B），B 板独立完成
> 解码、渲染、扫出。

### 分工

```
┌──────────── A 板（算）────────────┐        ┌──────────── B 板（画）────────────┐
│ YX-8 CPU / 游戏逻辑 / 精灵引擎     │        │ VQ 解码 → 索引重建 → 条带渲染      │
│ SD 卡 → 码流封装 → 以太网 UDP TX  │ ─UDP→  │ → SDRAM 帧缓冲 → HDMI 1.4b 扫出   │
└──────────────────────────────────┘        └───────────────────────────────────┘
```

### B 板内部数据流

```
码流字节流
  → yx_b_hdr_parse    解析 YXV2 文件头 + 装载码本（1024×32B）
  → yx_vp_ixdec       逐帧解码：KEY 帧整窗索引 / DELTA 帧位图 + 稀疏补丁
  → yx_vp_ixbuf       双索引缓冲；DELTA 走「合并流」重建（补丁与拷贝按块号
                      合并成稠密顺序流，规避 vendor 控制器不支持随机写）
  → yx_vp_band        4×4 块渲染，双扫描读口 → 行缓冲
  → 扫描写端          每带一次 256 字突发流式写入帧缓冲（band-major 布局）
  → SDRAM 四端口      WR1=扫描入帧  WR2=索引顺序写  RD1=HDMI 扫出  RD2=取带
  → yx_b_scanout      720p59.3 时序 + 双帧窗防撕裂 + AXI-Stream 输出
```

### 关键设计

**YXV2 码流格式**：20B 文件头（magic/几何/帧数/码本数）+ `cb×32B` 码本 +
每帧 5B 帧头（kind + 3B 变化块数）。KEY 帧 = 57600×2B 全窗索引；
DELTA 帧 = 7200B 位图 + 按变化数 ×2B 补丁。

**DELTA 重建（合并流）**：DELTA 帧本应「整窗拷贝 + 稀疏打补丁」，但 vendor
4 端口控制器只支持顺序突发，稀疏补丁会写错地址。改为单遍扫描：补丁流与
拷贝流按块号对齐合并，输出恒为稠密顺序流，下游写协议零改动。补丁滞后时
拷贝前沿等待，`pf(8) + skid(16) + 码流回压` 即天然缓冲。

**索引拷贝读口 = RD2 分时复用**：索引重建需要读上一帧的索引窗。它其实是一条
**严格顺序流**（补丁只让读地址前跳），因此不需要随机口——复用在渲染取带的
RD2 通道上，在「帧尾空闲」窗口内分时服务，KEY 流完全不触发。板上因此没有
任何随机访问 SDRAM 的需求。

**双帧窗防撕裂**：帧 k 渲染到窗 `k%2`，显示读「最后完成窗」，写读恒异窗。
显示每帧恰好消耗一整窗（720×640 = 460800 字），因此 vblank 的一次 LOAD
既重置读指针又切窗，不依赖 `rRD*_MAX` 的复位锁存行为。

### 验证（iverilog 全链路仿真）

| 入口 | 内容 | 结果 |
|---|---|---|
| `bboard_key` | KEY-only 合成流 720p × 5 帧 | **ALL PASS**：AXI-Stream 逐像素对拍 **4,413,454 拍 / 2728 行零错** |
| `bboard_sys` | 真实码流（含 DELTA）720p × 5 帧 | **ALL PASS**：**5,423,360 拍 / 3517 行零错**；索引窗金标 5×57600 逐字对（`igold=0`）、帧缓冲 900 带逐带对（`golden=0`）、cp 交付精确 `166212` 字 |
| `sdctrl_sanity` | vendor SDRAM 控制器读写回环 | ALL PASS（256/256/128 轮，errs=0） |
| `bboard_key` 1080p | 1920×1080 × 5 帧（24/30/free-run） | ALL PASS（1350 带） |

判据不是"跑完不崩"，而是逐像素/逐字对齐金标，并额外检查：`xz=0`（无 X/Z）、
写读地址互斥（比较控制器当前读地址与写带区间）、显示遍覆盖 720 行。

### 排障中沉淀的三条硬件经验（都写进了代码注释）

1. **顺序突发口的 LOAD 地址必须 64 字对齐**。full-page 突发在行边界（256 字）
   内回绕，而控制器按线性地址 +步长 步进；起始列 >192 的突发会把本行头部
   当成下一行尾，错误周期性出现且被均匀区域掩盖（实测 1585 字错位）。
2. **vendor 4 端口控制器的 `rWR*_MAX_ADDR/rRD*_MAX_ADDR` 只在复位锁存**，
   LOAD 不锁 MAX。依赖 MAX 回卷的"整窗循环读"会在第二个窗口死循环。
   解法：MAX 恒为全域，回卷交给每个带/每帧的显式 LOAD。
3. **写 FIFO 的 AE 阈值 = 突发长度**。若盲推 1 字/拍，窗尾必然滞留不足一次
   突发的字数（永不触发末突发）或突发中途欠载。解法：按 128 字成组推进，
   推满即停推，等本组突发落盘再推下一组。

### 目录

```
src/user_source/hdl_source/media/vp/
  yingxu_vq_board_top.v   B 板 SoC 顶层（SIM_ABSTRACT 参数切换抽象/体系模式）
  yx_vp_vq.v              VQ 顶层编排
  yx_vp_ixdec.v           YXV2 帧解码（KEY/DELTA）
  yx_vp_ixbuf.v           双索引缓冲 + DELTA 合并流重建
  yx_vp_band.v            4×4 块条带渲染
  yx_vp_vbuf.v            行缓冲
  yx_b_hdr_parse.v        文件头解析 + 码本装载 + 首帧 KEY 校验
  yx_b_ix_seq_wr.v        索引顺序写（128 字组协议 + 按窗完成屏障）
  yx_b_ix_fetch.v         取带读出 + 索引拷贝读口 RD2 分时复用
  yx_b_scanout.v          720p 时序 + 双帧窗 + AXI-Stream
  yx_b_scanout_play.v     SDRAM→像素取数核
tb/tb_scanout.v           显示通路独立 TB（秒级迭代：行为读源 + 可反解内存）
tb/tb_yxvp_bboard.v       B 板 SoC 集成验收 TB
tb/bshims/                vendor 原语的 iverilog 行为模型（含真双时钟 CDC FIFO）
tools/sim/run_sim.ps1     带门禁的仿真入口（编译失败绝不运行）
docs/YX_BBOARD_*.md       设计文档与验收报告（含完整根因链与证据）
```

### 复现

```powershell
# 依赖：iverilog（-g2005）
powershell -NoProfile -ExecutionPolicy Bypass -File tools/sim/run_sim.ps1 -Entry bboard_key
powershell -NoProfile -ExecutionPolicy Bypass -File tools/sim/run_sim.ps1 -Entry bboard_sys
# 输出：out/sim/bboard_*_<时间戳>_{compile,sim}.log，末行 VERDICT + TB-SUMMARY
```

> **说明**：B 板显示链的厂商加密 HDMI 核（`.enc`）不参与仿真构建——
> 仿真边界定在 AXI-Stream；TD 综合时由 `EMIT_HDMI` 宏切换为接入加密核。

---

## 快速开始

### 0. 硬件
安路 AC201 评估板 + AC601 核心板（EG4S20BG256）、HDMI 显示器、TF 卡（FAT32）、
USB 转串口（遥测）。

### 1. 固件
- 直接烧写发布位：`release/RELEASE_g32_FROZEN_20261031.bit`（TD → 下载 → program_spi）
- 或自行构建：TD 6.2.210.850 打开 `AC201_AL_board_test.al` → 全编译（约 2 分钟）

### 2. SD 卡内容（PC 端，Python 3.10+，无第三方依赖）
```powershell
# 写卡带：槽 A = 流浪者（板子 LBA 1,000,000），槽 B = 打砖块（1,001,000）
python tools/write_cart.py --drive E --cart cartridges/invaders.yxc --lba 1000000
python tools/write_cart.py --drive E --cart cartridges/breakout.yxc --lba 1001000

# 写音乐：任意 MP3 → 48kHz 16bit PCM + YXMA 头 → 音乐槽 0（板子 LBA 2,000,000）
python tools/music2sd.py --in 你的歌.mp3 --slot 0 --drive E
# 注意：务必用默认 48kHz。44.1k 文件在板上会走零阶保持重采样（约 -24dB 失真）
```

### 3. 演示操作单（SW 拨码，实测为准）
| 模式 | SW7 | SW5 | SW6 | SW4 |
|---|---|---|---|---|
| 照片浏览 | OFF | - | - | - |
| **音乐播放** | ON | OFF | OFF | **ON** |
| 卡带·流浪者 | ON | ON | ON | - |
| 卡带·打砖块 | ON | ON | OFF | - |
| 硬件·流浪者 | ON | OFF | ON | - |

换卡 / 换模式后**断电重上电**（热切换不可靠）。

### 4. 仿真（iverilog）
```powershell
# 音乐播放器回归：双采样率 + 弹出节拍比 + 块推进断言
iverilog -g2012 -o tb_wav.vvp tb/tb_wav_mon.v src/user_source/hdl_source/yingxu_wav_player.v ^
         src/user_source/hdl_source/media/sd/ram_dual_port_simple.v
vvp tb_wav.vvp +file=tb/assets/tb_tune.yxm     # 48kHz
vvp tb_wav.vvp +file=tb/assets/tb_tune44.yxm   # 44.1kHz

# CPU 金标余弦仿真（汇编 → 模拟器金标 vs RTL 轨迹逐指令比对）
python tools/yxa.py cartridges/torture1.asm cartridges/torture1.yxc
python tools/yxem.py cartridges/torture1.yxc --cosim --goldtrace out/gold_t1.txt --maxinsn 30000
python tools/yxc2hex.py cartridges/torture1.yxc out/t1
# 用 iverilog 跑 tb/tb_yx8_cosim.v 后：
python tools/cosim_diff.py out/gold_t1.txt out/rtl_t1.txt   # 期望 BADC0UNT=0
```

### 5. 板上诊断（不插仿真器）
- LED0-3 在音乐模式下 = 使能 / FIFO 有数据 / 已进入播放态 / 断流看门狗
- COM5 115200 遥测；音乐模式下 D 帧为播放器内部量（弹出计数、FIFO 占用、看门狗…）
  ```powershell
  powershell -File tools/music_telem.ps1 -Seconds 6
  python tools/music_telem.py
  ```

## 文档（调试实录——本仓库最值钱的部分）

从 [docs/HANDOFF_20261027.md](docs/HANDOFF_20261027.md) 开始，按日期读：
CPU 移域、四个硬件 bug 的仿真定位、精灵判定 1200 帧测试台、音频链路
五层根因（位序旋转 / 清零毛刺 / 16 位累加器溢出 / 块推进越界 / 44.1k 重采样），
每个 bug 都是"症状 → 仪表 → 根因 → 修复 → 回归判据"的完整闭环。

## 来源与致谢

自研：YX-8 CPU 及全部 `yingxu_*` 模块、卡带游戏、工具链、YXMA 音频格式。
SD 命令层、SDRAM 控制器、HDMI 收发器等随板示例代码的清单与致谢见
[docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md)。

> **关于 B 板综合**：B 板显示链在 TD 综合时会实例化安路官方 HDMI 1.4b 加密 IP。
> 仿真构建（默认）不依赖该 IP，可直接复现全部验收结果；综合 B 板 bit 需自行
> 从安路 IP 库获取该核。

## License

代码以 MIT 发布（见 [LICENSE](LICENSE)）；随板示例代码版权归原作者。
仓库不含任何音频/图片素材，请用 `tools/music2sd.py` 自行转换。
