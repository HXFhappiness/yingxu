# YX_BBOARD_P3_DISPLAY_20261121 — 板 B HDMI 扫出 + 双窗口显示 方案文档（P3 前置）

> 状态：方案文档（P3 实现的仓库依据）。YX1/YX5 会话口头批准的 P3 方向自此落盘。
> 依据：本文件所有"现状"均为 2026-11-21 仓库实读（YX6 收官后代码）。
> 实现跟进：P3 完成后在本文件 §10 回填验收表。

## 1. 目标与范围

把板 B 的显示链从"TB 节拍器"（逐字 token bucket + RD1 循环流）升级为**真实 HDMI
扫出**：720p59.3（1650×750 @73.33M 像素时钟）+ **双帧窗防撕裂**，为 P4（以太网
入口）后的"成体系板卡"完成出口侧。

范围内：yx_b_scanout.v（新）、顶层显示侧改造、双帧窗地址规划、TB 判据改版、
TD 侧 generate 门控。
范围外：以太网入口（P4）、精灵引擎合流（P6 候选）、1080p 显示档（后续迭代）。

## 2. 输入依据（已批准决策 + 仓库参考件）

已批准（YX4/YX5 会话，用户确认）：
1. 显示 = **720p59.3 双窗口**（A 板现成 PLL 73.33M/366.67M；2×460800 字装得下）；
2. 加密 HDMI 核不可仿真（iverilog）→ 仿真边界 = AXI-Stream，核与 lane_lvds 只进
   TD 构建（generate 门控）；
3. 音频 mute（valid=0）、DDC 触发置 0（观察项）。

仓库参考件（本日实读）：
- `src\user_source\hdl_source\video_source_test.v`——720p 时序计数器 + AXIS 生成：
  自由跑 x/y 计数（1650×750），`valid=active`、`user=帧首 (0,0)`、
  `last=活跃行末`、`data=I_fb_rgb`；两拍流水；**ready 仅 informational**（核必须
  全收）。→ P3 直接复用该模块（参数同款），不改文件。
- `src\user_source\hdl_source\yingxu_sdram_video_player.v`——A 板 SDRAM→像素取数核：
  1 字 = 2 像素（[31:16] 左 / [15:0] 右），**每个奇数 x 消费 1 字**；
  **vblank（x=0,y=VACTIVE）发 8 拍 LOAD 重置读指针 + 预取首字**（每帧天然对齐
  窗头）；RGB565→RGB888 扩展（r8={pix[15:11],pix[15:13]} 等）；
  教训注释：①逐行重定址已被否（行消隐期无法补数，HDMI 失锁）；②取数永不跳位
  （FIFO 空时保持上一 pair，不可采垃圾）。
- `design_top_wrapper.v`——A 板加密核例化参数（1650/1280/40/110/220、750/720/5/5/20、
  VIDEO_VIC=69、VIDEO_TPG=Disable、VIDEO_FORMAT=RGB、AUDIO_SAMPLE_RATE="48K"）。
- `hdmi_1_4b_transmitter_core_wrapper.enc.v`——AXIS 视频 slave（user/valid/last/
  data[23:0] + ready）、audio valid+L/R、ACR cts/n、EDID trig、O_video_locked、
  4×10bit TMDS 输出。
- `hdmi_phy_warpper.v`——4 对 TMDS 差分输出（I_tmds_channel_0..3）。

## 3. 地址规划（720p，全部 64 对齐——YX6 §0 硬约束）

| 区域 | 字地址范围 | 字数 |
|---|---|---|
| 索引窗 0（现状不变） | [0, 57600) | 57600 |
| 索引窗 1（现状不变） | [57600, 115200) | 57600 |
| **帧窗 0** | [115200, 576000) | 460800 |
| **帧窗 1** | [576000, 1036800) | 460800 |
| （余量） | [1036800, 2M) | 1060352 |

FB_TOTAL=460800 不变；"FB_BASE"由常量变为**帧窗基址函数**（见 §4/§6）。
余量 106 万字留给后续精灵层/第三窗/1080p 档评估。

