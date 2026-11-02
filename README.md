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
| 游戏机 | 卡带《宇宙流浪者》(604 词汇编)、《打砖块》(492 词)；硬件版流浪者（纯 FSM，判定经 1200 帧仿真验证 0 误判）；四种 PSG 事件音效 |
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

### 3. 菜单与维护拨码

统一分支 `feat/unified-menu-photo-video` 默认上电显示硬件菜单：key1 选择、key0 确认。
游戏子菜单两项均运行 YX-8 CPU 卡带：打砖块读取 LBA 1,001,000，飞机大战读取
LBA 1,000,000（仓库镜像标题 INVADERS）。游戏中 SW7 OFF 时 key0 左、key1 右；
回菜单使用 SW7 ON + key0 短按，2 秒长按保留兜底；游戏退出回子菜单原选项，
子菜单退出回主菜单“游戏”。导航锁定 100ms，主菜单中 SW7 ON 仍可 key0 确认。
菜单接管后实体 DIP 不再抢占模式。视频板测跟进、I1 编码及本地构建入口见
[最新交付说明](docs/D10_CLOCK_MENU_RETURN.md)。

以下为冻结固件及 `BOOT_MENU=0` 维护构建的实体 DIP 直通表；统一菜单固件默认不使用它。

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

## License

代码以 MIT 发布（见 [LICENSE](LICENSE)）；随板示例代码版权归原作者。
仓库不含任何音频/图片素材，请用 `tools/music2sd.py` 自行转换。
