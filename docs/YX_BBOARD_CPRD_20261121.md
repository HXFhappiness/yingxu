# YX_BBOARD_CPRD_20261121 — cp 拷贝读口板级契约闭环（fetch v5 RD2 分时服务）

> 状态：**已闭环**（v5b 双回归 ALL PASS，2026-11-21，见 §7 验收表）。
> 前置：`YX_BBOARD_DELTA_20261121.md`（ixbuf v2 合并流，cp 读口当时仍是
> "仿真=TB 随机口模型"契约位，板上方案挂账 P4/P5 前必须闭环——本文档即清偿记录）。

## 0. ★ 一般性硬件教训（P3/P5 设计评审必读）

**vendor 控制器所有顺序突发口的 LOAD 地址必须 64 字对齐**（突发长度 RD2_LENGTH=64
的倍数，且 64 | 行宽 256）。机理：

- full-page 突发（SC_PM=1）**在行边界内回绕**：起始列 >192 的 64 字突发，
  尾段越过列 255 后回绕到**本行**头，而不是线性进入下一行；
- vendor 地址寄存器按**线性字地址** +LENGTH 步进，假设数据线性连续；
- 二者叠加 ⇒ 未对齐 LOAD 之后每行一次的跨界突发返回**本行头部的内容**
  （地址上的"更早数据"），错误呈周期性、稀疏（均匀区域不可见）——
  YX6 实测：LOAD@57743（mod 64 = 15）→ f4 交付流 1585 字错位、
  igold=1585 / golden=10044。

对齐保证：突发恒不跨行（256 = 4×64）。本工程各口核查：
RD2 band 流（320=5×64，基址 0/57600 均 64 对齐）✓、WR2 组协议（128 对齐）✓、
WR1 扫描（2560=40×64）✓、RD1 显示（FB_BASE=115200 对齐，256 突发）✓、
**cp 流（v5b 起 LOAD 下取整到 64）✓**。

## 1. 问题定义

ixbuf v2 合并流（DELTA 帧重建）需要读**源窗**（上一帧索引窗）逐字数据，
经 `cp_rd/cp_addr/cp_dvld/cp_data` 电平握手口。该口在体系模式下由 TB 的
随机口行为模型供给（WR2 写流镜像进 ixmem → cp 读直读 ixmem）——即数据
路径上最后一个"仿真专用契约位"。板上没有这个模型，必须给出真实实现。

## 2. 关键洞察（改变设计空间）

**cp 读不是随机口，是严格顺序流**：`cp_addr = src_base + cp_i`，cp_i 单调
递增扫全窗（0..NB-1）。唯一的不规则性 = DELTA 补丁命中使 cp_addr **前跳**
1 字/补丁（每帧 ≤5638 次）。因此根本不需要"随机口"，只需要**一条可分时的
顺序读流**——vendor 4port 控制器的 RD2 恰好能承载。

第二个关键事实：**控制器读通道是连续过读的**（调度器见 FIFO 不满即连发
突发，与"谁在读"无关），且 `RD2_LOAD` 语义 = 冻结全部通道调度 + FIFO 清。
这决定了分时协议只能在"FIFO 空 + 无在途突发（RD_MASK[1]=0）"的静默点
切换地址流——fetch v4 的 FLUSH 机制天然提供这种静默点。

## 3. 设计（fetch v5）

### 3.1 服务时机 = fetch 静默窗（band 数据流零扰动）

| 时机 | 状态 | 覆盖场景 |
|---|---|---|
| a) 帧尾空闲 `frame_done_f` | 末带末字交付完、等下一帧 reload | case-b（DELTA 在 READY 宣布，合并与渲染并行）：合并在此全速完成 |
| b) reload-WAIT（hold && !drain && !ok_now） | 等目标窗 region_done | pend-case（DELTA 在非 READY 宣布，SWAP 时才启动 COPY）的**死锁破解点**：此窗若不服务 cp，merge 永不完成 → region_done 永不置位 → WAIT 永等 |

band 交付期间绝不插入 cp pop；KEY 流无 DELTA → cp 逻辑永不激活 →
KEY 路径行为与 v4 逐位一致（bboard_key 基线零扰动）。

### 3.2 流连续性（免重读的核心）

