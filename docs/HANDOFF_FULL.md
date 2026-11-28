# 映序 YingXu — 完整交接文档（Codex 用）

> 版本：2026-10-31（初赛固件冻结后）
> 目标读者：接手的工程师 / AI 编码代理
> 阅读建议：§0 速览 → §3 架构 → §5 冻结基线 → §6 问题档案（**最有价值**）→ §9 铁律 → §10 在建 → §11 路线图

---

## 0. 30 秒速览

**映序**是一台跑在国产 FPGA（安路 EG4S20）上的多媒体游戏机：一条 HDMI 输出照片浏览、SD 卡音乐播放、两款卡带游戏、硬件版射击游戏，底层是自研 8 位 CPU（YX-8）及其汇编器/模拟器。全部用国产 EDA（安路 TD）综合布线烧写。

- **仓库**：`HXFhappiness/yingxu-fpga`（私有），本目录即仓库根
- **冻结固件**：`release/RELEASE_g32_FROZEN_20261031.bit`（SHA256 见 `release/SHA256SUMS.txt`）
- **当前阶段**：初赛已冻结，**不再改 RTL**；新功能（视频、耳机口、菜单）排在复赛
- **在建**：YXV 视频管道（格式已定、PC 端转换器已跑通、RTL 解码器未开始）
- **纪律**：改文件只用 Python 脚本；改 RTL 先仿真；一次只改一处（见 §9）

---

## 1. 项目定位与创新点

### 1.1 三个关键词（答辩口径）

1. **全栈自研** — 自定义 ISA + 汇编器 + 周期精确模拟器 + 金标协同仿真 + 汇编内容，全链路自主
2. **卡带即内容** — SD 卡固定扇区抽象为"卡带槽"，照片/音乐/游戏/（未来）视频全是运行时加载的内容，FPGA 一次综合成为"主机"
3. **全国产闭环** — 国产 EG4S20 + 国产 TD 工具链 + 零第三方 CPU/IP 核依赖

### 1.2 三个形态（产品叙事）

| 形态 | 开关 | 内容 |
|---|---|---|
| 多媒体平台 | SW7 OFF | BMP 照片浏览（轮播/翻页/淡入淡出） |
| 游戏机 | SW7 ON + SW5/SW6 | 卡带游戏、硬件游戏、PSG 音效、PCM 音乐 |
| 计算机 | （同游戏机） | YX-8 CPU 执行 SD 卡加载的汇编程序 |

### 1.3 不要作为创新点讲的东西

单独的"8 位 CPU""SD 读取""BMP 显示""WAV 播放""PSG 音效"都是成熟技术，逐个都会被评委戳破。创新在**整机闭环 + 全栈工具链 + 卡带形态**，以及 §6 那套**可观测性驱动的问题定位方法**。

---

## 2. 硬件与环境

### 2.1 硬件

| 项 | 参数 |
|---|---|
| FPGA | 安路 EG4S20BG256（AC601 核心板 + AC201 底板） |
| 逻辑资源 | LUT 19,600 / REG 19,600 / BRAM 64（9K）/ DSP 29 |
| 板载时钟 | 50 MHz 晶振（引脚 K14） |
| 显示 | HDMI 1.4b，1280×720@59.3 Hz，pix_clk 73.30 MHz（13.643 ns） |
| SDRAM | **8 MB**（64 Mbit，2048 行 × 4 bank × 256 列 × 16 bit，地址 [20:0] 按 32 bit 字） |
| 板载 SRAM | IS61WV25616EDBLL-10TLI，256K×16 = **512 KB**，10 ns 异步（**当前未使用**） |
| SD 卡 | SPI 模式，当前 SCLK 6.25 MHz（781 KB/s） |
| 音频 | **WM8960** 编解码器（I2S + I2C），耳机/喇叭 —— **当前未接线**（`I2S_DO=0`） |
| I2C 总线共用 | WM8960、24LC256 EEPROM、PCF8563 RTC |
| 其他未用外设 | 千兆网 RTL8211（RGMII）、OV5640 摄像头、数码管（HC595）、蜂鸣器、红外接收 |
| 调试口 | **COM5** 115200 8N1（遥测），JTAG 烧写 |

> ⚠️ **SDRAM 是 8 MB 不是 32 MB**。这个数字决定了视频方案的上限（见 §10.3）。

### 2.2 软件环境

| 项 | 路径 / 版本 |
|---|---|
| TD（综合布线） | `D:\Anlogic\TD_Release_2026.2.210.850` |
| 工程文件 | `AC201_AL_board_test.al`（相对路径，克隆即开） |
| 仿真 | `D:\iverilog\bin`（iverilog `-g2012`） |
| Python | `C:\Users\HXF\yingxu_tools\python312\python.exe`（**无 pip**，只用标准库） |
| ffmpeg | `tools\ffmpeg\ffmpeg-9.0.2-essentials_build\bin\`（**不入库**，需自行下载） |
| Git | `C:\Users\HXF\mingit\cmd\git.exe`（MinGit 便携版，无凭据管理器） |

### 2.3 唯一工作目录（**重要：一份源码，别搞成两份**）

| 路径 | 角色 | 是否用于构建 |
|---|---|---|
| **`C:\Users\HXF\Desktop\yingxu-fpga`** | **Git 仓库 = 唯一源码真身 = 构建/烧录目录** | ✅ **是** |
| `C:\Users\HXF\Desktop\YX` | 历史调试目录（`out/` 构建日志、旧 `Runs/`、数百个一次性补丁脚本、厂商资料 `YX-tool/`） | ❌ 不再使用 |

**已验证（2026-10-31 14:32）**：在 `yingxu-fpga` 目录内用 TD 完整跑通
`syn_1 + phy_1 + save_best_bits`，产出
`yingxu-fpga\AC201_AL_board_test_Runs\best_result\AC201_AL_board_test.bit`
（630,802 B，与冻结版同尺寸）。51 个工程引用文件全部齐备。

> ⚠️ **坑**：`.al` 工程文件第 3 行 `<Project Path="...">` 是**绝对路径**。
> 曾经它指向 `YX`——那时在仓库目录里打开工程，TD 仍会编译 `YX` 里的旧源码，
> 表现为"改了代码但烧进去没变化"。现该字段已指向 `yingxu-fpga`。
> **若发现"改了没生效"，第一件事就是查这一行。**

### 2.4 构建与烧写（在 `yingxu-fpga` 内执行）

```powershell
# 构建（全流程，约 2 分钟；注意：TD 布线引擎有约 50% 概率崩溃，见 §6 E1）
echo import_device eagle_s20.db -package EG4S20BG256 > build_cmds.txt
echo open_project C:/Users/HXF/Desktop/yingxu-fpga/AC201_AL_board_test.al >> build_cmds.txt
echo set_seed_param -disable >> build_cmds.txt
echo reset_runs syn_1 >> build_cmds.txt
echo launch_runs syn_1 phy_1 -jobs 2 >> build_cmds.txt
echo wait_run syn_1 -quiet >> build_cmds.txt
echo wait_run phy_1 -quiet >> build_cmds.txt
echo save_best_bits >> build_cmds.txt
echo exit >> build_cmds.txt
D:\Anlogic\TD_Release_2026.2.210.850\bin\td_commands_prompt.exe < build_cmds.txt > out\build.log 2>&1

