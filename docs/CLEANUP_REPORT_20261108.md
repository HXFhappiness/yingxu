# 历史残留清理报告（2026-11-08，YX-8.1 同批）

> 原则：先引用审计（工程 source list、实例化、脚本、文档），后动手；文件级删除一律先进备份目录。

## 已处理

| 对象 | 动作 | 证据 |
|---|---|---|
| `design_top_wrapper.v` 的 `O_inv_wave/O_inv_lives` | **修复**：由常量 0 改接 `hw_wave/hw_lives`（硬件敌机真实状态，底部指示条此前恒灭） | wrapper 实例化了 `yingxu_invaders` 且导出这两个信号，但输出被硬编码 0 |
| `.al` 工程清单中的 `yingxu_breakout.v` 条目 | **移出构建**（磁盘文件保留）。该模块自 D13 起是纯 stub（输出全 0），`design_top_wrapper.v` 无实例化，打砖块走卡带路径 | 全局 findstr：仅 `.al` 清单与历史 docs/HANDOFF 提及；无实例化 |
| `rtl/yx8_cpu.v` | **移入** `cleanup_backup_20261108/yx8_cpu_old_from_rtl.v`。这是缺 `S_WAIT/WAIT_CYCLES/retire/pc_out` 的旧版副本，不在 `.al` 清单中 | `tb/ scripts/ tools/ *.bat *.tcl` 全部零引用 |

## 审计后保留（看似残留，实为在用或契约）

| 对象 | 保留原因 |
|---|---|
| `yx8_cart_soc.v` 内建 test ROM / `test_mode` | 顶层 SW0 仍接 `I_cart_test`，CPU 自测路径 |
| `yingxu_invaders.v` | wrapper 当前正在实例化（硬件/卡带对照） |
| `yingxu_sdram_framebuffer`（WR1/RD1 停用、`S_media_*` 置零） | WR2/RD2 scratch 通路是照片/播放的显示底座；注释明确 vendor 仲裁器对空端口的坑 |
| `yx8_uart_telem`、装载 watchdog、故障快照寄存器 | 顶层仍输出/驱动 LED 与现场诊断 |
| Ethernet/camera/TFT/GPIO/I2C 等安全常量端口 | 管脚约束与双板/外设规划的端口契约，删了要动 IO.adc |
| MJPEG/旧视频链路 | VQ 未板上验收前是唯一可回退的视频路径（见《YX-VP-VQ 设计》S1–S4 验收后再裁） |
| `yx8_prom.v` | 仍在 `.al` 清单但无实例化；本轮未做完整清单重排，列入下轮候选（删除需同步清单 + 备份） |

## 顺带修复的测试基建（非残留，但属本轮发现）

| 对象 | 问题 | 修复 |
|---|---|---|
| `tb/tb_yx8_cosim.v` 取指模型 | 1 拍取指，与现役 CPU/SoC 的 2 拍协议（`raddr_q`+BRAM 寄存输出）不符：JSR/JMP 第二字读错，snake 首条 JSR 跳到 0x10A | 改为 2 拍取指（`addr_q`），与 SoC 逐拍一致 |
| 同上，LFSR 推进 | 未用 `retire` 门控，2 拍取指下预取拍 `is_ldr` 已有效 → 每次读 RAND 推进两次（breakout 等读随机数卡带必分叉；snake 不吃食物才侥幸通过） | 加 `dut.retire` 门控，与 `yx8_cart_soc.v` 的写法一致 |
| 同上，`0xFD` | 平台模型缺 CAPS | 增加 `8'hFD → 8'h01`（与 SoC `cap_yx81=1` 一致） |
| `yx8_cpu.v` 的 ROL/ROR（0x1A/0x1B） | RTL 用普通移位器，与冻结规范 v1.1.2（"ROL/ROR 为 8 位循环"）及模拟器不一致；仅 torture 系列暴露，板级卡带零使用（已 grep .lst 确认） | 新增显式 8 位循环移位器，C=移出位，与 `yxem.py` 逐位对齐 |

## 验证

- 改造前后各 13 个卡带源码重编 **BYTE-MATCH**；15 条模拟器黄金轨迹指令数逐一相同。
- `ENABLE_YX81=1` RTL 共生：**15/15 卡带 + yx81test（50 条指令）全部零差异**。
- 全过程未烧录；综合构建见 `out/yx81_build_log.txt`（资源/时序结果另行汇报）。
