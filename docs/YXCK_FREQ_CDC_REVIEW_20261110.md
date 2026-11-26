# CPU 频率尝试 + 跨域违例治理 + 全面盘点 — 2026-11-10

## 1. 任务一：CPU 降到 50MHz —— 尝试结果：**架构上不可行，不保留**

### 时钟结构实测（推翻任务前提）
| 域 | 频率 | 来源 | 成员 |
|---|---|---|---|
| **主逻辑域（S_pixel_clk）** | **73.33MHz** | HDMI PLL clkc1（VCO 1100/15） | 游戏、SD 引擎、HDMI 核、音频 PSG（CLK_HZ=73_333_333 ✓）、**cart/CPU/loader/程序 RAM** |
| SDRAM 域 | 100MHz+相移 | Sdram_PLL clkc0/1 | SDRAM 控制器+帧缓冲 |
| TMDS 串行域 | 366.7MHz(90°) | HDMI PLL clkc2（VCO/3） | OSER10 串行器（5×DDR=733.3Mb/s ≈ 720p） |
| sys_clk | 50MHz | 晶振直入 | cart 内 SD 命令 FSM、0.5s 看门狗、UART 遥测（BAUD_DIV=434@50M ✓） |

**CPU 没有独立频率**：它挂在主逻辑 73.33M 域上（`yx8_cart_soc_v2.pix_clk = S_pixel_clk = clk1_out`）。

### 三条实现路径逐一排除
1. **整域降 50M**：HDMI 串行比 5:1 DDR 锁定（366.7M 固定），像素率 73.33M≈720p@60；降到 50M 后串行比错乱 + 像素率 -33%，视频模式崩；且违例本身要求 ≤59.6MHz（-20%），远超显示器对同模式描述符的容差。**排除**。
2. **cart 改挂 50M 晶振（sys_clk 已接入 cart ✓）**：性能无碍——实测 invaders（最大卡带）平均 **472 指令/帧**，悲观 CPI=4 且放大 10 倍活跃玩法也只占 50M 帧预算（833K 周期）约 **2%**；但 sprite/brick/event 接口（spr_we+多位数据+槽号、事件脉冲）全部变成真 CDC，需要双端口 LUTRAM 化 + toggle 标志改造，**游戏侧无仿真覆盖且当前约束禁止烧录验证**，"无负面影响"无法建立。**缓行，待板测恢复后立项**。
3. **域内使能降速（clock-enable）**：不改变寄存器到寄存器路径的时钟周期，**对 reg-to-reg 违例无效**。**排除**。

### 结论
**维持 73.33MHz**。-3.116ns 违例为 **YX-8 基线既有**（旧构建同路径 -7.804ns 板级实测正常），且经实测确认路径为 8 位 ALU/旗标链（此前"YX-8.1 16 位路径"的归因有误，予以更正）。

### 参数层尝试记录（均无效）
- 导出 gate.params 中的 `resource_sharing=on` 是**静态模板快照**（活参数表 Gate Property 中无此参数，`set_param` 静默无效果）。
- `map_mode logic_level_prior`（模板预期值）实测 WNS -3.25ns / FEPS 180，劣于默认 auto（-3.12 / 122），已回退。

## 2. 任务二：跨域违例治理 —— **已完成，全绿**

### 定性
10 条 clkc1→clkc2 违例路径全部为 `O_tmds_code_data_reg[9:0]`（像素域 TMDS 编码）→
`u0_lane_lvds_8_1/S_shift_data_reg[9:0]`（串行器移位寄存）。查 `lane_lvds_10_1.v`：
`S_odd_even` 像素域翻转标志经 **2FF 同步器**入串行域，`S_load_en` 三级延迟生成加载脉冲，
`S_shift_data` 在数据稳定后加载（加载间隔 = 5 串行周期 = 1 像素周期）——**设计内 CDC，结构正确，
板级实测通过**。TD 按"无关时钟"把数据要求对到 3ns 后最近串行沿，产生假违例。