# 若 phy 崩溃（进程消失、wait_run 永挂）：杀进程后只重跑 phy
#   把上面脚本改成 reset_runs phy_1 + launch_runs phy_1 即可
# **烧写前必须核对 bit 时间戳是今天**（崩溃时会残留旧 bit，烧错固件！）

# 烧写（约 26 秒）
echo connect_cable -allink > flash.txt
echo download -bit C:/Users/HXF/Desktop/yingxu-fpga/AC201_AL_board_test_Runs/best_result/AC201_AL_board_test.bit -mode program_spi -v -spd 7 -cable 0 -flashsize 128 >> flash.txt
echo exit >> flash.txt
D:\Anlogic\TD_Release_2026.2.210.850\bin\td_commands_prompt.exe < flash.txt > out\flash.log 2>&1
```

---

## 3. 架构全景

### 3.1 四个时钟域

| 域 | 频率 | 承载 | 端点 | 建立裕量 |
|---|---|---|---|---|
| `sys_clk_50m` | 50 MHz | SD SPI、卡带加载、WAV 解析、遥测 | 2153 | **+2.180 ns** |
| `pix` (U_pll clkc[1]) | 73.30 MHz | 视频管线、CPU、精灵、混音、WAV 输出侧 | 7433 | **+0.659 ns** |
| SDRAM (sdram_pll1 clkc[0]) | 100 MHz | SDRAM 控制器 | 514 | **+2.535 ns** |
| LVDS 串行器 (clkc[2]) | 366.7 MHz | TMDS 10:1 移位 | 49 | **+0.721 ns** |
| pix → LVDS 跨域 | — | TMDS 装载 | 31 | **-0.690 ns（伪违例，见 §6 E2）** |

跨域只允许三种方式：**双口 BRAM FIFO + 格雷码指针**、**2FF 同步单 bit**、**toggle 握手**。禁止多比特直通。

### 3.2 顶层模块树

```
hardware_test_P0_UART_V5_CRC32.v      ← 顶层：开关/按键、SD 监督、探针例化、遥测、LED
└── design_top_wrapper.v              ← 集成层（GBK 编码！）
    ├── yingxu_sdram_framebuffer      ← SDRAM 四端口 + 帧缓冲读写端口
    │   └── yingxu_sdram_control_4port + src/5640/sdram_ctrl_4p/*（厂商 IP）
    ├── yingxu_bmp_loader             ← BMP 头解析 + 像素写入帧缓冲
    ├── yingxu_sdram_video_player     ← 帧缓冲读出 → RGB 像素流
    ├── yingxu_sprite_engine          ← 6 槽精灵叠加（48×48 位图掩码）
    ├── yingxu_tile_layer             ← 图块层
    ├── yingxu_invaders               ← 硬件版流浪者（纯 FSM）
    ├── yx8_cart_soc (u_cart)         ← 卡带 SOC：SD 解析 + 24bit 指令 RAM + CPU + 精灵提交
    │   └── yx8_cpu                   ← YX-8 8 位 CPU
    ├── yingxu_psg                    ← 4 音色方波音效（48 kHz）
    ├── yingxu_wav_player (u_wav)     ← SD WAV 播放器（异步 FIFO + 分数采样率）
    ├── 混音器                         ← psg + wav 饱和相加 → HDMI 音频包
    └── 视频/音频发送 + HDMI 1.4b 发送器（厂商 enc IP）
```

SD 字节流是**广播式**的：探针 `yingxu_sd_integration_probe` 输出 `valid/data`，多个消费者各自取用，**背压权由 mux 决定**：

```verilog
// design_top_wrapper.v:319
assign O_bmp_sd_ready = I_music_en ? wav_sd_ready : bmp_sd_ready;
```

### 3.3 三条数据通路

**① 照片（SW7 OFF）**
```
SD LBA img_lba → 探针 → BMP loader（解析头）→ SDRAM 帧缓冲 → video_player → HDMI
```
- 5 秒自动轮播、K0/K1 手动翻页、淡入淡出转场、加载时数码管追逐动画
- 每张图一次 5401 扇区（2.7 MB）连续读

**② 音乐（SW7 ON + SW4 ON + SW5/SW6 OFF）**
```
SD LBA 2,000,000 → 探针 → WAV 解析（YXMA 头）→ 打包 32bit L/R → 异步 FIFO(1024×32)
   → pix 域按文件 rate 分数弹出 → 24bit → 饱和混音（+PSG）→ HDMI
```
- 文件格式 `YXMA`（见 §8.3）
- 分块：每块 5401 扇区（2,765,312 B），块尾自动推进到下一块并 restart 探针
- 背压：`sd_ready = music_active && (sstate != S_DONE) && (occ < 768)`

**③ 卡带（SW7 ON + SW5 ON）**
```
SD LBA 1,000,000/1,001,000 → 探针 → 卡带 SOC：
   解析 YXC 头 → 指令写入 24bit×1024 指令 RAM（pix 域）
   → YX-8 CPU 取指执行（S_WAIT 二段取指对齐 BRAM 延迟）
   → 写 MMIO：精灵寄存器(0xE8-0xF1) / 音效事件 → 精灵引擎 + PSG
```

### 3.4 存储映射（板子视角 LBA）

| 区域 | 起始 LBA | 大小 | 说明 |
|---|---|---|---|
| 照片 | `img_lba[]`（约 32672 起） | 每张 5401 扇区 | 由 `lba_rom` 表给出 |
| 卡带槽 A | **1,000,000** | 512 扇区 | SW6 **ON** → 流浪者（604 词） |

> 词数说明（2026-10-31 校正）：`invaders.yxc` 实为 **604 词**（1844 B = 32 B 头 + 604×3 B，头部 words 字段与 `yxa` 重建一致）。历史文档 `HANDOFF_20261029.md` 记的 606 词是 10-29 07:07 的旧版本，同日 18:13 调游戏手感后变更为 604。遥测 `WC` 对应当前镜像应为 **25C**（604），若读到 25A（606）说明板上是旧卡带。
| 卡带槽 B | **1,001,000** | 512 扇区 | SW6 **OFF** → 打砖块（492 词） |
| 音乐槽 0-3 | **2,000,000 + i×98,304** | 每槽 98,304 扇区（48 MB） | 当前槽 0 放 Higher（48k, ×0.5 增益） |
| 视频槽 0-3 | **3,000,000 + i×524,288** | 每槽 256 MB | 规划中（`video2yxv.py --write`） |

> **物理卷扇区 = 板子 LBA − 2048**（FAT32 分区偏移）。所有写卡工具都已补偿；
> 自己写临时脚本时**必须减 2048**，否则数据会错位写入（踩过，见 §6 E5）。

### 3.5 YX-8 CPU 要点

- 8 位寄存器组，16 位 PC，24 位指令（`op[23:16] | dst[15:12] | src[11:8] | imm[7:0]` 等变体）
- 取指延迟固定 2 拍（BRAM 寄存读 + `raddr_q` 打拍），CPU 用 `S_WAIT` 状态对齐
- MMIO：`0xE8 SEN / 0xE9-EA X / 0xEB-EC Y / 0xED SW / 0xEE SHT / 0xEF-F0 COLOR / 0xF1 COMMIT / 0xFE STAGE`
- 工具：`yxa.py`（汇编）、`yxem.py`（周期精确模拟，`--cosim` 出金标轨迹）、`yxc2hex.py`（转仿真 hex）
- **金标回归**：RTL 逐指令轨迹 vs 模拟器金标，`cosim_diff.py` 输出 `BADC0UNT=0` 才算通过

---

## 4. 已完成功能（可验收）

### 4.1 多媒体

| 功能 | 验收方式 |
|---|---|
| BMP 照片浏览 | SW7 OFF，K0/K1 翻页，可见 1280×720 全屏照片 |
| 自动轮播 + 淡入淡出 | 静置 5 秒自动换图，过渡有黑场渐变 |
| 音乐播放（48 kHz 无损直通） | SW7+SW4 ON，槽 0 歌曲完整循环，无杂音 |
| 音乐与音效混音 | 游戏模式下 BGM 与 PSG 音效同时可闻 |
| 音量 | 音乐峰值 -12 dBFS（×64），PSG ±1/32 FS |

### 4.2 游戏

| 功能 | 验收方式 |
|---|---|
| 卡带·宇宙流浪者 | SW7+SW5+SW6 ON，604 词，三档敌机/炸弹/三心/按键重开 |
| 卡带·打砖块 | SW7+SW5+SW6 OFF，492 词，球速/挡板/三心 |
| 硬件·流浪者 | SW7+SW5 OFF+SW6 ON，纯 FSM，判定经 1200 帧仿真 0 误判 |
| 48×48 位图精灵 | 炮台/敌机按 96 bit/行 掩码逐像素绘制 |
| PSG 音效 | 击毁 880 Hz / 反弹 440 Hz / 失败 220 Hz / 通关 1320 Hz |

### 4.3 计算机

| 功能 | 验收方式 |
|---|---|
| 卡带加载 | 断电重启后 `WC=604`/`494` 遥测（0 表示未加载） |
| CPU 执行 | 游戏可玩即证明；另有一套 torture1-5 压力测试卡带 |
| 金标一致性 | `cosmos_diff.py` → `BADC0UNT=0` |
| 遥测 | COM5 每秒 4.3 帧（230 ms/帧），D 帧含 CPU/SD/播放器状态 |

---

## 5. 冻结基线（2026-10-31）

| 项 | 值 |
|---|---|
| 固件 | `release/RELEASE_g32_FROZEN_20261031.bit`，630,802 B |
| SHA256 | `8774def738b2fb9854f2fc6b597d5dc765ea3fa7dbc183b7c9a6fa6a4caf08c0` |
| LUT | 10,519 / 19,600（**53.67%**） |
| REG | 5,730（29.23%） |
| BRAM | 39 / 64（60.94%） |
| DSP | **0 / 29（0%）** |
| 时序 | pix +0.659 / sys +2.180 / SDRAM +2.535 / LVDS +0.721 ns；仅 pix→LVDS 伪违例 |
| 卡带 | 流浪者 604 词、打砖块 492 词 |
| 音乐 | 槽 0 = Higher，48 kHz，213.5 s，增益 ×0.5（写入前衰减） |

**冻结的含义**：除非明确解冻，否则不改 RTL、不重新构建固件。所有新功能在复赛分支上做。

---

## 6. 问题档案（**本文件最有价值的部分**）

> 每条格式：症状 → 定位手段 → 根因 → 修复 → 回归判据。
> 编号 `B*` 是逻辑/硬件 bug，`E*` 是工程环境坑。

### B1 · CPU 寄存器写回未受状态机门控（非幂等指令双执行）
- **症状**：`SHLI`/`SHRI` 等非幂等指令执行两次，结果翻倍/四分之一
- **定位**：`tb_yx8_cosim` 逐指令轨迹比对，发现同一指令 retire 两次
- **根因**：写回使能是组合信号，`S_WAIT` 等待拍也在写
- **修复**：写回只在指定状态拍有效（`state == S_EXEC` 等）
- **判据**：`torture1-5` 金标 `BADC0UNT=0`

### B2 · 复位后首条 JSR 取到第一字
- **症状**：开机第一条 `JSR` 跳转地址错，程序跑飞
- **根因**：`JMP/JSR` 直接进 `F2` 重取，但 BRAM 寄存读还停在旧地址
- **修复**：`JMP/JSR` 也经 `S_WAIT` 再进 `F2`（二段取指统一）
- **判据**：`dbg_jsr.asm` 判官卡带亮绿色

### B3 · 元数据字恰好构成 JMP + L_DATA 尾字跳过填充
- **症状**：某些卡带随机跑飞，与内容相关
- **根因**：加载器把数据区元数据字当指令执行；且数据区尾字路径跳过了清零填充
- **修复**：`L_META` 状态显式消费元数据；`L_DATA` 尾字后强制进 `L_FILL`
- **判据**：`tb_burst.v` 逐词比对 `BADC0UNT=0`

### B4 · SW6 换槽不触发精灵表擦除
- **症状**：换卡带后残留上一款游戏的精灵
- **修复**：`cart_swap`（SW6 边沿）触发精灵表清除 + reload
- **判据**：换槽后画面干净（**需断电重启，热切换不可靠**）

### B5 · 硬件流浪者判定区间错误（子弹打空气命中）
- **症状**：子弹离敌机很远就"命中"，被击落的却是别的敌机
- **定位**：`tb_inv.v` 逐帧打印子弹/敌机矩形，凡"无矩形重叠却触发 o_ev_hit"就报错
- **根因**：`in_range` 用 `COLS*SPACE_X`(512 px = 4 格)，但每排只有 2 架（0..255）
- **修复**：`d < 2*SPACE_X`
- **判据**：1200 帧仿真 **0 次误判**

### B6 · 命中索引位宽错误
- **症状**：打黄机消紫机；紫机打不掉
- **根因**：`emask` 是"每排 2 架"的 6 位布局，索引应为 `{band, d[7]}`（3 位），误改成 4 位
- **修复**：恢复 3 位索引
- **判据**：`tb_inv.v` 命中索引与预期一致

### B7 · 敌机半出界仍开火（虚空子弹）
- **症状**：看不见的敌机射出子弹
- **修复**：`spawn*_ok` 要求整机在屏内（左右各留 48 px）

### B8 · 清空一波立刻重生
- **修复**：`emask=0` 空 120 帧（2 秒）后再入场，空场期间关 6 个精灵槽降载

### B9 · WAV FIFO 写数据未连线
- **症状**：音乐全静音，读出全 `z`
- **定位**：`tb_wav_dbg.v` 打印 `ram[raddr]` 与 `rdata`——`ram` 有值但读出 `z`
- **根因**：`assign wdata = ...` 漏写，`dina` 浮空
- **修复**：接上打包结果
- **判据**：仿真 `rdata` 与写入值一致

### B10 · 格雷码反解码错误
- **症状**：FIFO 占用率计算离谱，背压不工作
- **根因**：反格雷必须**组合前缀异或**（`dec[i] = dec[i+1] ^ gray[i]`），原实现逐位独立
- **修复**：改组合前缀链
- **判据**：仿真 `max_occ=768` 精确停在背压水位

### B11 · 字节握手语义（valid 在等 ready 时保持高）
- **症状**：同一字节被重复打包，样本错乱
- **根因**：探针是 AXI 式（valid 保持到被消费），播放器却每拍都计一个字节
- **修复**：`wire byte_v = sd_valid && sd_ready;` 所有消费点统一用它
- **判据**：`pops` 与文件帧数精确相等（24000 样本一个不少）

### B12 · 16→24 位扩位：30 位拼接塞进 24 位（位序旋转）
- **症状**：**刺耳噪音**（跟着音乐包络起伏的杂音）
- **根因**：`{符号位, L[15:0], L[15:3]}` = 30 位，截断后位序变成 `{L[10:0], L[15:3]}`，连符号位都错
- **修复**：`{rdata[31], rdata[31:16], 7'd0}`（×128）；后调为 `{{2{sign}}, L, 6'd0}`（×64）
- **判据**：逐拍核对 `rdata=0x019B → wav_l=0x00CD80`（×128）；负样本符号正确

### B13 · `rate_tick` 比 `out_tick` 晚一拍 → 每拍插入 1 拍宽清零毛刺
- **症状**：音乐"没声音"或全是噪声（取决于消费端锁到哪个相位）
- **根因**：清零分支挂在 `out_tick`，而 `rate_tick` 是其寄存器延迟一拍
- **修复**：清零分支改挂 `rate_tick`（与 pop 同拍互斥）
- **判据**：`tb_wav_dbg` 中 `wav_l` 不再出现意外 0

### B14 · 断流看门狗阈值过短（1.31 ms）
- **症状**：g27 LED3 高频闪（肉眼像常亮）；重启风暴
- **定位**：LED 语义化（LED3=看门狗触发）
- **根因**：SD 单扇区取数本身就要 0.7–1 ms，valid 占空比极低 → 每个扇区间隙都误触发
- **修复**：阈值改 333 ms（`24'd16_666_666`）+ 追加条件 `occ == 0`（真断流=FIFO 空且久无字节）
- **判据**：遥测 `RC` 字段增量 0

### B15 · `consume_acc` 16 位溢出（**44.1 kHz 文件慢放 9.7 倍**）
- **症状**：音乐听不出、只有低频嗡嗡 + 周期杂音
- **定位**：遥测 `pops` 实测 **4561 次/秒**（应 48000）→ Python 复算 16 位累加器得 4559 → 文件头确认 44100
- **根因**：`consume_acc + rate_pix` 在 16 位上下文求和，和 ≥65536 静默回绕。**rate=48000 时 acc 恒为 0 恰好不溢出**，所以 48 kHz 测试音永远测不出
- **修复**：`consume_acc` 改 **32 位**；未触发时才累加（改成分支）
- **判据**：新增 **RATECHK**——`pops/out_tick` 应等于 `rate/48000`（44.1k → 0.9187，实测 0.9185）
- **教训**：见 §9 铁律 1

### B16 · 块推进单位错误（字节数加到扇区地址上）
- **症状**：前 ~15.7 秒正常（带滋滋），之后永久噪音
- **根因**：`base_acc` 是扇区 LBA，却 `+= CHUNK_BYTES`（字节数）→ 从 LBA 4,765,312 读（卡上 2.4 GB 处的垃圾区）
- **修复**：`CHUNK_SECTORS = CHUNK_BYTES >> 9`，推进用扇区数
- **判据**：新增 **CHUNKCHK**——每次块重启时断言 `请求基址偏移 == 已消费扇区数`

### B17 · PSG 空闲输出直流偏置
- **症状**：录音可见 -12 dB 纯直流（扬声器听不出）
- **根因**：`phase=0` → 恒输出 `0xE00000`（-0.25 FS）
- **修复**：`sample = psg_on ? (...) : 24'd0`，空闲真静音

### B18 · 44.1 kHz 文件在 48 kHz 输出网格上零阶保持重采样
- **症状**：安静段落可闻"滋滋"底噪
- **定位**：`_audio_diag.py` 三路判别——MP3 码率 320 kbps、卡上 PCM 与解码**逐位相同（max_diff=0）**、ZOH 重采样额外引入 **-24.3 dB** 误差
- **根因**：不是音源问题、不是写卡问题，是板上重采样
- **修复**：**转卡端用 48 kHz**（`music2sd.py` 默认值），板上 1:1 直通
- **判据**：48k 文件在板上无滋滋声（已验听）

### B19 · 音量过大
- **修复**：音乐 ×128 → **×64（-12 dBFS）**；响度大的素材再用 `music2sd.py --gain 0.5` 在写入前衰减
- **注意**：`{{2{sign}}, L, 6'd0}` 是 24 位；若改 ×32 必须写 `{{3{sign}}, L, 5'd0}` 否则丢符号

### E1 · TD 布线引擎约 50% 崩溃
- **症状**：`wait_run phy_1` 永挂，`tasklist` 只剩 tcl 控制台；`phy_1/seed_*/` 里留着**旧的 bit**
- **处置**：杀挂起进程 → `reset_runs phy_1` 单跑 → **核对 bit 时间戳是当天** → 再烧写
- **危险**：不查时间戳直接 `copy best_result` 会把旧固件当新固件烧

### E2 · pix→LVDS 伪违例（-0.690 ns，31 端点）
- **根因**：`timing.sdc` 把两个 PLL 输出划进同一同步组，工具按单串行周期（2.27 ns）检查装载路径；实际装载由像素域同步链 `S_load_en_2d` 门控，数据稳定窗 ~10.9 ns
- **处置**：冻结期忽略；如需报告全绿，加
  `set_max_delay -datapath_only 13.0 -from [get_clocks {*U_pll/pll_inst.clkc[1]*}] -to [get_clocks {*U_pll/pll_inst.clkc[2]*}]`

### E3 · 编码坑
- `design_top_wrapper.v` 是 **GBK**；`hardware_test_*.v` 含**非 GBK 字节**（严格解码会抛异常）→ 用**字节级正则替换**
- PowerShell 5.1 读无 BOM 的 UTF-8 `.ps1` 会按 ANSI 解析，中文注释打乱语法 → **脚本只写 ASCII**
- Python 内联 `-c` 在此 shell 里**静默失败**（常无输出）→ 一律写成 `.py` 文件执行

### E4 · `write_slot` 写卡失败（原始卷写）
- **根因**：缺 `FSCTL_LOCK_VOLUME` + `FSCTL_DISMOUNT_VOLUME`；64 位 Python 下句柄未声明 `c_uint64` 被截断；写入长度未扇区对齐
- **修复**：`write_cart.py` 的 `Vol` 类（锁卷 + 卸载 + 对齐 + 回读校验）

### E5 · 分区偏移漏减 2048
- **症状**：写入后 `--list` 显示的时长是**旧文件**的（数据错位 1 MB）
- **根因**：自写脚本把板子 LBA 直接当卷扇区用
- **修复**：`卷内扇区 = 板子 LBA − 2048`

### E6 · Verilog 多驱动 / 隐式声明
- `lastl_r` 同时出现在两个 `always` 块 → `HDL-8007 ERROR`（综合直接失败）
- `raddr_q` 在 `u_prog` 例化之后声明 → `HDL-7225 CRITICAL-WARNING`（靠 TD 隐式合并工作，**建议清理**）

### E7 · WAV 分块替换后残留
- **症状**：换成更短的歌后，槽尾残留旧数据
- **处置**：写入后把槽内剩余空间**清零**并回读验证非零字节 = 0

### E8 · PowerShell 窗口层级
- ZCode 全屏时，CUA 坐标点击会命中 ZCode 自己 → 需先手动切窗
- `pressKey("Return")` 在 Chrome 地址栏**不提交导航**，`pressKey("Enter")` 才行

---

## 7. 测试体系

### 7.1 测试台清单

| 文件 | 用途 | 判据 |
|---|---|---|
| `tb/tb_wav_mon.v` | WAV 播放器整链（含 `+file=` 双采样率） | **RATECHK**（pops/out_tick = rate/48000）+ **CHUNKCHK**（基址=已消费扇区）+ 零交叉 |
| `tb/tb_wav_dbg.v` | WAV 逐拍调试（打印 RAM/rdata/wav_l） | 人工核对位序 |
| `tb/tb_psg_tick.v` | PSG 节拍频率 | 200 ms 内 9600 拍 → 48000 Hz |
| `tb/tb_cart_soc.v` / `tb_yx8_cosim.v` | 卡带加载 + CPU 金标 | `BADC0UNT=0` |
| `tb/tb_burst.v`（历史） | 卡带逐词比对 | `BADC0UNT=0 of 435` |
| `tb_inv.v` / `tb_inv2.v`（历史，判定类必用） | 逐帧打印矩形查误判 | 0 次误判 |

### 7.2 仿真命令

```powershell
# WAV 双采样率回归（44.1k 必须跑——48k 会掩盖 B15 那类溢出）
iverilog -g2012 -o out/tb_wav.vvp tb/tb_wav_mon.v `
    src/user_source/hdl_source/yingxu_wav_player.v `
    src/user_source/hdl_source/media/sd/ram_dual_port_simple.v