- `cp_pos` 跟踪 FIFO 头字地址（每 pop +1）；
- `cp_addr == cp_pos` → 直接续传（免 LOAD）；
- `cp_addr > cp_pos` → 头部惰性丢弃（pop-discard）追平（补丁跳字）；
- `cp_addr < cp_pos` 或 `cp_pos_v=0`（新 COPY 换窗 / 首次 / 被抢占）→
  静默点重 LOAD（**64 对齐**，见 §3.5）：LOAD 冻结调度 + 弹空在途
  （同 v4 FLUSH 收尾），空且无在途时锁对齐地址 → 释放 → 控制器从该地址
  连续过读。
- merge 停滞期 FIFO 被过读填满 = cp 的后续字，恢复后零重读；
  LOAD 次数 = 每 DELTA 会话 1 次 + 帧尾空闲窗被新帧 SWAP 打断的重入次数。

### 3.3 交付握手（与 TB 模型同款，ixbuf 零改动）

`cp_dvld` 1 拍脉冲、`cp_data` 同拍有效；仅在 `cp_req`（merge 处于 CP_RD
等待）时报价——防 merge 未采样被双消费；报价满 1 拍即撤（merge 必在
CP_RD 内采样）。skid 1 深；merge 经补丁越过 skid 字（防御路径）→ 丢弃重同步。

### 3.4 抢占与退出（v5b）

- reload 到来（swap_done 次拍）→ 抢占 cp 服务，cp 管线复位，进 v4 hold；
  **mid-serve 抢占 → 重入时重 LOAD（对齐地址）**——重 LOAD 次数随抢占时序浮动
  （YX6 实测 3~5 次），故 cploads 只作观测不作门禁；
- **★ WAIT 窗不服务 cp（v5b 删除）**：SWAP(N) 以 merge(N) 完成为前提
  （DRAIN 要求 cp_i==NB），故 reload 的 ok_now 只可能滞后末突发落 SDRAM 的
  ~150 拍，纯轮询即可；实测此窗服务只会产生 1 次无交付 LOAD + 立即 kill。
  （首版设计误判 pend-case 会死锁——实际不可能：merge 卡住的窗就是它自己在
  写的窗，而 WAIT 等的是上一个窗。）

### 3.5 ★ 64 对齐 LOAD（v5b 根因修复，见 §0）

CP_LOAD 完成时把地址与 cp_pos 同步下取整到 64 字边界
（`{cp_addr[16:6], 6'd0}`），首段 ≤63 字走既有 discard 逻辑追平。
band/reload 路径天然对齐（320=5×64），KEY 流无 cp 完全不受影响。

## 4. 顶层/TB 变更

- `yingxu_vq_board_top.v`：REAL_IX 下 ixbuf.cp 口改接 u_ixfetch
  （`.cp_req(cp_rd), .cp_addr(cp_addr)`）；模式 1 保持顶层输入口（TB 模型）。
  cp_rd/cp_addr 两模式均直驱顶层观测口。板上顶层无 cp_dvld/cp_data 随机口。
- `tb_yxvp_bboard.v`：SYS 模式下 TB cp 模型停用（cp_dvld_r 恒 0）；
  ixmem 镜像保留 = igold 镜像参考（DUT 不再读它——数据回路全部真实化：
  WR2 写 → SDRAM → RD2 cp 读 → merge）。
- 新增 CPSTAT 观测（deliv/disc/stale/loads）+ GATE 强化判据：
  `cpdeliv = 3*NBW-6588 = 166212`（f1 D595/f2 D355/f4 D5638 的
  Σ(NB−npatch)，与运行期抢占时序无关的精确契约）；cploads 仅观测。
  `YX_CP_DBG` 条件编译探针（会话迁移 + 全量 DELIV 迹线）+ 
  `tools/sim/check_cp_trace.py`、`probe_f4*.py` 离线对账脚本（排障用）。

## 5. 带宽/节奏核算（YX6 实测校准）

- cp 每 DELTA 帧交付 57600−npatch 字，实测合并服务 ≈ **46 万拍/帧**
  （交付+写入合计 0.125 字/拍——merge 的 CP_RD→CP_GNT→CP_DEC 握手循环
  为瓶颈），落在帧尾空闲窗 → DELTA 帧周期 1.36M → 1.82M（**+34%**）；
- KEY 帧零开销；5 帧真实流总时长 +1.38M 拍（+20%）；100MHz 下每帧预算
  41.7ms，24fps 内容余量充足；
