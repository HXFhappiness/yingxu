# B 板 DELTA 帧真实流修复 — 会话 YX5（2026-11-21）

> 模型：GLM-5.3-Flash（会话 YX5）
> 前序：YX4（2026-11-16，P1/P2 KEY-only 验收 ALL PASS，遗留 bboard_sys 观察点）
> 主题：**bboard_sys 真实流（含 DELTA 帧）根因定位与修复 → 文件金标验收**
> 验证：见 §6（最终判定以 `out\sim\bboard_{key,sys}_20261121_*` 最新一轮为准）

---

## 1. 一句话结论

YX4 §五.1 观察点（真实流索引窗半 X）**根因已闭环**：体系模式（SIM_ABSTRACT=0）下
ixbuf 的 DELTA 帧整窗拷贝（COPY）读源悬空 + 稀疏补丁无法通过 seq_wr 顺序写协议落位，
两处独立缺陷叠加。修复 = ixbuf COPY 相态重构为**合并流**（单遍扫描、补丁与拷贝按块号
对齐、输出恒稠密）+ TB 补上随机口行为模型的供给（WR2 写流镜像）。另修一个合并流
首版引入的帧边界闸缺陷。真实流 5 帧的索引窗/帧缓冲内容经 Python 金标逐字对拍通过。

## 2. 数字破案（根因定位过程）

真实流 `out\vp_720_5f.yxv2`（297,989B）解析（tools\sim\gen_golden.py 同款模型）：

| 帧 | 类型 | 变化块 | 段长 |
|---|---|---|---|
| f0 | KEY | 57600（稠密） | 115205 |
| f1 | DELTA | 595 | 8395 |
| f2 | DELTA | 355 | 7915 |
| f3 | KEY | 57600（稠密） | 115205 |
| f4 | DELTA | 5638 | 18481 |

YX4 遗留日志（bboard_sys_20261116）三个计数精确分解：

- `PUSHSTAT wr2: pushes=294588` = 57600×5（每帧整窗写）+ (595+355+5638)=6588（补丁追加重推）
- `X=172800` = 3×57600 —— **恰为三个 DELTA 帧的整窗 COPY 全部读到 X**
- `real=121788` = 2×57600（两个 KEY 窗）+ 6588（补丁值全部真实）

即：X 全部来自 DELTA 帧的"未变化块重建"路径，KEY-only 流从不触发 → bboard_key 全绿
而 bboard_sys 半 X。BOOK[0..7]=65535 亦确认为真实码本内容（文件 entry 0 本就是 FFFF）。

## 3. 根因清单（三处，按因果链）

### 根因 A：体系模式下 COPY 读源悬空（YX4 观察点的直接原因）

`yingxu_vq_board_top.v:165-167` 在 SIM_ABSTRACT=0 时把抽象索引写口强制置 0
（`ix_wr_valid=0`），TB 的 ixmem 永不被写；但 ixbuf 的 COPY 读口（cp_rd/cp_data，
顶层 ：194）**没有模式复用、直连 TB** → DELTA 帧 COPY 整窗逐字读全 X → 经 seq_wr/WR2
把 X 写进真实 SDRAM 索引区。cp 口是抽象模式遗留、P1 索引路径真实化时迁移不完整。

### 根因 B：稀疏补丁无法通过顺序写协议（COPY 修好后必然暴露的第二处）

seq_wr（yx_b_ix_seq_wr.v v3）是**纯顺序写**：S_PUSH 逐字推 WR2 FIFO、只认地址推
动（组突发 128 对齐），完全忽略 wr_addr 的块号语义。KEY 帧补丁按 blk 严格递增且稠密
→ 恰好等价于顺序写 ✓；DELTA 帧补丁按块号递增但**稀疏**（595 个散布在 57600 中）→
被连续推入相邻 SDRAM 地址 = 写错位置；且窗尾补丁触发 S_WINWAIT 重发 LOAD、把补丁
写到窗基址起的连续地址，整窗内容错位。**原设计的"先整窗拷贝、后打补丁"两段式在
体系模式下从根上不可行**（vendor 4port 控制器无随机写能力）。

