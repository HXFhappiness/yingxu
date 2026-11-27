# P6 — 板 A → 板 B VQ 码流端到端（yx_a_vq_sender + p6_e2e）

日期：2026-11-27 / 版本：0.17.0 / 分支：main（起点 472c5c7）
状态：**判据 1 通过；判据 2 全量跑分见 §6；判据 3 见 §5**

---

## 1. 交付物

| # | 交付物 | 文件 |
|---|---|---|
| 1 | A 侧发送器：字节流 → 1472B 分片 UDP → GMII | `src/user_source/hdl_source/media/vp/yx_a_vq_sender.v` |
| 2 | 开环节流器（帧锁存、按帧类型分周期） | 同上（常数与依据写在文件头） |
| 3 | 目的地址与 B 默认过滤一致 | `DST_MAC=00:0a:35:02:00:01` / `192.168.0.100` / `5000` |
| 4 | 独立仿真入口 `p6_e2e`（A 发送器 + B 接收器 GMII 直连） | `tools/sim/run_sim.ps1` + `tb/tb_yxvp_bboard.v`（`ifdef P6_E2E`） |
| — | A 侧单测 | `tb/tb_a_sender.v` |

---

## 2. 四个真 bug（全部是端到端才暴露的，不是测试放宽）

### 2.1 `ip_checksum` 采样点错 → **首包被丢**
P5 把 9 个操作数分级打拍，`suma` 在 `cal_en` 拍取 `p1_r + p2_r + dst_ip[15:0]`：
`p1_r/p2_r` 是**2 拍前**的值，`dst_ip` 是**当拍**值 —— 混了两个时间点。

- 实测：A 发的第 1 个包 IP 校验和线上 `0xF91A`，该头（`total_len=0x05DC`）正确值是 `0xF35A`。
- 反解：`0xF91A` 对应的 `total_len` 恰为 `0x001C=28`，即 `data_length` 被当成 0
  （`yx_a_vq_sender` 在 T+1 才置 `frag_bytes`，`tx_en_pulse` 在 T+2 到）。
- 后果：**只有首个包**被 `eth_udp_rx_gmii` 按坏 IP 头丢弃，而首片 1472B = YXV2 头 + 码本开头
  → B 的 `hdr_parse` 从码本中间解析 → `hdr_err=1`、`commit` 恒 `0xFFFF`、一帧不解。
- 修法：全部 9 个操作数在 `cal_en` 当拍采样，用**平衡加法树**保时序（深度 4 = 9 操作数最优；
  原线性链 7 级 8.229ns）。latency 不变，RX 侧采样余量不受影响。
- 验证：修后 `WIRE[32:33] = f3 5a`、首包 `pv=1`、`FEED[1..8]` = `59 58 56 32 02 04 00 00`。

### 2.2 `tx_en_pulse` 丢在包间隔里 → **发送器死锁**
`eth_udp_tx_gmii` 只在 `curr_state==IDLE` 接受 `tx_en_pulse`（其 :462），而 `tx_done` 在
`TX_CRC/cnt_crc==3` 就置位，之后核还要走 **64 拍包间隔**才回 IDLE。FSM 在 `tx_done` 后 2 拍就发
下一包 → 脉冲落进间隔被丢弃 → 永卡 `S_FEED` 等 `payload_req`（实测：序幕 23 包发完后
`st=2 / fcnt=2048 / preq=0` 静止）。旧版每包间隔 2.9 万拍从未撞上，FIFO 满后背靠背必撞。
- 修法：加 `S_GAP`，`tx_done` 后等 70 拍（≥64 + 余量）再回 `S_IDLE`。

### 2.3 flush 等待期未冻结节拍器 → **又一个死锁 + 字节数守恒被破坏**
窗口末残余片在等 `S_IDLE` 时，若 Bresenham 继续走 `acc`，每拍消费一个 tick 却没有对应 push，
窗口收尾 `win_last` 永远凑不齐；且被门控掉的字节配额白烧 → 字节数会少于 `win_total`。
- 修法：`paced && !flush_req` 才走节拍器，冻结期 `acc` 保持不动。
- 配套：`flush_req` 单驱动、「置优先于清」、`S_IDLE` 见到即消费。否则残余为 0 的窗口会把
  `flush_req` 带进下一帧，`S_IDLE` 一见 FIFO 非空就把刚到的几个字节当"残余"打成小包。

