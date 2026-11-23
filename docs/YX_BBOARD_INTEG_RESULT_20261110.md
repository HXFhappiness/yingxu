# 板 B SoC 集成仿真验收报告 — 2026-11-10

## 结论：**720p 与 1080p 全部 ALL PASS**（仿真证据齐全）

| 档位 | 结果 | 证据 |
|---|---|---|
| 720p×5 帧（自由跑） | **ALL PASS** | 900 带 0 错、stall2=0、5/5 帧 |
| **1080p×5 帧 @24Hz 显示节流** | **ALL PASS** | 1350 带 0 错、stall2=0、rd_b=12618 |
| **1080p×5 帧 @30Hz 显示节流** | **ALL PASS** | 1350 带 0 错、stall2=0、rd_b=15758 |
| **1080p×5 帧 自由跑（压力上限）** | **ALL PASS** | 1350 带 0 错、stall2=0、rd_b=42028（0.81 字/拍持续） |

1080p 帧节奏 2.6M clk/帧 = 预测 25.9ms ✓（渲染能力 38.6fps，跑 24/30fps 占 62%/77%）。
自由跑读带宽 0.81 字/拍远超 24/30Hz 档（0.249/0.311），**任何真实档位都在压力包络内**。
显示节流用令牌桶精确复现扫出率（249/311 ÷ 1000），dispE 恒定 ~24K/帧 = 节流生效。

日志：out/bboard_run.log（720p）、out/b1080_{24,30,free}.log。

```
720p:      CNT: frames=5 bands=900  scan_errs=0 disp_errs=0 stall2=0/8035195  (0%)
1080p@24:  CNT: frames=5 bands=1350 scan_errs=0 disp_errs=0 stall2=0/16035195 (0%)
1080p@30:  同上 ALL PASS
1080p自由: 同上 ALL PASS
```

## 1. 验收范围与链路

A 板字节流(vp_720_5f.yxv2, 265KB) → yx_vp_ixdec → yx_vp_ixbuf → yx_vp_band
（深度 2 握手 + 双扫描读口）→ 扫描写端 → **vendor SDRAM 控制器 + EG_PHY_SDRAM 硬宏**
（页模式全页流式）→ 显示消费端（RD1 连续流）。

帧缓冲布局：带 b 占 [b*2560, +2560)（32bit 字，2 像素/字），10 页/带页对齐。

## 2. 三条断言（全过）

| # | 断言 | 证据 |
|---|---|---|
| A1 | 扫描对拍：每带 scan_done 时 SDRAM 帧缓冲区 vs 行缓冲半区 2560 字逐位一致 | **900/900 带 0 错** |
| A2 | 不欠扫描：渲染器因深度 2 顶满（pend_cnt==2）的滞留占比 | **stall2=0（0%）** |
| A3 | 帧推进：5 帧全部渲染+扫描 | frames=5，commit=4，rno_done 0→4 |

## 3. 本轮联调修复台账（全部有定位数据）

| # | 位置 | 缺陷 | 修复 |
|---|---|---|---|
| 1 | top 扫描写端 | 分页扫描时 sc_push 跨页未清零 → 行缓冲地址偏 512 像素 | 页首地址不含 sc_push |
| 2 | top 扫描写端 | sc_wdata/wr1_en 同拍捕获 → 首字残值、末字丢失 | re 沿采 pre-edge 流水对齐（skip 首拍 + TAIL 撤使能） |
| 3 | top 端口 | clk100 未引出 → TB 全部 @(posedge clk100) 永等 | 加 dbg_clk100 输出 |
| 4 | top→ixbuf | rendered_no 误接"开始渲染帧号"（契约=最后完成帧号）→ busy 误释放/WAITFREE 死锁 | frame_done 拍锁存 render_no |
| 5 | band 深度2 | **帧尾判定用 ack 时刻的 band_no**——被后续带完成覆盖 → f0 帧尾丢失、f1 尾误判 → busy[0] 死锁 | 完成时入 2 深帧号队列，ack 弹队首判定 |
| 6 | band/top | frame_done 在 ack 拍触发，rno_done 锁存时 render_no 已推进 → 释放错缓冲 | frame_done 提前到"帧尾带完成"拍 |

期间一次激进修改（去掉 frame_wait 停等）导致 ixpipe 回归 cmpfail=374，**立即回滚**——
帧尾停等是行缓冲半区不被下一帧覆盖的保证，也是既有 TB 比对的时序前提。

## 4. 回归矩阵

| 测试 | 几何 | 结果 |
|---|---|---|
| tb_sdctrl_sanity（控制器+4 shim 写读回环） | 256/256/128 字 | **ALL PASS** |
| tb_yxvp_ixpipe（既有回归，band 改动后） | 720p×5 帧 | **ALL PASS**（900 带 0 失败） |
| tb_yxvp_bboard | 720p×5 帧自由跑 | **ALL PASS** |
| tb_yxvp_bboard | 1080p×5 帧 @24Hz | **ALL PASS** |
| tb_yxvp_bboard | 1080p×5 帧 @30Hz | **ALL PASS** |
| tb_yxvp_bboard | 1080p×5 帧 自由跑 | **ALL PASS** |

1080p 参数化改动：AW 自适应 19（索引双缓冲 259K 字）、帧缓冲基址/半区偏移去硬编码、
显示端令牌桶节流（DISP_NUM/DEN 参数）。

## 5. 已知观察项（不影响验收）

- FRAME 行的 bands 计数偶显 179/359 等（帧尾带 ack 与 scan_done 落账跨拍）——计数时序，
  A1 全量对拍 0 错证明无数据问题。
- 显示消费端 disp_words 为 16 位（每帧回绕 ~7 次），仅遥测用。
- 索引缓冲 SDRAM 随机口（ixbuf 补丁写/拷贝读、band 取带）由行为模型承载：vendor 4port
  只支持顺序突发，随机口需板级专用方案（独立立项，见设计文档 §2）。

## 6. 复现

```
iverilog -g2005 -o out\bboard.vvp tb\tb_yxvp_bboard.v <top+3 个 vp 模块>
         tb\bshims\*.v src\5640\sdram_ctrl_4p\{sdram_ip,command,control_interface,
         sdr_data_path,Sdram_PLL,Sdram_WR_FIFO,Sdram_RD_FIFO}.v
vvp out\bboard.vvp +STREAM=out\vp_720_5f.yxv2 +WD=8000000
```