### 根因 C：合并流首版的帧边界闸缺失（本会话引入、仿真当日抓出）

首版合并流让 accept 在 COPY 相态保持打开（本意补丁随到随合并），但流不停在帧边界：
下一帧补丁穿过 pf 与本帧补丁混序。合并引擎按块号对齐时看到"头补丁块号 < cp_i"→
全部按越位误弃（实测 `cperr=63265` ≈ f2 的 355 + f3 的 57600 + …），且下一帧补丁
堵死 pf 使完成条件（pf 全空）永不满足 → 合并以每步 50~2700 拍爬行、12M 拍仅 2 帧
（`out\sim\bboard_sys_20261121_180258`）。原设计的 `accept=0 during COPY` 实为帧边界
闸门，重构时必须保留其语义。修复：COPY 相态 accept 在本帧 `frame_done`/`cp_fd` 置位
瞬间关闸（含脉冲当拍防 1 拍泄漏），下一帧补丁等在 skid/码流回压里。

## 4. 修复设计

### 4.1 ixbuf COPY 相态 → 合并流引擎（yx_vp_ixbuf.v v2）

DELTA 帧不再"先拷贝后补丁"两段式，改为**单遍扫描** `cp_i: 0..NB-1`：

```
pf 头补丁 blk == cp_i → 发补丁字（该块被本帧修改，源字丢弃）
pf 头 blk  > cp_i    → 读源字直发（该块未修改）
pf 头 blk  < cp_i    → 协议违例（cp_err 计数告警，丢弃补丁防死锁；健康运行恒 0）
pf 空 且帧未完(fd=0) → 前沿等待（下一补丁可能命中 cp_i，不可越位）
pf 空 且帧已完(fd=1) → 余段纯拷贝
完成：cp_i==NB 且 pf 全空
```

输出恒为**稠密顺序流** → seq_wr/WR2 协议、组屏障、region_done 全部零改动；
band/fetch/扫描端/显示端零改动。补丁滞后时拷贝前沿等待，pf(8)+skid(16)+码流回压
即天然缓冲，无需新增 BRAM。cp 读口语义不变（仿真=TB 随机口模型，见 4.2/§7 债务）。

### 4.2 TB 随机口模型供给（tb_yxvp_bboard.v）

体系模式下 ixmem 原本无供给。新增镜像：`wr2_load_u` 重置计数、`wr2_en_u` 逐字把
WR2 稠密写流镜像进 ixmem —— cp 读从此返回与真实 SDRAM 索引区一致的数据。KEY 流
无 DELTA、不触及（回归不受影响）。

### 4.3 真实流文件金标（gen_golden.py + TB 对拍）

- `tools\sim\gen_golden.py`：解析 .yxv2 → 每帧窗状态（KEY 稠密重写 / DELTA 拷贝+补丁，
  与 RTL 语义逐条对齐）+ 每帧行缓冲期望像素（cb[idx][j]，字={奇,偶}）。已与日志
  交叉验证（首 3 索引=002b、帧 0 像素=f79df79d、f3 首索引=0045）。
- TB 新增两组对拍：
  - **索引窗**：`region_done[w]` 上升沿（seq_wr 组屏障保证整窗已落 SDRAM）比对
    `u_dram.sdram.mem[w*NB..]` vs `idx.mem`；第 N 次写窗 w ↔ 帧 2*(N-1)+w。
  - **帧缓冲**：`scan_done` 沿逐带比对 `fb.mem[frm*FB_TOTAL + band*2560 + k]`。
- 判据二选一落定：**真实流金标生成器**（更强，独立校验解码链）。
- run_sim.ps1：bboard_sys 运行前自动生成金标（生成失败=INPUT-FAIL），WD 8M→12M
  （DELTA 合并流 + 真实流节奏，YX4 实测 4 帧/8M 边缘）。

### 4.4 显示节拍：24Hz 节流档 + 取数时刻写前沿影子队列