## 4. 双窗口协议

### 4.1 窗号语义
- 渲染帧 k（u_band.render_no，0 基）从**索引窗 k%2** 取带（现状 base_l 不变），
  其扫描写入目标 = **帧窗 k%2**。
- 窗完成：帧 k 的 band 179 `scan_done` 拍 ⇒ `win_done[k%2]` 脉冲（100M 域），
  记 `win_show_req = k%2`（"最后完成窗"）。

### 4.2 写端（100M 域，扫描写端改造点）
- band_done 拍锁存 `u_band.render_no[0]` 为本带目标窗号；
- `wr1_addr = 115200 + win*FB_TOTAL + band*2560`（64 对齐 ✓：115200、460800、
  2560 均 ≡0 mod 64）；
- 其余（LOAD 每带一次、LENGTH=256、rp 影子排空）零改动。

### 4.3 读端（像素域，yx_b_scanout）
- `win_show_req` 1 位 → 像素域**双拍同步**（窗号只翻转，两拍同步 + 边沿检测
  足够；逃逸窗口 = 一个显示帧，无害）；
- 像素域本地计算显示窗基址 = 115200 + win*460800；
- **vblank 每帧发 LOAD**（A 板语义）：①重置读指针到窗头（每帧天然对齐）；
  ②换窗时切到新窗基址——一箭双雕；
- **MAX 引脚恒 0x1FFFFF（fetch v4 同款哲学）**：显示每帧恰好消耗一整窗
  （720 行 × 640 字 = 460800 = FB_TOTAL），回卷完全由 vblank LOAD 承担，
  **不依赖 rRD*_MAX 的复位锁存行为**（YX4 教训：MAX 只在复位锁存）；
- RD1_FIFO：clkw=100M（控制器 CLK）/ clkr=73.33M（像素域），vendor 原生 CDC
  （A 板同款）。

### 4.4 撕裂免疫论证
- 渲染帧 k 写帧窗 k%2；显示读"最后完成窗"= (k−1)%2 = k%2 ^ 1 —— **写读窗恒异**；
- 显示线性扫**完整**窗（窗完成才可被选中），写入在另一窗——两窗交替、互不重叠；
- 首窗完成前（帧 0 渲染完之前）：显示输出黑（valid=0 或 rgb=0），不发起读。

## 5. yx_b_scanout 模块设计（新文件 media/vp/yx_b_scanout.v）

**裁剪版新写**（不复用 A 板 player 全量：B 板不需要 fade/contrast/brightness 特效，
减少不必要逻辑），三段拼装：

1. **时序 + AXIS**：例化 `video_source_test`（参数 A 板同款，文件零改动），
   `I_fb_rgb` 接取数核输出；
2. **取数核**（自 yingxu_sdram_video_player 裁剪）：vblank → 8 拍 LOAD（重置读
   指针+预取）、primed 首字、每奇数 x 消费 1 字（FIFO 空时保持 pair——A 板教训）、
   RGB565→RGB888 直通扩展（fade/bright/contrast 三级流水全部裁掉）；
   RD1_ADDR/MAX/LOAD/LEN 驱动 + RD1_DATA/EMPTY 消费；
3. **双窗基址**（§4.3）：win_show_req 双拍同步 → 本地窗基址寄存器 → RD1_ADDR/MAX。

对外接口（顶层接线用）：
- 100M 域输入：rst_n、win_show_req（最后完成窗号）、
- 像素域：pixel_clk、pixel_rst、RD1_*（控制器口）、AXIS 输出
  （video_user/valid/last/data + ready）、遥测（O_win_show、O_disp_pass 计数）。

## 6. 顶层显示侧改造（yingxu_vq_board_top.v）

- **旧显示消费者退役**：token bucket（DISP_NUM/DEN）、disp_scan_seen 9 位计数、
  disp_word_q/disp_band 逐字 gating、disp_started_guard——**全部移除**。
  其中 **9 位 seen 跨帧回绕债（YX4 §五.3）结构性消失**：双窗协议下显示不再
  逐带 gating（窗级完成判定替代）；
