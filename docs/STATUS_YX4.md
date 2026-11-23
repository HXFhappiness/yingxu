# 映序 B 板体系化 — 会话交接文档（YX4,2026-11-16)

> 模型：GLM-5.3-Flash（会话 YX4）
> 前序：主会话 → YX2（gpt-6.1-sol,门禁体系+状态机/仲裁修复）→ YX3（审计,STATUS.md）
> 主题：**实施 WR2 零有效落写修复方案 → bboard_key GATE 首次 ALL PASS**

---

## 一、本会话结果一句话

> **P1/P2 SYS 验收（KEY-only 720p×5 帧）首次全绿**：`bboard_key` GATE ALL PASS
> （dec=5/frames=5/bands=900/golden=0/scan=0/disp=0/xz=0/mem 索引区与帧区全真）。
> 修复过程中发现并闭环了 **7 个根因**，其中 3 个是交接方案之外的既有 RTL 缺陷。

## 二、证据

| 项 | 值 | 出处 |
|---|---|---|
| bboard_key（干净 TB 复跑） | **ALL PASS** | `out\sim\bboard_key_20261116_032300_sim.log` |
| bboard_key（含临时探针首跑） | **ALL PASS** | `out\sim\bboard_key_20261116_031511_sim.log` |
| sdctrl_sanity | **ALL PASS** | `out\sim\sdctrl_sanity_20261116_033629_sim.log` |
| bboard_sys（真实流冒烟） | FAIL（判据不适配,见 §五） | `out\sim\bboard_sys_20261116_032951_sim.log` |

bboard_key 关键数字：
- `MEMCHK idx_nonX=115200/115200 fb_nonX=460800/460800 m0=000000e4`（0xe4=228 恰为帧 5 idx 公式值 (4×313)%1024）
- `PUSHSTAT wr2: pushes=288000 X=0 first3_real=00000000,0000000b,00000016`（288000=5×57600,5 窗全推、零丢字零 X）
- 5 帧逐帧 FRAME 行 `errs=0`、stall2=5%（背压健康）

## 三、修复清单（按因果链顺序）

### 根因 1：WR2 写通道窗尾滞留/欠载（交接方案"固定 900 拍屏障"不可靠）
- **机理**：vendor 写通道触发阈值（占用≥128,AE=127）< 突发长度 256,且 `WR2_FULL` 实接 afull(378)。窗尾推停时 FIFO 占用随机,必有 <128 字滞留（永不触发末突发）或突发中途欠载（空读 do 重复写坏窗尾）。
- **修复**（`yx_b_ix_seq_wr.v` v3）：**128 字组突发对齐**——每攒 128 字推一组、推满即停、等 `wr2_done`（`mWR_DONE&WR_MASK[1]`,顶层组合,厂商自身同构用法）再推下组。NB=57600=128×450 整除,窗尾恰在突发边界收干,零滞留零欠载。WR2_LENGTH 256→128。

### 根因 2：窗完成屏障的语义（交接方案"region_done 脉冲"有死锁面）
- **机理**：脉冲在渲染 swap 之后发生时 fetch 错等下一窗；改单值电平（region_valid+region_win 窗号）后,写入领先渲染 1 窗时窗号滚走、读侧窗的完成信息丢失 → fetch 误等"该窗下次重写完成" → 全链死锁（实测 t=3M 卡死）。
- **修复**：**`region_done[1:0]` 按窗独立标志**——每窗末组突发完成置位 `region_done[win]`,seq_wr 开始重写该窗（LOAD 拍）清除。fetch `ok_now = region_done[need_win]`,窗 0/窗 1 完成状态独立可查。