vvp out/tb_wav.vvp +file=tb/assets/tb_tune.yxm      # 48 kHz
vvp out/tb_wav.vvp +file=tb/assets/tb_tune44.yxm    # 44.1 kHz

# PSG 节拍
iverilog -g2012 -o out/tb_psg.vvp tb/tb_psg_tick.v src/user_source/hdl_source/yingxu_psg.v
vvp out/tb_psg.vvp
```

### 7.3 三条判据设计原则（血泪换来的）

1. **测试激励必须覆盖真实参数** — 只测 48 kHz 会漏掉 44.1 kHz 的累加器溢出；不理会 `wav_base` 会漏掉块推进越界
2. **比值型判据 > 绝对数量判据** — `pops=24000` 正常，但 `pops/out_tick` 才暴露速率错误
3. **仪表先行** — 静音/异常类问题先做 LED 语义化 + 串口遥测，再动 RTL

---

## 8. 工具链

### 8.1 音频

| 工具 | 用途 |
|---|---|
| `tools/music2sd.py` | MP3/任意音频 → 48 kHz 16bit PCM + YXMA 头 → 写音乐槽（锁卷+校验）。**默认 48 kHz 是硬性要求**，非 48k 会打印失真警告 |
| `tools/video2yxv.py` | 视频 → YXV 容器（见 `docs/YXV_FORMAT.md`） |

```powershell
# 音乐：务必用默认 48000；响度大的素材加 --gain 0.5
python tools/music2sd.py --in 歌.mp3 --slot 0 --drive E [--gain 0.5] [--mono]
python tools/music2sd.py --drive E --list          # 查看 4 个槽
python tools/music2sd.py --in 歌.mp3 --out a.yxm   # 只生成不写卡

