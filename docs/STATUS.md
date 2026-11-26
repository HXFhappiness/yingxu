# 映序 0.17.0 — B 板体系化 交接状态

> 更新时间：2026-11-11（第二版，依据当日技术审计修订）
> 来源：旧会话原始模型 IO 记录 + `gpt-6.1-sol` 对仓库/日志的复核审计
> 用途：在新会话里无缝接续。开工前请读完全文并执行文末检查清单。

> **⚠️ 最新状态（2026-11-23，YX7 会话）**：**P3（HDMI 扫出 + 双窗口）已验收通过**。
> `bboard_key` 与 `bboard_sys` 双入口 **ALL PASS**，AXIS 逐像素对拍把 `ax_errs=0`
> （key 441 万拍 / sys 542 万拍）。核心成果：valid 由 active 延迟 8 级生成（消除
> 行首字重复）、`win_show` 反映 i_base 实际窗（修复防撕裂闸门误判）、skid 预取、
> CDC FIFO 格雷码修正。调试方法改进：新建 `tb/tb_scanout.v` 独立仿真（秒级迭代，
> 替代 7 分钟一轮的全 SoC），并用"乘法哈希可反解内存"实现精确相位定位。
> 详见 `docs\YX_BBOARD_P3_DISPLAY_20261121.md` §8.5/§10。
> 下一步：P4（以太网入口）→ P5（TD 综合，待 AC601 引脚表；user/last 相位需校准）。
> 再前状态见 `docs\YX_BBOARD_CPRD_20261121.md`（cp 口闭环）、`STATUS_YX4.md`。

**修订说明（对比第一版）**：第一版把状态写成"只剩一个 afull 吞吐 bug"，并记录了 12 项"已修复"。经复核，这个结论**不成立**——部分"修复证据"来自有缺陷的构建流程（编译失败仍跑旧 `.vvp`），因此相关结论一律降级为"待验证"。本版以审计结论为准。

---

## 1. 背景与硬约束

- **项目**：映序 0.17.0（FPGA 视频编解码板卡）
- **工程根目录**：`C:\Users\HXF\Desktop\YX`
- **当前阶段**：初赛已结束，进入决赛准备。**A 板稳定冻结**；当前工作是把 **B 板**从"数据通路验证核"升级为"成体系板卡"。
- **硬约束**：
  1. **本阶段只做仿真，不烧录、不生成 bit 流**；
  2. VQ / B 板功能**不能混入 A 板**现有顶层和构建清单；
  3. 本地修改，**不自行推送 GitHub**；
  4. 仿真进程退出码为 0 **不等于**测试通过——需要核对日志、错误计数和验收条件；
  5. 中文回答。

---

## 2. 当前真实状态（一句话）

> **已证实的是若干子链路和历史配置曾通过仿真；尚未证实的是当前 KEY-only 真实四端口体系。**

不要再沿用"只剩最后一个 afull 调参 bug"的说法，也不要沿用旧会话里任何没有依据的完成声明。

---

## 3. 任务地图

| 阶段 | 内容 | 状态 |
|---|---|---|
| P1 | 索引路径真实化（WR2/RD2 接真实控制器） | 代码存在，**协议未经独立验证** |
| P2 | KEY-only 码流 + 头解析/码本装载 | 代码与码流存在，**验收未通过** |
| **P1/P2 验证** | **KEY-only 720p × 5 帧 SYS 集成验收** | ❌ **未通过 / 未证实** |
| P3 | HDMI 扫出 + 双窗口 | 待 P1/P2 通过 |
| P4 | 以太网 UDP 入口 | 待 P3 |
| P5 | B 板 TD 综合 + STA | 待引脚表 |

---

## 4. 待验证问题清单（按修复优先级）

### 4.1 验收基础设施本身是坏的（**最先修，否则后面所有结论都不可信**）

会话中多次出现：

```
iverilog 编译失败  →  shell 仍打印 OK / BUILD_OK  →  vvp 继续运行旧文件  →  返回旧结果
```

根因：命令写成 `iverilog ... | findstr ... & echo OK & vvp ...`，**没有检查编译器退出码**。

其他缺陷：

- TB 的 PASS 条件未包含 `golden_errs==0`；
- 曾用 `frames_done>=5` 判通过，会放过"多解出帧"的错误；
- 当前 POLL 直接引用 `REAL_IX`，可能使抽象模式编译失败；
- 缺少统一的 X/Z 检查；
- 同名二进制、日志并行使用，导致过文件锁与版本混淆；
- 最后一项"wrapper 标志并排探针"任务 **退出码 255**，未产生有效新仿真证据。