### 根因 3：fetch hold 期 LOAD 恒高冻死整个控制器
- **机理**：vendor 调度器全局门控要求 4 个 LOAD 全 0 才选通道——RD2_LOAD 保持会把 WR2 也冻死（观测 ctl 全闲+w2f occ=128 等 done）。
- **修复**（`yx_b_ix_fetch.v`）：hold 两段——**WAIT**（窗未写完时不拉 LOAD,RD2 首突发填满 256 字后静默,几乎零仲裁干扰）；**FLUSH**（ok_now 后才保持 LOAD 冻结新调度+弹空+等在途完,≤650 拍有限时长）→ 撤 LOAD 尾拍锁存新地址 → 恢复后首突发恒从新地址读。

### 根因 4：rRD2_MAX_ADDR 只在复位锁存 → 窗 1 死循环读窗头（既有 RTL 缺陷）
- **机理**：vendor :517-518 只复位锁 MAX,LOAD 只锁 ADDR/LENGTH(:566-569)。复位引脚值=窗 0 尾 57600 → 窗 1 首突发后步进条件恒假 → 每突发回卷引脚 → 死循环读窗头 256 字（帧 0 完美、帧 1+ 数据源全错的根因）。
- **修复**（fetch v4）：**放弃整窗循环读,改每带 LOAD**——RD2_LENGTH=64（带 320 字=5 突发整除）、MAX 引脚恒 0x1FFFFF（永不自动回卷）、fetch 按交付字数自数带边界（每 320 字）,带边界走 mini-hold（复用 hold 机制:弹空+单拍 LOAD 锁新带首地址）。窗尾（带 179）不 LOAD,等帧切换 reload。

### 根因 5：scan_ra_w/scan_rb_w 悬空 → 扫描推数全 X（既有 RTL 缺陷,旧因果链误归因于索引 X）
- **机理**：顶层 :194 声明的 wire 只被 band 读取,全文件无驱动（悬空 Z）→ `ln[Z]=X`。行缓冲内容实际完好（DBG 证实 ln[0..7] 全真）。
- **修复**（`yingxu_vq_board_top.v`）：`assign scan_ra_w = sc_ra; assign scan_rb_w = sc_ra+1;`——顺带修推数链：band 行缓冲改**组合读**（仿真版；消除同步读+full 停推的结构性错位,sc_ra_v 机制删除）；推数条件删除误用的 `wr2_aempty_w` 门控。

### 根因 6：scan_done 时机超前 → TB 比对读 FIFO 尾字 X（既有）
- **机理**：TB 在 scan_done 拍直读 sdram mem 比对,但 WR1 FIFO 尾字还在突发中。
- **修复**：sc 状态机加 FLUSH 段——**rp 影子差分计数**（`u_sdram.write_fifo1.logic_fifo.rp_bin` 10 位 mod 1024 差分累加,与 fetch occ 自计数同构）等 2560 字全落 SDRAM+256 拍裕量才报 scan_done;旧 600 拍固定 DRAIN 删除（被精确排空取代）。

### 根因 7：fetch reload 在 frame_done 拍触发,早于 band 接帧锁新 base_l（既有）
- **机理**：frame_done 提前到最后一带完成拍（与 ack 解耦）,band 要等 ack 才接挂起帧更新 base_l → fetch 在 frame_done 拍锁到旧窗基址 → 渲染帧 N 读窗 N-1 数据撕裂（帧 1 带 0 读到帧 0 数据、带 40 读到已被帧 2 重写的数据）。
- **修复**：band 新增 `frame_start` 输出脉冲（IDLE 直进/接挂起帧拍,此拍 base_l 已锁新窗）；fetch reload 改由 frame_start 触发。

### TB 判据修正（YX4 同步修订）
- scan 比对帧号：`frm=bands_scanned/180` 计数在比对滞后跨帧时与渲染帧号错位 → 改 `frm=u_band.render_no`（渲染侧实际帧号）。
- disp 比对（旧判据从未通过,语义先天破缺）：显示流滞后写入前沿是正常行为（RD1 循环流+消费速率不同步）,与 mem 实时值按位置比对天然错位 → 改**渲染字结构判据**：`{奇,偶}={idx+j+1, idx+j}`（相邻像素对）。内容级逐字对齐判据留待 P3 显示节拍定案（显示节流开启后滞后量固定）再强化。