### 2.4 TB 源驱动错位一格（**测试代码 bug，非设计**）
`a_src_data_r <= smem[a_sp]` 与 `a_sp <= a_sp+1` 同拍 NBA → 握手拍 DUT 采到的是**上一个**字节
→ 序幕整体错位 → `cb` 读成 0 → `win_total=0` → 卡死 `PS_PRO`（实测 `ps=1 win=0/0 byte=20`）。
- 修法：握手拍**预取** `smem[a_sp+1]`（`tb_a_sender` 与 `tb_yxvp_bboard` 两处同修）。
- 教训：DUT 的 `src_data` 是当拍组合取用（与厂商核 FWFT 语义一致），TB 必须同拍给出。

### 2.5 工具链：`always @(*)` 组合读大数组 → **iverilog 编译期死循环**
`tb_a_sender` 里 `always @(*)` 读 1M 条目 `smem[sp]` → `ivl` 编译期自旋（高 CPU、内存
60~90MB 不涨，累计烧掉 2.1 核·小时）。改为寄存预取驱动后编译 **0.12~0.22 秒**。
- `run_sim.ps1` 编译门禁补 180s 超时 + `taskkill /T /F`，超时判 `COMPILE-TIMEOUT`。
- 另修：`Start-Process` 后必须立刻取 `$p.Handle` 强制打开句柄，否则秒退的编译读不到
  `ExitCode`（返回 null → 误判 COMPILE-FAIL；实测 vvp 已产出却报编译失败）。

---

## 3. 开环节流器：为什么必须"帧锁存"，且 KEY/DELTA 要分周期

### 3.1 常数速率方案被两轮实测否定
| 方案 | 实测结果 |
|---|---|
| `BYTE_DIV=20`（6.25 MB/s，依据 P5 §5F 的 6.81 MB/s） | t≈2.5M 起 `drop` 0→85，`room` 8192→39 |
| `BYTE_DIV=42`（2.98 MB/s，已低于源码率） | t≈5.5M 起仍 `drop` |

两轮的解码质量本身都是好的（`FRAME errs=0`）——**不是解码错，是发送超发**。

根因：P5 §5F 的 6.81 MB/s 是 **VQ-1024 那一条流自己的源码率**
（114,917 B ÷ 16.87 ms），不是可外推的"B 能力常数"。B 的消费是**帧锁存**的：
每个帧周期只消费一帧的负载字节。8KB FIFO 吸收不了"DELTA 帧期间 B 只要 8KB、
而 A 还在按 3 MB/s 灌 41KB"这种帧内供需失配。

### 3.2 帧锁存 + 按帧类型分周期
A 解析 YXV2 结构，把**每一窗自己的字节数**均匀摊到该窗的周期里（Bresenham）：

| 窗口 | 字节数 | 周期 | 速率 |
|---|---|---|---|
| 序幕（20B 头 + 1024×32B 码本） | 32,788 | `PRO_CYC` = 1.0M clk125（8 ms） | 4.10 MB/s |
| KEY 帧体 | 115,200 | `T_KEY_CYC` = 12M clk125（96 ms） | **1.20 MB/s** |
| DELTA 帧体 | 8,390 ~ 18,476 | `T_DELTA_CYC` = 2.75M clk125（22 ms） | 0.38~0.84 MB/s |

帧长公式（权威定义见 `tools/sim/gen_golden.py`）：
`KEY = 5 + NB×2`；`DELTA = 5 + MB + changed×2`，`NB=(W/4)×(H/4)`、`MB=ceil(NB/8)`。

**为什么 KEY 要单独放慢**：见 §4 的死窗实测。DELTA 帧边界实测无死窗（B 逐拍跟踪 A，
缺口 ≤1,455），故维持 22 ms。

---

## 4. B 端消费能力：实测依据（**这是本节的核心，不要再用"6.81 MB/s"这个数**）

数据来源：`out/sim/p6_e2e_run1.log`（BYTE_DIV=20）与 `p6_e2e_run5.log`（统一 22 ms 帧锁存）
的 POLLETH 缺口曲线（`a_tx_byte` vs `eth_byte_cnt` 每 250k clk100 采样）。

### 4.1 无渲染争用时：≥ 6.26 MB/s
run1 t≤2.5M（序幕 + 第一个 KEY 帧，此时显示还没接上、无渲染争用）：
A 供 0.0625 B/clk100，B 连续 2M clk100 保持 `room=8192`（FIFO 全空），
即 **B 完全跟得上 6.25 MB/s** → 能力下界 6.26 MB/s。