- 读带宽：cp ~0.125 字/拍，与 RD1（显示 0.249 字/拍节流）/WR2 并行，
  控制器 rd1_turn 轮转 + afull 门公平调度；
- 首版估算（~4 拍/字、+16%）偏乐观，以本节实测为准。

## 6. 排障实录（YX6，数字破案过程存档）

1. **v5 首跑**：key ALL PASS（cp 路径惰性 ✓）；sys FAIL——golden=10044、
   igold=1585，但 CPSTAT 精确（deliv=166212、disc=6588、stale=0）。
2. **分帧分布**：f0-f3 窗零错误，仅 f4 窗 1585 错（i≥512）→ 帧缓冲 f4 渲染
   10044 错——损坏只在最后一个 DELTA。
3. **DELIV 全量迹线对账**（`check_cp_trace.py`）：会话交付计数全部精确、
   地址单调无回退，但 S5 会话（重入，LOAD@57743）的交付值与 win3 失配。
4. **首错定位**：S5 交付 #0-176（窗位置 143..319）正确，从窗位置 512 起
   失配，got=0045（= 窗内更早位置的值）。
5. **根因**：LOAD@57743 非 64 对齐 → 行跨界突发回绕（见 §0）。所有对齐
   会话（@0/@57600）全部正确，BAND 路径 320=5×64 天对齐从未踩雷——
   与全部观测数字闭合（1585 = 均匀区域掩盖后的可见子集）。
6. **修复**：CP_LOAD 64 对齐（§3.5）+ 删 WAIT 窗服务（§3.4）。
   GATE 判据校准：cpdeliv 精确保留；cploads 降为观测（依赖抢占时序）。

## 7. 验收（YX6 实测回填，全部 PASS）

| 项 | 期望 | 实测 |
|---|---|---|
| bboard_key（KEY-only，v5b 全链） | ALL PASS，KEY 路径零扰动 | **PASS**（`bboard_key_20261121_214947`，GATE 十二项全 OK，psc=288000/ldc=5/MEMCHK 与基线一致，cp 逻辑休眠） |
| bboard_sys（真实流含 DELTA） | ALL PASS 全项 | **PASS**（`bboard_sys_20261121_220642`）：golden=0、igold=0、cperr=0、scan/disp/xz=0、hdrerr=0、cpdeliv=166212 精确 |
| 分帧索引窗错误 | 全零 | IGERR-DIST f0..f4 = **0/0/0/0/0**（修复前 f4=1585） |
| 分帧帧缓冲错误 | 全零 | GERR-DIST f0..f4 = **0/0/0/0/0**（修复前 f4=10044） |
| cp 交付计数 | 3×NBW−6588 = 166212 | **166212 精确**；disc=6603 = 6588 补丁跳字 + 15 对齐首段（57743−57728）；stale=0 |
| 重 LOAD 次数 | 观测值 | 4（每 DELTA 1 次 + f4 mid-serve 抢占重入 1 次；WAIT 空会话已删除） |

**节拍实测**：DELTA 帧尾合并服务 ≈ 46 万拍/帧（0.125 字/拍交付+写入），帧周期
1.36M → 1.82M（+34%/DELTA 帧，KEY 帧不受影响）；5 帧总时长 +1.38M 拍（+20%）。
100MHz 下每帧预算 41.7ms，24fps 内容余量充足。若后续需要提速，优化路径 =
2 深 skid + 提前 pop（§7 遗留优化）。

**附**：hdr_parse 首帧 KEY 强制校验同步落地（f0_chk + TB phe 门禁，本表
hdrerr=0 即其收口）；run_sim key 入口 WD 8M→12M（YX4 §五.2 裕量债销账，
FRAME#5 = 7.914M 实测，对齐修复后裕量与基线一致）。

## 7. P4/P5 影响（债销账说明）

- P4（以太网入口）：无需为 cp 口预留任何板级机制——索引路径上已无
  "TB 模型契约位"，全链路仿真可直接叠加；
- P5（TD 综合）：顶层 cp_dvld/cp_data/band_rd_* 输入口在 SIM_ABSTRACT=0
  下悬空（综合为无驱动输入），TD 顶层可整体删除这些端口；
  fetch v5 新增的 cp_* 端口为内部连接，无引脚；
- 遗留优化空间（不阻塞）：cp 交付 ~4 拍/字受 merge 握手循环限制，
  若实测帧周期超预算，可做 2 深 skid + 提前 pop（预计降到 ~3 拍/字）。