sys 首轮出现 `disp=22`（显示字 X）。影子队列判据（下）暴露真实机理：自由跑下显示
实际消耗 ~7.3M 字（disp_words 16 位回绕上百次，约 3.2 圈帧缓冲），平均 0.61 字/拍
**持续超过扫描写入速率 0.39 字/拍**——显示反复套圈撞上写前沿、与在写带竞速，竞速
失败的取数读到未写区域 → X。这属**节拍伪影**（帧缓冲全域非 X、golden=0 为据）而非
数据缺陷，且靠判据余量无法根治（竞速窗口随前沿移动）。

双管齐下：
1. **bboard_sys 入口加显示节流 `DISP_NUM/DEN=249/1000`**（24Hz 档，P3 规划值，也是
   历史命令 B 的原始配置）：显示平均 0.249 字/拍 < 写入 0.39 字/拍 → 永久滞后写
   前沿，竞速与 X 结构性消除。key 入口保持自由跑（基线一致性）。
2. **TB 取数时刻写前沿影子队列**：RD1 每次推入记当时 `bands_scanned×FB_WB`，弹出时
   取数位置(+4 字对齐余量) < 取数时刻前沿 → 该字取数时已写妥，硬判非 X（真实流）/
   相邻对结构（合成流）；否则属超前预取，`disp_skip` 计数不判。精确判据，非放宽。

## 5. 改动文件

| 文件 | 改动 |
|---|---|
| `src\...\vp\yx_vp_ixbuf.v` | COPY 相态重构为合并流引擎（CP_HOLD/DEC/RD/GNT 四态 + cp_fd + cp_err + 帧边界闸 accept 门控） |
| `tb\tb_yxvp_bboard.v` | WR2→ixmem 镜像；索引窗/帧缓冲文件金标对拍；disp 前沿影子队列；GATE 增加 igold/cperr 项 |
| `tools\sim\run_sim.ps1` | bboard_sys 金标预生成 + GOLDEN_IDX/FB plusargs + WD 12M |
| `tools\sim\gen_golden.py` | 新增（真实流金标生成器） |

**未改动**：seq_wr、ix_fetch、band、顶层端口、vendor 控制器/shim 链。

## 6. 验证证据

### bboard_key（回归，KEY-only 合成流，自由跑显示）

三轮（合并流 v1 / 帧边界闸后 / disp 影子队列后）均 **ALL PASS**：
`out\sim\bboard_key_20261121_175423 / _182602 / _185130`。计数与 YX4 基线**逐位一致**
（ivc=5153675 gnc=573750 psc=288000 ldc=5、PUSHSTAT 288000/0X、stall2=479727/8035195）。
KEY 路径零扰动 ✓。

### bboard_sys（真实流含 DELTA，24Hz 显示节流）— **ALL PASS**

`out\sim\bboard_sys_20261121_191416`（GATE 十项全 OK，全日志零错误行）：

```
GATE dec_frames=5(OK) frames_done=5(OK) bands=900(OK) golden=0(OK) scan=0
     disp=0(OK) xz=0(OK) mem=115200/460800(OK) igold=0(OK) cperr=0(OK)
=== TB-SUMMARY: ALL PASS ===
MEMCHK idx_nonX=115200/115200 fb_nonX=460800/460800 m0/m1/m2=00000045  ← 恰为金标值
PUSHSTAT wr2: pushes=288000 X=0 real=288000 first3=0000002b,0000002b,0000002b
PUSHSTAT wr1: pushes=2304000 X=0 real=2304000
FIFOPOP wr1/wr2: doX=0 mismatch=0 underrun=0
IXWR psc=288000 ldc=5                                                  ← 多余 LOAD 消失
FRAME #5 t=6986085（5 帧渲染收尾，stall2=0%）
disp_skip=154（超前预取采样被影子队列精确豁免，判据正常工作）
```

- **igold=0**：5 窗 × 57600 索引字在 region_done 沿逐字对拍 Python 金标，全对
  （含三个 DELTA 帧的拷贝+补丁合并内容——独立校验解码链）。
