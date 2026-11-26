# 状态交接 — 2026-10-26 08:50

## 一句话

**v2 网表 SD 初始化失败（与模式无关、与种子无关、与资源无关），R85 同板同卡正常。SD 模块与约束已证明与 R85 完全一致，差异只能在顶层文件。**

## 已排除

| 假设 | 证据 |
|---|---|
| 卡/硬件坏 | 烧 R85（D:\yingxu_work\p1_dbg\release\V0.4C-R85_HEARTS.bit）→ LED0 亮 |
| 卡带数据错 | 卡上绝对 LBA 1,000,000 回读 = `YXCA` + ver1 + 209 字 + 无数据段，格式正确 |
| 写卡地址错 | `write_cart.py` 用 `rel = lba - off` 落绝对地址，与 `CART_LBA` 一致 |
| 资源超限 | v2 仅 3,455 LUT（17.6%），R85 为 8,420（43%） |
| 种子抽签 | 39/29/32/35 四个种子全灭 |
| 模式相关 | 照片模式（SW7 OFF）与卡带模式都不亮 |
| SD 模块/约束被改 | `sd_card_control/sd_init/spi_driver/sd_stream_reader*/probe/bmp_loader/video_player` 与 `IO.adc/timing.sdc` **哈希全部一致** |

## 当前板上

- 最新构建（seed 32，含两处修改）：
  1. `led[0] = ~sd_seen`（原为 `~sd_dbg_init_done`，会在任何事务开始后熄灭，造成误判）
  2. `yx8_cart_soc.v` 的 `L_HDR` 增加 `hdr_idle` 看门狗，每 32768 拍重拉 `restart_pend`
- 现象：LED0 不亮（`sd_seen` 从未置位）

## 下一步（按顺序）

1. **逐段 diff 顶层 SD 段落**（不是整文件，行数 824 vs 1770 差异太大）：
   - v2:   `C:\Users\HXF\Desktop\YX\hardware_test_P0_UART_V5_CRC32.v`
   - R85:  `D:\yingxu_work\p1_dbg\release\src_R85\hardware_test_P0_UART_V5_CRC32.v`
   - 重点函数块：`por_cnt` / `flush_*` / `sd_retry_*` / `busy_kill` / `sd_rst` / `sd_seen` / probe 实例端口
   - **建议方法**：抽出每个 always 块的完整代码，逐块贴出来对齐比较（不要用行过滤，会漏掉块内差异）

2. 重点怀疑点：
   - `sd_rst` 的 5 个来源中，`busy_kill` 是否可能被卡住（`busy_kill != 4'd0` 会把探针永久按在复位）
   - `flush_active` 的结束条件（`flush_clks` 是否真的走到 `FLUSH_CLKS`）
   - 探针实例的 `.rst` / `.clk` / `.restart` 端口连接是否与 R85 一致

3. 快速实验（若 diff 找不到）：在 v2 顶层临时把 `sd_rst` 改成 `~rst_n | !por_done | flush_active`（去掉 `sd_retry_pulse`/`busy_kill` 两项），看 LED0 是否点亮 → 直接定位是哪一项。

## 参考

- R85 完整快照（能启动的参照）：`D:\yingxu_work\p1_dbg\release\src_R85\`
- 构建（项目流程，勿用 in-process）：`cmd /c "td_commands_prompt.exe < out\v3_proj_build.tcl > log 2>&1"`
- 烧板：`download -bit <种子bit> -mode program_spi -v -spd 7 -cable 0 -flashsize 128`
- 种子目录：`AC201_AL_board_test_Runs\phy_1\seed_28..39 / 70..77`