### 处置（timing.sdc，仅约束零硬件）
```
set_clock_groups -name cdc_hdmi_pix_serial -asynchronous \
  -group [get_clocks {*U_pll/pll_inst.clkc[1]*}] -group [get_clocks {*U_pll/pll_inst.clkc[2]*}]
```
### 验证
FEPS **153 → 122**，TNS -162µs → **-125µs**；HDMI 组违例全部消失，最差路径回到 CPU 域既有链。

## 3. 任务三：全面盘点与下一步

| 角度 | 现状 | 判断 |
|---|---|---|
| 资源 | LUT 55.3% / FF 30.1% / BRAM 60.9% / DSP 0 | 健康无需动作 |
| 时序 | HDMI 跨域已清；CPU 域 -3.1ns 为基线既有、板级验证 | 接受并留档；真要收敛需 RTL 重组（盲改风险）或 cart 分域（缓行） |
| 功能 | **SD 快速引擎 CRC 注错回退场景 DATA1 失败**（与改动前逐字一致，确认为既有缺陷） | **唯一已知功能缺陷 → 选定继续** |
| 代码 | hardware_test 壳两个未驱动网络告警（cart_ready_w/lba_rom） | 低优先级 |
| 其他 | +throttle 仿真墙钟超限未跑完 | 低优先级 |

**选定：排查并修复 SD 快速引擎回退路径的 DATA1 失败**——当前树中唯一已知功能缺陷，仿真可闭环
（符合"仿真全过即可"约束），修复后 25MHz 探测失败的卡在首请求回退时不再出错，决赛演示更稳。

## 4. 已执行：DATA1 回退缺陷根因与修复 ✅

### 根因
read#1 诊断 `bytes=8704 (=8192+512) err=8164`：**探测阶段的首扇区 512 字节泄漏进流**。
探测（CMD17 读首扇区）的 CRC 判定在 512 数据字节**之后**；原设计靠 512B FIFO 在判定前扣住
字节（S_CRC 失败分支遗留注释"FIFO 弃之不用"为证），台账 #8 为修跨块竞态删除 FIFO 改单字节
直推后，探测失败时首扇区字节已外流——回退核心重读 16 扇区，消费者收到 512+8192 错位流。

### 修复（sd_multi_reader.v，单时钟域内、零接口变化）
- 新增 `probe_buf[0:511]` 探测缓冲：`probe_phase` 期间 S_DATA 字节写缓冲不置 `byte_pending`
  （判定前不外流，SPI 以自身速率收完 512 字节）；
- S_CRC 判定成功 → 新状态 `S_DRAIN`：512 字节按消费者节奏经 `byte_pending` 握手排水
  （SPI 暂停安全：卡为时钟从机），排空后走原链尾（CS_UP/CMD18/收尾）；判定失败 → 弃缓冲，
  核心重读；
- `stream_data = probe_drain ? probe_buf[probe_ra] : rec_data`。

### 验证（tb_sd_multi 回归矩阵）
| 配置 | 修复前 | 修复后 |
|---|---|---|
| 默认（快速引擎） | ALL PASS | **ALL PASS**（逐字一致）|
| +crcerr（注错回退） | DATA1 FAIL → 总 FAIL | **DATA1 PASS（bytes=8192 err=0）→ ALL PASS** ✅ 首次通过 |
| FORCE_LEGACY=1 | ALL PASS | **ALL PASS** |
| +throttle | 墙钟超限未跑完 | 未变（不在基线）|

### 综合同步（yt_s81 重跑）
LUT 10844→**11425**（+581，探测缓冲 LUTRAM，58.3% 仍健康）；TNS -125µs → **-103µs**；
WNS -3116 → -3261ps（CPU 既有路径随布局漂移 ±145ps，状态不变：73.33M 慢角违例、板级实测正常）；
违例分组复核：仍全部集中在 u_cart/u_cpu，缓冲未引入新违例域。