- RD1 接线改造：`RD1_CLK` 从恒 clk100 改为 **pixel_clk**；RD1_ADDR/MAX/LOAD
  改由 scanout 驱动；RD1_MAX 恒 0x1FFFFF；
- 扫描写端窗选择（§4.2）；
- 新增 EMIT_HDMI 参数（默认 0）：
  - 仿真构建（EMIT_HDMI=0）：scanout 的 AXIS 引出顶层观测口（TB 对拍），不例化
    加密核/PHY/PLL（iverilog 编不过 .enc）；
  - TD 构建（EMIT_HDMI=1）：AXIS → 加密核（参数 A 板同款：720p/VIC69/RGB/
    TPG Disable/48K）→ PHY wrapper → 引脚；I_audio_valid=0（mute）、
    I_acr_valid=0、I_edid_read_trig=0（观察项）；I_pixel_clk/I_rst = pll_hdmi1_4b
    输出（73.33M/366.67M，TD 例化，仿真用 shim）；
- 遥测改版：disp_words/disp_band 移除，新增 O_win_show（显示窗号）、
  O_disp_pass（显示遍计数，TB 判据用）。

## 7. 时钟规划

| 时钟 | 来源 | 用途 |
|---|---|---|
| 100M | Sdram_PLL（现状） | 控制器 + 全部视频逻辑（不变） |
| 73.33M 像素 | pll_hdmi1_4b clk1_out（TD）/ shim（仿真） | scanout 全域（时序计数、取数、AXIS） |
| 366.67M 串行 | pll_hdmi1_4b clk0_out（TD） | 加密核 TMDS 串化 |

CDC 边界（全由既有机制承载）：RD1 FIFO（clkw 100M / clkr 73.33M，vendor 原生）；
win_show_req 1 位双拍同步（§4.3）；无其他跨域。

## 8.5 P3 调试实录与当前裁决（2026-11-22，独立 TB）

为摆脱"7 分钟一轮全 SoC"的低效循环，新建 `tb/tb_scanout.v`（秒级编译、
~3 分钟一遍）：行为读源（字=乘法哈希，模 2^32 可逆 → 任意一拍可反解绝对字
地址）、按行 1280 拍比对、逐行偏移搜索。

**已修并确认的 RTL 缺陷（8 项，均带证据）**

| # | 缺陷 | 证据 |
|---|---|---|
| 1 | 冲洗退出未撤 `rd1_load` → 调度器永久冻结（全系统死锁） | 全 SoC `ctl: ST=0 msk=00` 全程不变 |
| 2 | CDC shim 格雷码指针截到 9 位（实为 10 位） | `rbw=639 > wb=384`、emp/af 全乱 |
| 3 | CDC 占用用 `>=` 守卫，写指针回绕时把非空判空 | `occ_w=202 / occ_r=0` 显示饿死 |
| 4 | 帧缓冲字布局 `{奇,偶}` 与 mux `{偶,奇}` 相反 | 偶奇像素互换，反解逐点吻合 |
| 5 | A1/golden 判据漏双窗偏移 | 帧 1+ 写窗 1 而判据读窗 0 |
| 6 | 金标地址 `1'b × 参数` 位宽溢出为负 | `wd=xxxxxxxx@-2147368448` |
| 7 | `pixel_active` 与流水线错拍 → 行首 2 拍黑 | 行首 got=000000 |
| 8 | `PIX_DLY` 语义错误（`pxd[0]` 多延迟 1 拍） | 扫参仅 D=0（直连）可用 |

**当前剩余（已定界，非"未知"）**

- 每帧 720 行、每行 1280 valid 拍、**行体 1276 像素逐点正确**；
- 行首固定 4 像素异常：同一个字被输出两次（2 字槽冻结），随后恒定 6 像素
  相位（`got(m) == exp(m-6)` 对 m≥4 逐点成立）；
- 每帧 pop 460805（期望 460800，+5），`disp_stall=2048`；
- 已试无效：4 深 skid 预取（未改变 4 像素现象）→ 说明不是供数饥饿。