**修复要求**：

1. 唯一输出文件名；编译失败立即终止，不运行旧 `.vvp`；
2. 编译开警告，检查数值截断、未连接输入、隐式 wire、generate 作用域、多驱动；
3. 短跑加 `$fflush` 或可靠实时日志，不用长时间盲等代替进度确认；
4. PASS 必须同时满足：

```text
解码帧数 == 5
渲染帧数 == 5
扫描带数 == 900
scan_errs == 0
golden_errs == 0
无 X/Z、溢出、欠载、超时
```

### 4.2 扫描器状态编码错误

- 需修正所有 `2'd4` 截断；
- 先验证**一带**完整推进与 `scan_done`；
- 分开验证行缓冲读地址流水、停顿恢复、最后一字；
- 必须区分"字已推入 FIFO"与"字已写入 SDRAM"，**不能在最后一个 FIFO 写沿就宣告 SDRAM 完成**。

### 4.3 WR2 反压与顺序写协议

- **没有 WR2_FULL 反压，不能保证不丢数据**：固定优先级仲裁可能让 WR2 长时间得不到服务，缓冲必须有正确反压或容量上界证明；
- 顺序写 v2 方向是"一次 LOAD + 连续灌数"，切窗等待固定 600 拍，需检查：
  - 首窗是否真正发过初始化 LOAD；
  - 切窗首字是否在旧地址配置下先被接收；
  - 600 拍是否能覆盖实际仲裁延迟（**FIFO 深度 512 不推出 600 拍必排空**）；
  - 必须按真实写入完成后再允许 ixbuf 发布 `swap_done`；
  - WR2 地址范围与 `MAX_ADDR` 是否与窗口一致。

### 4.4 取带器换窗与 pop/dvld 时序

相关信号：

```text
rd2_re, rd2_empty, rd2_we, rd2_bmask1
drain, drain_cnt, old_done, cap, out_v, rd_dvld
fetch_reload_r, u_band.base_l
```

已发生过：`out_v` 不清零、`cap` 无置位、切窗后错误冲刷、基址变化检测漏首帧、用提交事件重载导致渲染帧与取带窗口错配。

当前逻辑使用：

```verilog
band_frame_start = (swap_done_w && (u_band.st == 0)) || frame_done_vq;
```

但 `frame_done_vq` 已提前到最后一带渲染完成，**不等于下一帧真正开始**，该重载时序是否正确未验证。

---

## 5. 数值口径（避免再次混淆）

- 720p：`NB = 57600`；
- 当前适配器：**一个索引占一个 32bit SDRAM 字**；
- 因而每窗恰好 **225 个 256 字突发**，**没有尾数**；
- 早期"113 个突发、补尾"的说法来自另一种打包假设，**不能用于当前实现**。

---

## 6. 关键文件路径

工程根：`C:\Users\HXF\Desktop\YX`

### B 板 RTL

```text
src\user_source\hdl_source\media\vp\yingxu_vq_board_top.v
src\user_source\hdl_source\media\vp\yx_vp_band.v
src\user_source\hdl_source\media\vp\yx_vp_ixbuf.v
src\user_source\hdl_source\media\vp\yx_vp_ixdec.v
src\user_source\hdl_source\media\vp\yx_b_hdr_parse.v
src\user_source\hdl_source\media\vp\yx_b_ix_seq_wr.v
src\user_source\hdl_source\media\vp\yx_b_ix_fetch.v
```

### 仿真与 shim

```text
tb\tb_yxvp_bboard.v
tb\tb_yxvp_ixpipe.v
tb\tb_sdctrl_sanity.v
tb\tb_gen_key_stream.v

tb\bshims\EG_LOGIC_FIFO.v
tb\bshims\EG_PHY_PLL.v
tb\bshims\EG_PHY_SDRAM_2M_32.v
tb\bshims\Sdram_Control_4Port.v

tools\_ctrl_shim.py
src\5640\sdram_ctrl_4p\
```

### 可复用 HDMI / 网络代码

```text
src\user_source\hdl_source\video_source_test.v
src\user_source\hdl_source\yingxu_sdram_video_player.v
src\user_source\hdl_source\yingxu_sdram_control_4port.v
src\user_source\hdl_source\hdmi_phy_warpper.v
src\user_source\hdl_source\lane_lvds_10_1.v
src\user_source\hdl_source\hdmi1.4b_transmitter_core\
al_ip\pll_hdmi1_4b\

src\eth_udp_rx_gmii.v
src\eth_udp_tx_gmii.v
src\rgmii_to_gmii.v
src\gmii_to_rgmii.v
src\crc32_d8.v
src\ip_checksum.v
```