### 4.2 稳态 KEY 帧起点：**~2.5 ms 消费死窗**
run5，KEY3（第二个 KEY 帧）起点：

| t (clk100) | A 累计 | B 消费 | 该窗消费速率 |
|---|---|---|---|
| 7.50M | 164,190 | 163,748 | — |
| 7.75M | 175,291 | 164,095 | **+347 B / 250k ≈ 0** |
| 8.00M | 187,856 | 170,755 | 0.0266 B/clk100 |
| 8.25M | 200,420 | 182,019 | 0.0451 |
| 8.50M | 212,985 | 199,171 | **0.0686（6.9 MB/s，追喝）** |

→ **前 2.5 ms B 消费 ≈ 0**，随后以 0.045~0.069 B/clk100（4.5~6.9 MB/s）追喝，
缺口稳定（不再增长）。丢包正好发生在死窗内：A 按 5.24 MB/s 推，2.5 ms 压 10.7 KB > 余量 → 丢 8 包。

**成因**：KEY 帧要写 57,600 个索引字，`ixwr` 的 SDRAM 写带宽被 `band` 渲染 / `scanout` 读占用
→ 写 FIFO 满 → `ixdec` 的 skid 满 → `stream_ready=0`。
KEY0（第一个 KEY）没有死窗，是因为当时还没有渲染争用——**不代表稳态**。

### 4.3 丢包阈值（实测）
run5：deficit（`a_tx_byte − eth_byte_cnt`）涨到 **≈11,000 B** 时开始丢包
（= B 的 8,192 B FIFO + A 侧分片 FIFO/在途 ≈ 2,800 B）。

### 4.4 KEY 速率上限推导
```
死窗实测 ≈2.5 ms（B 消费≈0），取 2 倍安全系数 → 按 5 ms 设计
死窗内 A 的累积 ≤ 丢包阈值 11,000 B
  ⇒ KEY 速率 ≤ 11,000 / 5 ms = 2.2 MB/s（2× 死窗）
  按实测 2.5 ms 计：≤ 4.4 MB/s
取 1.20 MB/s（= 115,200 B / 96 ms）：
  4 ms 死窗压 4.8 KB（余量 2.3×）；5 ms 压 6.0 KB（余量 1.8×）—— 留足冗余
```
**结论：B 的能力不是单一常数，而是「稳态 ≥5.2 MB/s + 每个 KEY 帧起点 ~2.5 ms 死窗」。**

---

## 5. 速率账（判据 3）

| 项 | 数值 |
|---|---|
| 源文件 | 297,989 B / 5 帧（平均 59,597.8 B/帧） |
| 真实帧分布 | KEY 115,205 / DELTA 8,395 / 7,915 / KEY 115,205 / DELTA 18,481 |
| 一次性前导 | 头 20 B + 码本 32,768 B = 32,788 B |
| A 侧发送总时长（设计） | 8 + 96×2 + 22×3 = **266 ms**（clk100 26.6M） |
| A 侧发送总时长（实测） | **279 ms**（clk100 27.9M，含每包串行开销；第 5 帧解码完成于 27,885,205） |
| A 侧平均速率 | 297,989 B / 279 ms = **1.07 MB/s** |
| 分片数 | **206**（= Σ ceil(窗口/1472)；6 个残余片 404/389/1035/555/389/817 B，均 ≥18） |
| 总线字节 | 297,989 + 206×42 = 306,641 B（42 = 14 以太 + 20 IP + 8 UDP + 4 FCS） |
| 占 GMII 线速 | 306,641 B / 279 ms = 1.10 MB/s = **0.9%** |
| B 侧丢包 | **0**（`drop=0`，`bytes=297,989` = `slen`） |
| 余量 vs 死窗约束 | KEY 1.20 MB/s ≤ 2.2 MB/s（2× 死窗口径）→ **1.8× 设计余量**；实测峰值缺口 3,819 B vs 阈值 11,000 B → **2.9× 实测余量** |

**与目标帧率的差距（必须写明）**：本方案 KEY 帧 96 ms（≈10 fps）、DELTA 22 ms，
端到端等效远低于实时。这是**有意的保守**（"宁可比目标慢，不可超发"：B 端丢一个包
就整段码流断裂且无重传）。要跑 60fps 无损，必须解决 §7 的结构限制。

---

## 6. 验收状态

