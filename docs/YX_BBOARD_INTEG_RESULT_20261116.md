# B 板体系化验收报告 — P1/P2 SYS 集成（KEY-only 720p×5 帧）

> 会话：YX4（2026-11-16）
> 依赖：`docs\STATUS_YX4.md`（修复过程与根因清单）、`docs\STATUS_YX2.md`（门禁体系）
> 结论：**P1（索引路径真实化）与 P2（头解析/码本装载/KEY-only 码流）的 SYS 集成验收通过**。

---

## 1. 验收对象与判据

对象：`SIM_ABSTRACT=0`（体系模式）下,B 板 SoC 顶层 `yingxu_vq_board_top` 的完整链路：

```
A板字节流 → hdr_parse(头解析/码本装载) → ixdec(解码) → ixbuf(补丁缓冲)
  → yx_b_ix_seq_wr(v3 组协议, WR2 写索引区)
  → yx_b_ix_fetch(v4 每带 LOAD, RD2 读索引区, region_done 屏障)
  → band(渲染, 码本查表, 行缓冲 ping-pong)
  → 扫描写端(v3 FLUSH, WR1 写帧缓冲) → TB 比对(GOLDEN)
  → 显示消费端(RD1 循环流) → TB 比对(结构判据)
```

判据（TB GATE,判据严格强于旧版）：
`dec_frames=5 && frames_done=5 && bands=900 && golden=0 && scan_errs=0 && disp_errs=0 && xz_errs=0 && mem 索引区/帧区非 X 字数>0`

## 2. 验收结果

### 2.1 bboard_key（KEY-only 合成流 720p×5 帧）— **ALL PASS**

| 运行 | 判定 | 日志 |
|---|---|---|
| 含临时探针首跑 | **ALL PASS** | `out\sim\bboard_key_20261116_031511_sim.log` |
| 清理探针后复跑 | **ALL PASS** | `out\sim\bboard_key_20261116_032300_sim.log` |

关键证据（复跑日志）：

```
MEMCHK idx_nonX=115200/115200 fb_nonX=460800/460800 m0=000000e4 m1=000000ef m2=000000fa
GATE dec_frames=5(OK) frames_done=5(OK) bands=900(OK) golden=0(OK) scan=0 disp=0(OK) xz=0(OK) mem=115200/460800(OK)
=== TB-SUMMARY: ALL PASS ===
```

- 索引双缓冲区 115200 字全部非 X；帧缓冲区 460800 字全部非 X。
- `m0/m1/m2=000000e4/ef/fa`（228/239/250）恰为帧 5 的 idx 公式值 `(0×11+4×313)%1024=228` 起——帧缓冲区内容与金标逐帧一致。
- `PUSHSTAT wr2: pushes=288000 X=0 first3_real=00000000,0000000b,00000016`——5 窗 288000 字全部落写、零丢字零 X,首 3 字=金标 (blk×11)%1024 序列。
- 5 帧逐帧 `FRAME #n ... errs=0`；stall2=5%（渲染深度 2 背压,健康）。
- 运行时长 7.91M 拍（WD=8M,裕量 1.1%）。

### 2.2 sdctrl_sanity（vendor 控制器写读回环）— **ALL PASS**

`out\sim\sdctrl_sanity_20261116_033629_sim.log`——控制器 shim 契约未受本轮改动影响。

### 2.3 bboard_sys（真实编码流冒烟）— FAIL（判据不适配,非本轮回归）

`out\sim\bboard_sys_20261116_032951_sim.log`：`dec_frames=5`(解码全通)、`scan_errs=0`(渲染→扫描→mem 链一致)、`golden=1843200`(全错)。

失败构成（均为**已知预期**或**观察点**）：
1. **golden 全错**：金标公式 `idx=(blk×11+frame×313)%1024` 只对 `tb_gen_key_stream` 合成流成立；真实流码本前 8 项=0xFFFF（`BOOK[0..7]=65535×8`，即 `run_sim.ps1` :123-127 注明的已知特性）。
2. **disp 结构判据 512 错**：同因——真实码本像素不满足 `{idx+j+1, idx+j}` 相邻对结构。
3. **速度边缘**：4 帧/720 带（8M 拍内），真实流节奏略慢于合成流。
4. **⚠️ 观察点（下会话排查）**：`MEMCHK idx_nonX=57600/115200`——真实流下索引窗 1 落写区半 X；`m0=0000xxxx`。需区分"真实流帧段特性"与"WR2 窗 1 路径残留问题"。

## 3. 相对交接方案的偏离（重要）

交接文档第五节方案（"每窗推数计数达 NB 后等 900 拍 → 发 region_done 脉冲；取带器 region_ok 门；复位后首窗也发 LOAD"）**意图全部实现,但机制升级**：

| 交接方案 | 实际实现 | 原因 |
|---|---|---|
| 固定 900 拍排空屏障 | 128 字组突发对齐（推满停推+等 mWR_DONE 事件） | 触发阈值(128)<突发(256)+afull(378) 组合下窗尾必有滞留/欠载,固定延时无法根治 |
| region_done 脉冲+region_ok 门 | region_done[1:0] 按窗独立标志（完成置位/重写清除） | 脉冲有"渲染 swap 晚于脉冲"死锁面；单值电平有"窗号滚走"死锁面（均实测复现） |
| 取带器 region_ok 门 | 保留,ok_now=region_done[need_win] | — |
| 首窗也发 LOAD | 保留（S_WAIT0 等首补丁后 LOAD） | — |

此外修复了交接因果链之外的 **4 个既有 RTL 缺陷**：scan_ra/rb 悬空（扫描推数全 X 的真根因之一）、scan_done 超前（TB 比对读 FIFO 尾字 X）、fetch reload 早于 band 接帧（帧间撕裂读）、rRD2_MAX_ADDR 复位锁存（窗 1 死循环读窗头——帧 0 对、帧 1+ 数据源全错的根因）。

## 4. 结论与下一步

- **P1/P2 验收通过**，B 板 KEY-only 体系链路（解码→写索引→取带→渲染→扫描写帧→显示读）数据正确性闭环。
- 旧报告 `YX_BBOARD_INTEG_RESULT_20261110.md` 中"超出证据的表述"（Vivado 成功/bit 生成等）维持审计结论：**无效**，以本报告为准。
- 下一步：**P3 HDMI 扫出+双窗口**（方案已批准）→ P4 以太网 UDP 入口 → P5 TD 综合+STA（待 AC601 引脚表）。
- 遗留项清单见 `docs\STATUS_YX4.md` §五。
