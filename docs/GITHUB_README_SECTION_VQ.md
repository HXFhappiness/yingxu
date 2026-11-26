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
