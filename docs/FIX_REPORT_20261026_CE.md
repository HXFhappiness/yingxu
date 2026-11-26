# 映序 YingXu — SD 子系统修复完成报告
日期: 2026-10-26 | 板卡: EG4S20BG256 (AC201) | TD 6.2.210.850

## 结果
- **v2 SD 子系统在板上完全工作**: SD 初始化成功 + 5401 扇区 (2,765,312 字节) 完整读取 + **HDMI 正常显示 BMP 图像, LED0 亮**（用户确认）。
- 最终构建: **build8**（最优 seed_29），TEMP 遥测已移除。STA 覆盖率 **94.89% → 98.42%**。
- bit 文件: `AC201_AL_board_test_Runs\best_result\AC201_AL_board_test.bit`（已烧录，program_spi -spd 7，校验通过）。

## 根因
厂商 `clk_div_var` 生成 fabric 伪时钟 `clk_out_var`（spi_clk）驱动数百个 SD 链触发器；TD STA 从不分析该时钟（覆盖率 94.89%，时钟列表只有 clk0–3）。跨种子表现为状态机错过 1 周期 done 脉冲（seed_33 卡 INIT=1、seed_28 卡 INIT=4、seed_31 卡 RD=1）。

## 修复
1. **ce 重写（核心）**: 12 个 `media/sd` 文件全部改挂真实 50MHz sys clk，用 clock-enable (`spi_en_rise = spi_en & ~spi_en_d`) 门控每个非复位触发器更新；每个 ce 周期 ≡ 一个旧伪时钟周期，语义严格等价（done/rec 脉冲宽度、sclk 403kHz/6.25MHz 分频比均不变）。原始链备份于 `media/sd_pre_ce_backup/`。
2. **probe 遥测假阳性修复**: `dbg_accept_count` 11 位 → 22 位（5401×512=2765312 需要 22 位），ERR=1 消除。
3. **TEMP 遥测移除**: U_TELEM、pad_mise_cnt/pad_sce_cnt 删除，uart_tx 恒高。

## 仿真验证 (iverilog -g2012, workspace sim_ce/)
- **TB1 等价测试**: 新链 vs 原链（o_ 前缀）同激励（LFSR miso），事件级对比: 149 个 MOSI 字节、71 个 init 状态事件、2397 sclk 边沿、24 次 CS 切换 — **完全 MATCH**。
- **TB2 端到端**: 新链 + mode-3 SPI SD 卡行为模型（响应从命令后第 2 字节槽起，与板上 RSP=00FFFFFFFF 遥测一致）— **E2E PASS**（init_done=1，512 字节数据逐字节校验通过）。原链同模型亦 PASS（RTL 无时序）→ 证实板级失败为时序性。
- 附带发现: 厂商默认 SPI_HIGHFREQ=25MHz → div=1 会使 clk_div_var 死锁；probe 已覆盖为 6.25MHz（div=4），板上 DIV=04 一致。

## 板级遥测（build7/seed_36，移除前）
`SEEN=1 BUSY=0 ERR=0 DNE=1` + `CTRL=4 RD=0 CSN=1` + `OFF=0x2A3200`（5402×512，含一轮完整重读）— 读阶段全部完成。

## 遗留说明
- clk3 (366MHz HDMI) WNS≈-0.56ns 为既有已知项，与本次修复无关。
- 新链相对原链每伪周期统一滞后 1 个 sys 周期（恒定、不累积）。
- iverilog 不接受厂商 cnt.v 的 `var` 标识符与不定宽拼接 — 仅仿真副本修补，源文件未动。

## G4 卡带模式诊断记录 (2026-10-26 下午)
- 现象: 卡带模式 LED1 常亮 (loader 卡死), 只有星空。
- 已排除: restart 脉冲被 ST_IDLE 吞 (tb_cart_pulse.v 仿真 PASS: init_done 后 1-cycle 脉冲正常触发整扇区读);
  sel_cart/cart_active 极性不一致 (两处同为 game_mode && sel==2); busy_kill (20s > 3.5s 读); sd_retry (仅 !sd_seen)。
- **测试盲区实锤**: tb_cart_soc.v 在加载器端口直接注入字节流 (`always @(posedge cart_restart)` 直接吐字节),
  完全绕过 probe/core/SD 链 — 所以"仿真 PASS"从未覆盖过真实卡带加载路径。
  新纪律: 卡带路径验证必须走 probe 级 TB (sim_ce 系列 + 卡模型), 端口级注入只允许测加载器内部 FSM。
- 遗留隐患: v2.1 重写时 hdr_idle 看门狗被删 — cart 的 restart_pend 是单周期脉冲, 若发射瞬间 core busy
  (如刚从照片模式拨到卡带模式, 上一笔读仍在跑), 脉冲被 `~dbg_busy` 吞掉 → cart 永久卡 L_HDR。
  修复方向: probe 内 latch restart (restart_hold 直到 reader_start 消费) — 一处修复, 客户端无需改动。
- build9 (seed 34, 遥测恢复) 已烧录, 卡带模式 COM4 遥测采集中。