**裁决（2026-11-22 已闭环）**：行首瑕疵由 **A1 方案**根治——`valid` 不再用源
输出（其在行末多 2 拍、落进消隐却被按拍计数当成下一行前 2 像素），改由
**本模块用 `pixel_active` 延迟 8 级生成**，与数据逐拍对齐。

实测结果（tb_scanout，`-DVDLY` 扫参）：

| VDLY | errs | 说明 |
|---|---|---|
| 3 | 1434 | 每行 2 错 |
| 4 | 717 | 每行 1 错 |
| **7（默认）** | **0** | **best_sh=0、nlines_bad=0、ALL PASS** |
| 6 | 0 | 亦通过（但有 1 像素常数偏移） |

全 SoC `bboard_key`：`ax_errs=0 / 383.8 万拍 / 2278 行`，GATE 全项 OK，
**ALL PASS**。

**附带**：skid 预取（4 深）保留——虽非本次根因，但把取数与消费解耦，
在真实 FIFO + 仲裁环境下提供必要抖动余量。

**遗留（P5 处理）**：`video_user`/`video_last` 仍取源输出相位。二者在独立
TB 与 AXIS 判据下均正确（TB 按 valid 计数、用 user 切帧），但接加密核时需按
核的实际采样点校准相位（实测将 user 一并延迟会引入 4 拍错位，说明源内 user
与 active 存在相位差，需单独处理）。

## 10. P3 验收（2026-11-23 全部通过）

| 入口 | 判定 | 关键证据 |
|---|---|---|
| **bboard_key**（合成流） | **ALL PASS**（`bboard_key_20261123_165803`） | GATE 全项 OK；`ax_errs=0 / 4,413,454 拍 / 2728 行` |
| **bboard_sys**（真实流含 DELTA） | **ALL PASS**（`bboard_sys_20261123_164127`） | GATE 全项 OK；`ax_errs=0 / 5,423,360 拍 / 3517 行`；`golden=0 igold=0 cperr=0 cpdeliv=166212` |
| **tb_scanout**（独立，秒级） | **ALL PASS** | best_sh=0、errs=0、nlines_bad=0（720 行零错） |

**P3 实现要点（最终版）**
1. **valid 由 `pixel_active` 延迟 8 级生成**（A1 方案）：消除源 valid 在行末
   溢出 2 拍导致的"每行首字重复"（2868 错 → **0 错**）。VDLY 扫参证明 7 级
   最优（零相位偏移）。
2. **`win_show` 改为反映 `i_base` 实际指向的窗**（而非实时 req）：修复写窗
   闸门误判 → 消除"显示读窗 X 同时写窗 X"。这是防撕裂的核心。
3. **skid 4 深预取**：取数与消费解耦，抑制供数抖动。
4. **CDC FIFO**：格雷码 10 位全宽 + 占用模减 + AF 水线 300。
5. **互斥断言精确化**：比较控制器当前读地址（`rRD1_ADDR`）与写带区间，
   替代整窗/窗号比较（后者误报 9288 次）。

**实测带宽/节奏**
- 显示遍 921600 拍（16.87ms，59.3fps），每帧 720 行、每行 1280 拍；
- `disp_stall=6950`（消隐期冲洗，已被 skid 吸收，像素零错）；
- `stall2≈12~13%`：渲染被防撕裂闸门节流（渲染全速 > 显示 59.3fps 时必然），
  属设计行为；真实 24fps 内容下不会出现。

**遗留（P5 处理）**
- `video_user`/`video_last` 仍取源输出相位，接加密核时需按核采样点校准
  （实测将 user 一并延迟 8 级会引入 4 拍错位，说明源内 user 与 active 有
  相位差，需单独处理）。

## 8. 带宽预算（100M 域，字/拍，实测验收项）

| 流 | 稳态 | 峰值（渲染期） |
|---|---|---|
| RD1 显示（新增恒载） | 0.274（460800 字 / 16.87ms / 100M） | 同左（不可压） |
| WR1 扫描写入 | — | ~0.34 |
| RD2 取带+cp | — | ~0.13 |
| WR2 索引写 | — | ~0.06 |
| **合计** | **0.274** | **~0.8** |