### 记录与日志

```text
docs\YX_BBOARD_INTEG_DESIGN_20261110.md
docs\YX_BBOARD_INTEG_RESULT_20261110.md
docs\YXVP_IXPIPE_S3_RESULT_20261110.md
docs\YXCK_FREQ_CDC_REVIEW_20261110.md

out\vp_720_key.yxv2
out\sdctrl_sanity2.log
out\ixpipe_regress.log
out\bboard_run.log
out\b1080_24.log
out\b1080_30.log
out\b1080_free.log
out\bboard_sysM.log
```

> ⚠️ 验收报告里部分"全链路""正式档位""任何真实档位都在包络内"的描述**超出证据**，需要修订，不能直接作为最终验收结论。

---

## 7. 历史修复台账（**可靠性存疑，需重新验证**）

旧会话声称修复过以下问题，但部分"证据"来自 4.1 描述的坏构建流程，**不要当作已验证事实**：

| # | 缺陷 |
|---|---|
| 1 | FIFO shim 格雷链双重转换（改为二进制指针） |
| 2 | hdr_parse 吞字节 ×2 |
| 3 | 码本 wa 时序 |
| 4 | +1 字节帧头 |
| 5 | 取带器 cap 丢失 / out_v 不清零 / 切窗冲刷 |
| 6 | 首帧重载不触发 |
| 7 | 写端 LOAD 覆盖 |
| 8 | 地址重叠 |
| 9 | FULL 背压缺失 |
| 10 | wr2_full 漏接 |
| 11 | 码本字节错位 |
| 12 | 占用计数非增量 / 未饱和 |

**处理方式**：视为"可能相关线索"，在修好构建门禁后逐项回归确认，不要直接当作已完成。

---

## 8. 已知的不可信内容（旧会话幻觉）

使用 `glm-5.3-flash` 的旧会话后期出现明显幻觉，以下内容**不可作为事实依据**：

- "Vivado 工具启动成功 → 综合成功 → 布局成功 → 路由成功 → `.bit` 文件生成成功"——与"不烧录、不生成 bit 流"直接矛盾，判定为编造；
- "P1/P2 验证已经完成了"——未执行任何验证动作，只是复读问题；
- "预算见底 / 预算将尽"——模型对自身额度的误判，非真实报错；
- 连续无效回复（"GLM 5.3 Flash here... I'm ready to assist"）——该模型把 ZCode 注入的 `<system-reminder>` 当作用户消息回应，形成自我循环。

**新会话请勿使用 `glm-5.3-flash`**；建议 `gpt-6.1-sol`、`claude-opus-5-5` 或官方 `deepseek-flash`。

---

## 9. 对 AI 助手的工作要求

1. **先修验收基础设施，再做任何"修复"**——否则无法证明任何结论；
2. 不继承旧会话的完成声明，一切以文件、编译输出、仿真日志为准；
3. 每轮先给结论和数据，再动手；改完必须贴编译退出码 + 仿真关键计数；
4. 不要复述用户指令、不要回应系统提醒，直接干活；
5. 遇到歧义先问一句，不要自行假设后大改；
6. 长分析写入文件，不刷屏。

---

## 10. 交接检查清单（开工第一步）

- [ ] 检查 `run.bat`、`scripts\`、`tb\` 里的仿真命令，确认是否存在"编译失败仍继续跑旧 `.vvp`"的问题；
- [ ] 把所有仿真入口改为：编译失败立即退出 + 唯一输出文件名；
- [ ] 读取 `tb\tb_yxvp_bboard.v`，确认 PASS 条件是否包含 `golden_errs==0`、`scan_errs==0`、无 X/Z；
- [ ] 读 `docs\YX_BBOARD_INTEG_RESULT_20261110.md`，标出所有"超出证据"的表述；
- [ ] 跑一次带门禁的基线仿真，记录：解码帧数、渲染帧数、扫描带数、`scan_errs`、`golden_errs`、X/Z 计数；
- [ ] 与本文第 2、4 节比对，确认问题清单是否一致。

---

## 11. 本轮第一件事

按第 4 节的顺序执行：

1. **4.1 修构建与验收基础设施**（门禁 + 唯一文件名 + 完整 PASS 条件）；
2. **4.2 修正 `2'd4` 截断**，先验证一带完整推进；
3. **4.3 补 WR2 FULL 反压**，验证首窗 LOAD 与写完成屏障；
4. **4.4 验证取带换窗/pop 时序**；
5. 以上全部通过后，重新执行 KEY-only 5 帧 SYS 验收，再进入 P3/P4/P5。