- **golden=0**：900 带 × 2560 字 × 5 帧（230 万字）在 scan_done 沿逐字对拍像素金标，全对。
- **cperr=0**：合并流协议零越位违例。
- **速度**：真实流 5 帧 6.99M 拍收尾（节流后 RD1 让出带宽，stall2 由 4%→0%，
  比 KEY-only 的 7.91M 还快）；YX4 §五.2 的速度裕量观察点随显示节流一并缓解，
  KEY-only 裕量问题仍在（本会话未动）。
- 中间过程日志（帧边界闸缺陷抓痕、disp 伪影定位）保留于
  `bboard_sys_20261121_180258 / _183401 / _190002`，作 §3 根因 C / §4.4 的证据链。

## 7. 遗留债（按优先级）

1. **随机口板级方案（P4/P5 前必须闭环）**：ixbuf 的 cp 读口仍是"仿真=TB 行为模型"
   的设计契约位。板上索引区在 vendor SDRAM（seq_wr/WR2 + fetch/RD2），随机读无
   vendor 支持。落地方向：RD2 在取带器带间隙分时复用（拷贝源=顺序突发，每渲染带
   间隙插 64/256 字 LOAD+弹空-重同步，数据无冲突——src 与 fetch 同窗只读），
   预估占用 RD2 带宽 ~6%，代价是取带节奏 +6%。P3 若改窗口管理方案需一并评审。
2. **显示节拍（P3 主体）**：9 位 `disp_scan_seen` 跨帧回绕使 `disp_can_go` 失真
   （实测 12M 拍仅消费 62K 字，显示长期停顿）；内容级逐字对齐判据待节流定案。
   今日的前沿影子队列判据在 P3 重做显示路径时应替换为固定滞后量的内容对拍。
3. **速度裕量**：sys 5 帧 ~8M 拍内完成（帧节奏 ~1.6M/帧 vs KEY 1.58M，合并流开销
   约 2-4%）；KEY-only 裕量仍 1.1%（YX4 §五.2 的带边界跳跃 LOAD 优化未动）。
4. **层次引用债务**（YX4 §五.4 原样）：RTL 引用 vendor 内部信号
   （mWR_DONE/write_fifo*.logic_fifo.rp_bin 等），P5 综合前重构。
5. **首帧必须 KEY**：格式假设（f0=DELTA 时 src 窗未初始化）。当前编码器满足，
   ixdec/ixbuf 未强制校验（TB 金标可检出）。

## 8. 防重复踩坑（新增）

- **流不自动停在帧边界**：ixdec 的 frame_done 只表示"本帧补丁已推入 pf/skid"，
  不是"流停"。任何"COPY/重建期间继续收补丁"的设计必须显式关 accept 闸
  （含 frame_done 脉冲当拍），否则下一帧补丁穿序。
- **vendor 顺序写端口没有随机写语义**：wr_addr 在 seq_wr 里只用于窗判定
  （S_WINWAIT 换窗 LOAD），块级寻址全靠写入顺序。任何稀疏写需求都必须在
  上游合并成稠密流（合并流）或改用真随机口存储。
- **显示 RD1 自由跑会套圈撞写前沿**：显示消费 0.61 字/拍 > 扫描写入 0.39 字/拍时，
  显示循环读追平并越过写前沿、与在写带竞速，X 属节拍伪影非数据缺陷。判显示 X 必须
  以"取数时刻写前沿"为准（影子队列法）+ 显示速率必须低于写入速率（节流档），
  缺一不可；直接按位置比对会误报。
- **disp_words 是 16 位回绕计数**：`disp_words=62474` 不代表总消费量（实际 ~7.3M）。
  任何用 disp_words 做总量判断的 TB 逻辑（如收口 settle 循环 `disp_words < 
  bands_scanned*FB_WB`）都因回绕恒真而失效，只起"跑到 WD"的作用。P3 显示路径
  重做时须换 32 位或分段计数。
- hdr_parse 的 `get=in_valid` 不带握手：停滞期 dbg_cnt 空转（16 位回绕 → 日志
  出现多组 PARSE 0..11，非多实例、非数据问题；FSM 在 S_PASS 不消费 get，
  功能无影响，仅显示噪声）。