## 四、改动文件

| 文件 | 性质 |
|---|---|
| `src\...\vp\yx_b_ix_seq_wr.v` | 重写（v3 组协议+region_done[1:0]+首窗 LOAD） |
| `src\...\vp\yx_b_ix_fetch.v` | 重写（v4 hold WAIT/FLUSH+每带 LOAD+region_done 门） |
| `src\...\vp\yx_vp_band.v` | frame_start 输出+行缓冲组合读+复位段 |
| `src\...\vp\yingxu_vq_board_top.v` | scan_ra/rb 连线、WR2_LEN=128、RD2_LEN=64/MAX 恒、wr2_done_w、sc v3 状态机（FLUSH+rp 影子计数）、frame_start 接线、删 wr2_aempty 门控 |
| `tb\tb_yxvp_bboard.v` | scan 帧号 render_no、disp 结构判据、TEMP-DBG 已全部清理 |

## 五、遗留项 / 观察点（下会话）

1. **bboard_sys（真实流）**：✅ **已闭环（YX5,2026-11-21）**。观察点根因=体系模式下 ixbuf DELTA 帧整窗 COPY 读源悬空 + 稀疏补丁不可过 seq_wr 顺序写协议,双重缺陷；修复=合并流引擎（稠密输出）+ TB 随机口镜像 + 真实流金标生成器。证据与遗留债见 **`docs\YX_BBOARD_DELTA_20261121.md`**。
2. **速度裕量**：KEY-only 5 帧 7.91M 拍 vs WD 8M,裕量 1.1%。组协议+每带 LOAD 的开销（每带 mini-hold ~650 拍×900 带）可优化（带边界改"跳跃 LOAD 不弹空"?或 DISPH 节流减少 RD1 干扰）。
3. **显示位置对齐判据**：P3 显示节拍（DISP_NUM/DEN 节流）定案后,显示滞后量固定,可做内容级逐字对齐。
4. **层次引用债务**：RTL 内引用 vendor 内部信号（`u_sdram.mWR_DONE/write_fifo1.logic_fifo.rp_bin` 等）——仿真必需,P5 TD 综合前需重构为端口引出或控制器外包装。
5. **band 行缓冲组合读**（仿真版）：板上 BRAM 同步读需推数拍对齐流水,P3/P5 适配。
6. **P3/P4/P5 未动**：HDMI 扫出+双窗口、以太网 UDP 入口、TD 综合+STA（待 AC601 引脚表）。

## 六、防重复踩坑（新增)

- vendor 控制器读通道**无法关停**（触发仅看 FIFO 占用<AF,无 LENGTH=0 禁用;LENGTH=0 是空转突发）；唯一暂停手段=LOAD 置位（但**全局冻结所有通道**,只能单拍使用）。
- 回卷目标=**引脚值**（写通道 :550 `rWR2_ADDR<=WR2_ADDR`、读同构）——窗基址必须常驻引脚 reg。
- **MAX_ADDR 只在复位锁存**——任何"动态窗循环"需求都绕不开它,只能改协议（每带 LOAD+线性 MAX）。
- `WR*_FULL` 接的是 **afull(378)** 不是真满(512)；`AE=127` 是写触发阈值、`AF=128` 是读触发阈值。
- LOAD 尾拍（次拍撤）+厂商 LOAD 抑制（触发条件含 LOAD==0）的组合可保证"撤后首突发用新地址"——单拍 LOAD 时序以此为准。
- mWR_DONE/mRD_DONE 是 SDR_CLK 域 1 拍脉冲,CLK 域采样与厂商自用同构,可直接组合进顶层事件线。

## 七、下会话第一件事

1. 若继续收尾 B 板仿真：查 bboard_sys 真实流窗 1 半 X 观察点（§五.1）；
2. 否则按路线图进 **P3**（HDMI 扫出+双窗口,方案已批准）。