# 视频
python tools/video2yxv.py --in 片.mp4 --out out/clip.yxv --width 640 --height 480 --fps 24 --quality 4
python tools/video2yxv.py --write out/clip.yxv --drive E --slot 0
```

### 8.2 卡带

```powershell
python tools/yxa.py cartridges/invaders.asm cartridges/invaders.yxc      # 汇编
python tools/check_syms.py cartridges/invaders.asm                       # 撞名检查（yxa 会转大写）
python tools/write_cart.py --drive E --cart cartridges/invaders.yxc --lba 1000000
python tools/write_cart.py --drive E --cart cartridges/breakout.yxc --lba 1001000
```

### 8.3 YXMA 音乐格式（32 字节头）

| 偏移 | 宽 | 字段 |
|---|---|---|
| 0 | 4 | `"YXMA"` |
| 4 | 1 | version=1 |
| 5 | 1 | channels（1/2） |
| 6 | 2 | bits=16 |
| 8 | 4 | sample_rate（**必须 48000**） |
| 12 | 4 | frames |
| 16 | 4 | pcm_bytes |
| 32.. | — | s16le 交织 PCM |

### 8.4 遥测（COM5 / 115200）

每 230 ms 一帧（4 行 A/B/C/D）。**D 帧在音乐模式下被 mux 成播放器内部量**（卡带模式仍为卡带调试字段）：

| 字段 | 音乐模式含义 |
|---|---|
| `MISE` | out_tick 计数（测 PSG 节拍） |
| `SCE` | byte_v 计数（测 SD 吞吐） |
| `SP` | 解析出的 rate |
| `PC` | wav `rptr[9:0]` |
| `DW` | pops 累计 |
| `I0` | `{sstate[1:0], occ[10:0], wptr[10:0]}` |
| `RC` | 看门狗触发次数 |
| `I1` | `{8'd0, last_L[15:0]}`（最近写入的左声道样本） |
| `SW` | 开关字节（**0x6F = 4+7 ON、5+6 OFF**） |

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/music_telem.ps1 -Seconds 6
python tools/music_telem.py            # 解析 out/telem_raw.txt，输出判读结论
```

### 8.5 其他

| 工具 | 用途 |
|---|---|
| `tools/grab.py` / `screen_probe.py` / `track.py` | 采集卡抓帧 / 画面分析 / 逐帧追踪（**OBS 开着时抓帧会报 I/O error，先杀 obs64**） |
| `tools/rec_audio.py` / `rec_av.py` | 采集卡录音 / 录影音（频谱定位音频问题） |
| `tools/yxpad.html` + `test_yxpad_edit.js` | 网页像素画板（Node + DOM 桩自测 9 项断言） |
| `tools/tilekit.py` / `palette.py` | 图块关卡 / 调色板工具 |

---

## 9. 铁律（违反必踩坑）

1. **改文件只用 Python 脚本**，不要用 PowerShell `-replace`（大小写不敏感，曾多次改烂源码）
2. **`design_top_wrapper.v` 是 GBK**；`hardware_test_*.v` 含非 GBK 字节 → 用字节级正则替换
3. **PowerShell 脚本只写 ASCII**（PS 5.1 按 ANSI 解析无 BOM 的 UTF-8）
4. **Python 一律写成 `.py` 文件执行**，不要用内联 `-c`（此 shell 会静默失败）
5. **改 RTL 先仿真**，回归看 `RATECHK` / `CHUNKCHK` / `BADC0UNT=0`
6. **判定类 bug 先写 TB 打印矩形**，别盲改
7. **测试激励要覆盖真实参数**（采样率、文件长度、块边界）
8. **烧写前核对 bit 时间戳是当天**（TD 布线崩溃会留旧 bit）
9. **写卡必须减 2048 分区偏移**；写完必须回读校验
10. **换卡/换模式后断电重上电**（热切换常失败，表现为 `WC=000`）
11. **构建 10 分钟量级、烧写 26 秒**，一次只改一处，别叠加
12. **`yxa` 把所有符号转大写** → 用 `check_syms.py` 扫撞名
13. **冻结期不改 RTL**；新功能开分支
14. **音频一律 48 kHz**（板上输出网格）；非 48k 必重采样，失真 -24 dB

---

## 10. 进行中：YXV 视频管道

### 10.1 已完成

| 项 | 状态 |
|---|---|
| 容器格式 | **已定稿 v1** → `docs/YXV_FORMAT.md` |
| PC 端转换器 | `tools/video2yxv.py` **已跑通**（ffmpeg MJPEG + PCM，含 5 条自检断言） |
| 测试向量 | `out/testsrc.yxv`（合成 6 s）、`out/xinji_480p.yxv`（真人 20.2 s） |
| 带宽实测 | 640×480@24 真实内容 **0.92 MB/s**（含音频） |

### 10.2 未开始

| 项 | 预估 |
|---|---|
| **MJPEG 解码器 RTL** | Huffman 解码 ~1.5K LUT + IDCT ~2K LUT + 6 DSP + YCbCr→RGB565（移位加法）→ **3–5 天最小版** |
| SPI 提速 | `SPI_HIGHFREQ` 6.25 → 12.5/25 MHz（**一个参数**，但要走完照片/音乐/卡带全回归） |
| 2× 放大显示 | 640×480 铺满 720p（显示读路径像素倍增），半天 |
| 音画同步 | 音频采样计数推进帧号（`frame = samples_played * fps / 48000`） |

### 10.3 为什么是 640×480@24 而不是 720p

SDRAM 只有 **8 MB**；720p 双缓冲 3.7 MB（占 46%），显示刷新固定开销 **110 MB/s**，SDRAM 带宽上限 ~150 MB/s：

| 方案 | 写入带宽 | 判定 |
|---|---|---|
| 720p@24 | 44.2 MB/s → 总 154.2 | ✗ 超限 |
| 720p@15 | 27.6 → 总 137.6 | △ 贴地飞行 |
| 640×480@30 | 18.43 → 总 128.4 | ✓ 可行 |
| **640×480@24** | **14.75** → 总 124.8 | ✓✓ **推荐** |

> 注：640×480 两行于 2026-10-31 修正。原记 13.8 / 11 MB/s 有误——
> 正确算法：640×480×2 B = 614,400 B/帧，@24fps = **14.7456 MB/s**
> （由 `docs/DESIGN_MJPG.md` §1.1 的核算纠正）。

H.264 基线要 25–50K LUT（超预算 2–3 倍），**MJPEG 是唯一可行路线**。

---

## 11. 路线图

### 11.1 初赛前（已完结）

- [x] 冻结固件 g32 + SHA256 + `docs/FREEZE_20261031.md`
- [x] GitHub 仓库上线（私有）
- [ ] **录演示视频（5 段）+ 答辩材料** ← 唯一剩余项

### 11.2 复赛（按优先级）

> **⚠️ 2026-11-26 修订：MJPEG 解码器一项已作废，不要再做。**
> 视频显示已整体移交板 B（VQ/YXV2 解码 + HDMI 出图），板 A 只负责把 `.yxv2`
> 字节流按帧率喂过去，**不需要任何视频解码器**；仓库里也从来没有 MJPEG 解码 RTL。
> 原 P0 是双板架构确定之前写的（当时板 A 要自己解 YXV/MJPEG 并显示）。
> 格式区分见 `docs/FORMAT_INDEX.md`：`YXV v1`（MJPEG 容器，`tools/video2yxv.py`）
> 属板 A 单板旧路径，**当前架构不使用**；在用的是 `YXV2`（VQ，`tools/vq_encode_stream.py`）。

| 优先级 | 项 | 成本 | 价值 |
|---|---|---|---|
| ~~P0~~ | ~~**MJPEG 解码器 + 视频播放**~~ → **已作废**（视显示移交板 B，见上方修订） | — | — |
| **P0** | **VQ 端到端产品化**：SD 存 `.yxv2` + 板 A 按帧率推流 + 板 B 播放控制（循环/切段/暂停）<br>**↳ 2026-11-27 P6：A→B 传输链路仿真闭合**（`yx_a_vq_sender` + `p6_e2e`，7 入口全 PASS）。<br>**↳ 2026-11-28 P7-a：B 入口 FIFO 16KB（AW=14，4×bram32k 显式例化）+ 速率提到 KEY 2.0 MB/s（平均 1.81 MB/s，较 P6 +69%），零丢包全项 PASS**；速率上界实测夹在 KEY 2.0~4.11 MB/s（4.11 档丢 30 包）。<br>**⚠ 结构限制（P7-a 实测修正）**：B 的消费是"线速爆发 + 帧边界长停顿"，停顿不是常数——随 A 节奏超线性增长（1.07 MB/s 档 ≤5.5ms → 4.11 档 ~15ms）。开环 + 现有 BRAM 预算（16KB FIFO 上限）**无法实时**；更大 FIFO 此路不通（24KB 用光空闲、64KB 装不下）。实时需要 **A→B 反压通道**（B 的 `fifo_room` 信号现成）或 **B 侧 RTL 消帧边界串行化**。详见 `docs/YX_BBOARD_P7_PACING_20261128.md`。剩余：SD 扇区读取接入、播放控制、上板联调。 | 1–2 天 | 视频叙事闭环（板 B 已做到 720p60 实时） |
| P1 | **WM8960 耳机口输出** | ~1 天 | "独立于显示器的音频"（方案已备 §11.3） |
| P1 | **菜单 UI** | ~1 天 | 产品形态（照片背景 + 精灵高亮条，开关保留兜底） |
| P2 | **基于精灵引擎自研游戏** | 3–5 天 | 视频管道 → 卡带含过场动画/纹理/BGM |
| P2 | 精灵引擎 SDRAM 纹理采样 | 2 天 | 美术资产从"烧进芯片"变成"卡带内容" |
| P3 | 音频频谱可视化 / RTC 时钟 / EEPROM 最高分 | 各半天 | 彩蛋 |
| P4 | OV5640 摄像头预览 | 1–1.5 天 | 需实物模块（参考代码在 `src/5640`） |
| — | 千兆网 UDP 相册 | 1–2 天 | 参考栈不在本仓库（在厂商资料里） |


### 11.3 WM8960 方案（已推导，未实现）

- 芯片确认：原理图 `LibReference=WM8960CGEFL/RV`（**不是 ES8388**，厂商 demo 的 `ES8388_init_table.v` 不适用）
- MCLK：`50 MHz ÷ 32 = 1.5625 MHz`（计数分频，50% 占空比）
- 芯片 PLL：`R = 12.288/1.5625 = 7.86432` → PLLN=7, SDM_FRAC，K=`0xDD4413`
  → SYSCLK = 12.288 MHz，BCLK = SYSCLK/4 = 3.072 MHz，LRCK = 48 kHz
- 寄存器序列（依据 Linux `wm8960.c` 分频规则推导，**需板上验证**）：
  `0x0F RESET → 0x19 PWR1(VREF|VMIDSEL) → 0x34..0x37 PLL → 0x1A PWR2(PLL_EN|DACL|DACR) → 0x04 CLK1(CLKSEL=PLL) → 0x08 CLK2(BCLKDIV=÷4) → 0x07 INTF0(MS|I2S|16bit) → 0x0A/0x0B DAC vol → 0x05 CTR1(unmute) → 0x22/0x25 out mix → 0x2F PWR3 → 0x02/0x03 LOUT1/ROUT1 vol → 0x1A PWR2(+LOUT1|ROUT1)`
- FPGA 侧：I2S 从机 TX（BCLK/LRCK 由芯片给），小异步 FIFO 复用 WAV 播放器的格雷码 CDC 模式
- ⚠️ **IO.adc 的 I2S 引脚命名与管脚表不符**：`I2S_DO` 分在 A8（管脚表是 DACLRC），真正的 DACDAT(A7) 被命名成 `I2S_RCLK`。实现时**以管脚表为准重排约束**

---

## 12. 给 Codex 的协作约定

### 12.1 动手前必读

1. 本文件 §3（架构）、§6（问题档案）、§9（铁律）
2. 改哪块先读对应模块头部注释（每个 `yingxu_*` / `yx8_*` 都有设计说明）
3. 涉及音频/视频，读 `docs/YXV_FORMAT.md`、`docs/AUDIO_PLAN_20261028.md`

### 12.2 代码风格（与现有代码一致）

- Verilog-2001 风格（`always @(posedge clk)`，不用 `always_ff`）
- 中文注释说明**为什么**（尤其坑），英文标识符
- 时间常数写注释：`localparam [23:0] WDOG_LIMIT = 24'd16_666_666; // 333ms @50MHz`
- 跨域注释必须写明同步方式

### 12.3 改动纪律

- **一次只改一处**，改完立即仿真/构建（构建 10 分钟级）
- RTL 改动必须同时**新增或更新判据**（比值型优先）
- 不要"顺手优化"冻结模块（时序已收敛在 +0.66 ns）
- 提交信息写清"改了什么 + 判据是什么"

### 12.4 禁止事项

- ❌ 改 `al_ip/`、`src/5640/`、HDMI enc IP（厂商 IP，改不动也修不好）
- ❌ 用 `PowerShell -replace` 改源码
- ❌ 未核对 bit 时间戳就烧写
- ❌ 在 8 MB SDRAM 假设下设计 720p 全屏 30 fps（会超带宽）
- ❌ 把音乐/视频素材提交进仓库（版权）

### 12.5 环境注意事项

- **唯一工作目录**：`C:\Users\HXF\Desktop\yingxu-fpga`（构建、烧录、git 都在这里；详见 §2.3）
- Python 无 pip → 只用标准库
- 无 `git` 在 PATH → `C:\Users\HXF\mingit\cmd\git.exe`
- ffmpeg 需自行下载到 `tools/ffmpeg/`
- 采集卡与 OBS 互斥

### 12.6 与 Codex 云端协作的正确姿势

Codex 只能看到 **GitHub 上的仓库**，**不能直接烧板子**（板子、TD、SD 卡都在本地）。
所以闭环是：

```
Codex 改 GitHub 仓库
        ↓ 用户在 GitHub Desktop 里 Pull（或 git pull）
C:\Users\HXF\Desktop\yingxu-fpga  ← 唯一源码真身，同时就是构建目录
        ↓ TD 构建（§2.4）
yingxu-fpga\AC201_AL_board_test_Runs\best_result\AC201_AL_board_test.bit
        ↓ 核对时间戳后烧写
板子
```

**给 Codex 的路径清单（它可以写进自己的说明里）**

| 用途 | 路径（仓库内相对路径） |
|---|---|
| TD 工程 | `AC201_AL_board_test.al` |
| 顶层 | `hardware_test_P0_UART_V5_CRC32.v` |
| 自研 RTL | `src/user_source/hdl_source/yingxu_*.v` / `yx8_*.v` |
| SD 层 | `src/user_source/hdl_source/media/sd/` |
| 测试台 | `tb/*.v` + `tb/assets/*.yxm` |
| 工具 | `tools/*.py` |
| 约束 | `timing.sdc` / `IO.adc` |
| 文档 | `docs/` |
| 冻结固件 | `release/RELEASE_g32_FROZEN_20261031.bit` |

**注意**：`hardware_test_*.v` 与 `design_top_wrapper.v` 在本地是 **GBK**，
仓库里是 **UTF-8**（文本等价，已验证 `text_equal=True`）。Codex 改完推上来是 UTF-8，
用户在本地构建没问题（TD 对注释编码不敏感）。若 Codex 需要本地 GBK 副本，
用 `src/user_source/hdl_source/design_top_wrapper.v` 的 UTF-8 版即可，不要试图反向转码。

---

## 附录 A · 目录结构

```
AC201_AL_board_test.al          TD 工程（Path 属性 = 仓库自身绝对路径）
AC201_AL_board_test_Runs/       TD 构建输出（gitignore；best_result/*.bit 就是要烧的文件）
hardware_test_P0_UART_V5_CRC32.v 顶层（本地 GBK 混合字节 / 仓库 UTF-8，用字节级编辑）
timing.sdc / IO.adc              时序 / 管脚约束
src/user_source/hdl_source/      自研 RTL（yingxu_* / yx8_*）
  media/sd/                       SD 命令层（厂商）+ 流式读取层（自研）
  media/bmp/                      BMP 头解析
  hdmi1.4b_transmitter_core/      HDMI 发送（厂商 enc）
src/5640/                         SDRAM 控制器（厂商）
al_ip/                            TD IP（PLL/FIFO/ODDR）
tb/                               测试台 + assets/（仿真音频）
tools/                            汇编器 / 模拟器 / 写卡 / 遥测 / 画板 / 视频转换
cartridges/                       YX-8 汇编源码 + .yxc 镜像
docs/                             设计文档与调试实录
release/                          冻结固件 + SHA256SUMS
```

## 附录 B · 常用命令速查

```powershell
# 仿真：WAV 双采样率（44.1k 必须跑）
iverilog -g2012 -o out/tb_wav.vvp tb/tb_wav_mon.v src/user_source/hdl_source/yingxu_wav_player.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v
vvp out/tb_wav.vvp +file=tb/assets/tb_tune44.yxm

# 仿真：PSG 节拍
iverilog -g2012 -o out/tb_psg.vvp tb/tb_psg_tick.v src/user_source/hdl_source/yingxu_psg.v
vvp out/tb_psg.vvp

# 汇编 + 写卡带
python tools/yxa.py cartridges/invaders.asm cartridges/invaders.yxc
python tools/write_cart.py --drive E --cart cartridges/invaders.yxc --lba 1000000

# 音乐写卡（务必 48 kHz）
python tools/music2sd.py --in song.mp3 --slot 0 --drive E

# 视频转码 + 写卡
python tools/video2yxv.py --in clip.mp4 --out out/clip.yxv
python tools/video2yxv.py --write out/clip.yxv --drive E --slot 0

# 板上诊断
powershell -NoProfile -ExecutionPolicy Bypass -File tools/music_telem.ps1 -Seconds 6
python tools/music_telem.py
```

## 附录 C · 开关模式表（实测，以此为准）

| 模式 | SW7 | SW4 | SW5 | SW6 | 校验遥测 |
|---|---|---|---|---|---|
| 照片浏览 | OFF | - | - | - | `GM=0` |
| **音乐播放** | ON | **ON** | OFF | OFF | `SW=6F` `GM=1` |
| 卡带·流浪者 | ON | - | **ON** | **ON** | `WC=604` |
| 卡带·打砖块 | ON | - | **ON** | OFF | `WC=492`(`1EC`) |
| 硬件·流浪者 | ON | - | OFF | **ON** | `LS`/`SP` 变化 |

- 音乐模式下 LED0-3 = 使能 / FIFO 有数据 / 已进入播放态 / 断流看门狗
- 换卡或换模式后**必须断电重上电**

## 附录 D · 术语

| 术语 | 含义 |
|---|---|
| YX-8 | 自研 8 位 CPU（16 位 PC，24 位指令） |
| 卡带 / YXC | SD 卡上的指令镜像，含 `YXCT` 头 + 24 位指令序列 + 数据区 |
| YXMA | 音乐容器（32 B 头 + s16le PCM） |
| YXV | 视频容器（32 B 头 + 帧表 + MJPEG 帧 + PCM 音轨） |
| 探针（probe） | `yingxu_sd_integration_probe`，把 SD 变成 valid/ready 字节流 |
| 块（chunk） | 一次探针 restart 读取的单位：5401 扇区 = 2,765,312 B |
| 金标（golden） | `yxem.py` 模拟器产生的指令级参考轨迹 |
| 判官卡带 | 用画面颜色直接表达自检结果的测试程序（绿=通过） |