| 判据 | 项 | 结果 |
|---|---|---|
| 1 | A 侧单测：payload 与源 `.yxv2` 逐字节一致 | **PASS**（`tb_a_sender`：slen=297,989 重组=297,989，报文 206，短片 6，帧 5，`GATE checks=9 errs=0`） |
| 2 | `p6_e2e`：`ax_errs=0` / `scan_errs=0` / `frames=5` / GATE 全项 OK | **PASS**（见下方 GATE 原文） |
| 3 | 速率账 + 丢包=0 | **PASS**（`drop=0`，收 297,989 B = 源长度；余量账见 §4.4/§5） |

### 6.1 GATE 原文（全量跑分）
```
GATE dec_frames=5(want 5: OK) frames_done=5(want 5: OK) bands=900(want 900: OK)
     golden=0(want 0: OK) scan=0(want 0: OK) xz=0(want 0: OK)
     mem=115200/921600(want >0: OK) igold=0(want 0: OK) cperr=0(want 0: OK)
     cpdeliv=166212(want 166212: OK) cploads=3 hdrerr=0(want 0: OK)
     axerr=0(want 0: OK) axlines=10346(want >=720: OK) mutex=0(want 0: OK)
     dstall=6950(want 0: OK)
GATE-WR1 eq_errs=0(want 0: OK)
GATE-ETH ok=206(want 206=A.pkt: OK) drop=0(want 0: OK)
         bytes=297989(want 297989: OK) a_bytes=297989
=== TB-SUMMARY: ALL PASS ===
CNT: frames=5 bands=900 scan_errs=0 ax_errs=0 ax_beats=13242976 ax_lines=10346
```

### 6.2 5 帧解码时刻（每帧 `errs=0`）
| 帧 | t (clk100) | bands |
|---|---|---|
| #1 | 11,407,757 | 179 |
| #2 | 14,043,574 | 358 |
| #3 | 16,203,751 | 538 |
| #4 | 25,516,527 | 718 |
| #5 | 27,885,205 | 898 |

### 6.3 关键中间判据
| 项 | 结果 |
|---|---|
| B 收到的前 32,788 字节（头+码本）与文件逐字节比 | **零错**（`BYTECMP prologue 32788B mismatch=0 OK`） |
| A 侧送出的前 40 字节 vs Python 读文件 | **逐字节一致** |
| 短包位置 | 只在窗口末尾（首个 `idx=22 len=404`，`ps=3` = 序幕末片），**不是首包** |
| KEY3 起步死窗（上一轮丢包点） | 缺口峰值 **3,819 B** ≪ 丢包阈值 11,000 B（**余量 2.9×**），`drop=0` |
| `hdr_parse` | `hdrerr=0` |
| 既有入口回归 | `eth_rx` PASS、`eth_stress` PASS、`mdio` PASS、`phy_init` PASS、`bboard_sys_eth` PASS、`bboard_key` PASS |

### 6.4 官方入口复跑（`run_sim.ps1 -Entry p6_e2e`）
```
VERDICT: p6_e2e PASS exit=0 summary="=== TB-SUMMARY: ALL PASS ==="
GATE dec_frames=5 OK frames_done=5 OK bands=900 OK scan=0 OK xz=0 OK
     hdrerr=0 OK axerr=0 OK axlines=6891 OK mutex=0 OK cpdeliv=166212 OK
GATE-WR1 eq_errs=0 OK
GATE-ETH ok=206(=A.pkt) OK drop=0 OK bytes=297989(=slen) OK
stall2=36,923/27,924,959 (0%)
```
与手跑的 p6_final 逐拍一致（t=16.0M 时 `win=12,700/115,200`、`byte=177,008` 完全相同），
确定性复现。修 `a_src_done` 后仿真在 27.9M 正常收尾（此前空转到 36M WD）。

---

## 7. 结构限制与后续（P7 建议）

**根因不在 A 侧**：B 的入口 FIFO 只有 8 KB（`FIFO_AW=13`），而 KEY 帧起步有 ~2.5 ms 消费死窗。
开环 UDP 在"8 KB FIFO + 无回传通道"下，任何有用速率都会在死窗内溢出。三选一才能跑实时：

1. **B 侧 FIFO 至少 64 KB**（8 KB × 2.5 ms × 5 MB/s ≈ 12 KB，取 64 KB 有余量）；
2. **A→B 增加反压/信用通道**（当前 B 板没有 TX 引脚与 125M TX 时钟，硬件需改板）；
3. **接受丢包 + 应用层重传**（需 B 侧能认出丢包并请求，仍要回传通道）。

在本轮约束（不动 B 板 RTL、A 板无回传）下，已选"开环 + 保守慢速"，正确性优先。