页模式可持续 ~0.85-0.9（含刷新）——渲染期峰值紧但可行（A 板同款控制器跑
显示+写入成功）。**验收项**：sim 实测 RD1 FIFO 空拍率（pair 保持事件计数），
阈值 = 每 460800 字 ≤ 4096 次（初值，可调）；超阈值则渲染期降速优先级复核
（cp 已是帧尾空闲窗，下一步是 WR1 分段让位）。

## 9. 仿真策略与判据

- **时长预算**：一显示遍 = 1.2375M 像素拍 ≈ 1.69M 个 100M 拍（16.87ms）。
  sys 入口渲染 5 帧至 ~8.4M 拍，之后显示持续跑——**不追求完整遍覆盖**，
  TB 抽查判据限定窗口；WD 维持 12M（预计覆盖首窗完成（~1.6M）后 6 遍显示）。
- **不做 SIM_ACCEL**（压缩消隐/加速像素时钟都会破坏取数节拍与 CDC 前提）。
- 判据（GATE 改版）：
  1. **AXIS 内容级对拍**（替代影子队列）：显示遍内抽查行（首 8 行 + 每 32 行
     抽 1 行）逐像素 = 金标帧（key 入口合成公式 / sys 入口 gfb_mem）RGB888
     扩展后比对；user 仅帧首 1 拍/帧、last 每活跃行末；
  2. **写读窗互斥断言**：任意拍 显示窗 ≠ 渲染写窗（§4.4）；
  3. **vblank 重载断言**：每显示帧恰 1 次 LOAD、地址 = 显示窗基址；
  4. **RD1 供数**：pair 保持事件计数 ≤ 阈值（§8）；
  5. 双回归保持：bboard_key（显示判据改版后仍合成金标可对拍）+ bboard_sys
     （gfb_mem）双 ALL PASS；
  6. 旧判据退役：disp 影子队列/非 X 检查、disp_words 尾部条件改版
     （渲染完成 + 显示遍数 ≥ 2）。
- 判据实现层：TB 新增 AXIS 采样对拍器（像素域侧，hierarchical 采样）。

## 10. TD 侧清单（待 AC601 引脚表后执行，P5 一起做也行）

- 例化 pll_hdmi1_4b + 加密核 + hdmi_phy_wrapper（EMIT_HDMI=1 generate）；
- 引脚：4 对 TMDS 输出（ch0/1/2/clk_p）、（可选 DDC scl/sda 观测）；
- timing.sdc：新增 73.33M 像素域组 + 366.67M 串行组 + RD1_FIFO 跨域路径
  （100M↔73.33M）例外声明；
- B 板首份实测资源/时序报告同步产出。

## 11. 风险与对策

| 风险 | 对策 |
|---|---|
| 渲染期四口并行 + 显示峰值带宽 ~0.8 字/拍 | §8 验收项实测；超阈值降 WR1 优先级/分段 |
| 加密核 ready 行为（B 板首次直驱） | A 板已验证件 + ready 仅 informational；sim 边界不含核 |
| rRD_MAX 复位锁存（YX4 教训） | MAX 恒 0x1FFFFF + vblank LOAD 回卷（§4.3） |
| sim 时长膨胀 | 抽查判据 + WD 维持 12M（§9） |
| 显示首帧黑屏期（首窗未完成） | guard 输出黑；TB 不对拍黑屏期 |
| TB 判据改版波及 key 基线 | 判据改版一次到位、key+sys 双回归重跑并记录新基线 |

## 12. 实施顺序（P3 内部）

1. yx_b_scanout.v（裁剪取数核 + video_source_test 例化 + 双窗基址）+ 顶层
   显示侧改造 + 扫描写端窗选择；
2. TB 判据改版（AXIS 对拍器 + 互斥断言 + 尾部条件）；
3. key 入口回归（显示判据新基线）→ sys 入口回归；
4. 带宽实测（RD1 空拍率）回填 §8；
5. （P5 时）TD 侧 EMIT_HDMI 构建 + 引脚约束 + SDC。
