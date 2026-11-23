# YX_BBOARD_P5_SYN_20261124 — B 板首次 TD 综合结果与诊断

> 状态：首份综合完成（**未生成 bit、未烧录**）。红线（时钟名核对）**通过**；
> 资源与时序不合格，根因已定位到下两级模块。
> 运行时间：2026-11-24 02:04 起；基于当时**工作区**状态（含尚未提交的
> P5 RTL 修改，见 §1.2）。

## 1. 运行方式

### 1.1 命令行（TD Release_2026.2 / 6.2.3.210850）

```tcl
# run_b_syn.tcl
import_device eagle_s20.db -package EG4S20BG256   ;# 必须在 open_project 之前
open_project {AC601_B_VQ_p5.al}
reset_runs { syn_1 }
launch_runs { syn_1 } -jobs 4
wait_run syn_1 -quiet
```

```powershell
cd /d D:\yingxu-repo
"D:\Anlogic\TD_Release_2026.2.210.850\bin\td_commands_prompt.exe" "C:/…/run_b_syn.tcl"
```

**两个坑（都踩过）**：

1. **脚本路径必须用正斜杠**——反斜杠会被 TD 吃掉（`C:UsersHXF…` → 找不到文件）。
2. **`import_device` 的器件名是位置参数，且要写设备库文件名**：
   正确写法 `import_device eagle_s20.db -package EG4S20BG256`；
   写成 `import_device EG4S20BG256 -package BG256` 会报 `USR-8001 Invalid device_db name`；
   省略则在 `settings.cfg` 里留下空的 `device_name`，run 直接失败
   （`PRJ-8001 can't read "device_name"`）。
   正确值来源于 A 板已有 run 目录：
   `AC201_AL_board_test_Runs\syn_1\settings.cfg`。

### 1.2 本次综合针对的代码状态（未提交）

| 文件 | 说明 |
|---|---|
| `src/user_source/hdl_source/media/vp/yingxu_vq_board_b.v` | 新增：板级包装顶层（只暴露板级引脚，内部以 SIM_ABSTRACT=0 例化 `yingxu_vq_board_top`，并带"缺宏即报错"守卫） |
| `src/5640/sdram_ctrl_4p/b_board/Sdram_Control_4Port_b.v` | 新增：B 板自持的控制器副本（模块名 `Sdram_Control_4Port_B`） |
| `src/5640/sdram_ctrl_4p/b_board/Sdram_RD_FIFO_b.v` | 新增：`Sdram_RD_FIFO_B`（CDC=1、AF_W=300） |
| `src/user_source/hdl_source/media/vp/yingxu_vq_board_top.v` | 修改：WR1 排空判据由"读 FIFO 内部指针"改为"数 WR1 突发完成次数"（`mWR_DONE & WR_MASK[0]`，10 次 = 2560 字） |
| 其余 | `yx_b_scanout*.v` / `yx_vp_band.v` / `yx_vp_ixbuf.v` / `yx_vp_ixdec.v` / `timing_b.sdc` / `AC601_B_VQ_p5.al`（加入宏定义）/ TB 与 runner |

> 注：此前 `HDL-8007 'SAMEDOM' is not declared under prefix 'logic_fifo'`
> （顶层穿透厂商 FIFO IP 内部的层次引用）已由此修复，分析阶段现为**零 ERROR、
> 零 CRITICAL-WARNING，30 个源文件全部解析成功**。

## 2. 红线：时钟名核对 —— 通过

`report_qor -step gate` 输出的实际时钟（见 `*.qor` 的 Logic Level Distribution 表）：

| 实际时钟 | 周期 | `timing_b.sdc` 的 glob | 结论 |
|---|---|---|---|
| `b_ref_clk_50m` | 20.000 ns (50 MHz) | 同名 | ✓ |
| `b_eth_rxc_125m` | 8.000 ns (125 MHz) | 同名 | ✓ |
| `u_top/u_sdram/sdram_pll1/pll_inst.clkc[0]` | 10.000 ns (100 MHz) | `*sdram_pll1*clkc[0]` | ✓ |
| `u_top/u_sdram/sdram_pll1/pll_inst.clkc[1]` | 10.000 ns (100 MHz) | `*sdram_pll1*clkc[1]` | ✓ |
| `u_top/u_hdmi_pll/pll_inst.clkc[0]` | 10.000 ns (100 MHz) | 未引用（闲置） | — |
| `u_top/u_hdmi_pll/pll_inst.clkc[1]` | **13.643 ns (73 MHz)** | `*u_hdmi_pll*pll_inst*clkc[1]`（像素域） | ✓ |
| `u_top/u_hdmi_pll/pll_inst.clkc[2]` | **2.727 ns (366 MHz)** | `*u_hdmi_pll*pll_inst*clkc[2]`（串行域） | ✓ |

**结论**：`clk1_out → clkc[1]`、`clk2_out → clkc[2]`，与 SDC 假设一致，
**不需要修改 `timing_b.sdc` 的 glob**。此前担心的"clk1_out 落到 clkc[0] 导致
异步组声明错对象"没有发生。

## 3. 资源：超容量 248%（不合格）

`AC601_B_VQ_p5_gate.area`：

```
#lut      48777 / 19600 = 248.86%     ← 超标 2.49 倍
#reg       3089 / 19600 =  15.76%
#bram        45 /    64 =  70.31%
#bram9k      38        （另 fifo9k 7）
#dsp          2 /    29 =   6.90%
#pll          2 /     4 =  50.00%
#io          17 /   188 =   9.04%
```

### 层级分解（按 LUT 排序）

| 实例 | 模块 | LUT | seq | BRAM |
|---|---|---:|---:|---:|
| `top` | `yingxu_vq_board_b` | 48193 | 3099 | 45 |
| `u_top` | `yingxu_vq_board_top` | 47420 | 3089 | 45 |
| **`u_band`** | `yx_vp_band` | **20474** | 145 | **30** |
| **`REAL_IX$u_ethrx`** | `yx_b_eth_rx` | **16260** | 661 | 0 |
| ├─ **`u_bfifo`** | **`yx_b_afifo`** | **15710** | 132 | 0 |
| ├─ `u_dfifo` | `yx_b_afifo` | 96 | 47 | 0 |
| └─ `u_mac` | `eth_udp_rx_gmii` | 343 | 409 | 0 |
| `u_hdmi_core` | 加密 HDMI 核 | 849 | 1005 | 8 |
| `REAL_IX$u_ixfetch` | `yx_b_ix_fetch` | 151 | 111 | 0 |
| `REAL_IX$u_hdr` | `yx_b_hdr_parse` | 102 | 114 | 0 |
| `REAL_IX$u_ixwr` | `yx_b_ix_seq_wr` | 78 | 44 | 0 |

### 根因判断

1. **`u_bfifo` = 15,710 LUT，且 BRAM 占用为 0** —— 这是 `yx_b_eth_rx` 内的
   异步双时钟字节 FIFO（`yx_b_afifo`），被综合成**分布式逻辑而非 BRAM**。
   按 ~15 LUT/字推算，深度在 1024 字量级。
   → 单个 FIFO 吃掉 80% 器件预算。

2. **`u_band` = 20,474 LUT + 30 BRAM** —— 行缓冲已用 30 块 BRAM，却仍有 20K LUT，
   说明 `ln` 的多读口需求（2 个扫描读口 + 渲染读写口）导致 BRAM 复制不足、
   部分路径退化到 LUT 实现。

3. 其余模块（hdr/ixfetch/ixwr/dram/hdmi_core）合计 < 1,200 LUT，**不是问题**。

## 4. 时序：不合格

```
Setup WNS        = -2652 ps
Setup TNS        = -7797502 ps
违例端点         = 3095
```

| 时钟 | over-quota 路径 | 最差 slack | 路径特征 |
|---|---:|---:|---|
| `b_eth_rxc_125m` | 2054 | **-2652 ps** | `SEQ,LUT5,LUT4,ADDER,ADDER,ADDER,ADDER,LUT4,LUT2,LUT4,LUT2,DRAM` |
| `u_top/u_sdram/…clkc[0]` | 1024 | -2306 ps | `SEQ,LUT4,LUT5,…,DRAM` |

125 MHz 域的关键路径里连续出现 4 个 ADDER —— 与 LUT 版 FIFO 的指针/计数逻辑吻合。
**修好 FIFO→BRAM 后这条大概率一并消失**；100 MHz 域的 1024 条需单独看。

## 5. 修复优先级（建议）

| 优先 | 动作 | 预期 |
|---|---|---|
| **P0** | `yx_b_afifo` 改用 BRAM 实现：仿真保留行为模型，综合走 `ifdef SYNTHESIS` 切到 `EG_LOGIC_FIFO`（厂商双时钟 FIFO 原语，与控制器内部一致）或显式双时钟 FIFO IP | 省 ~15,000 LUT（248% → ~172%）；125 MHz 域时序大概率转正 |
| **P1** | `u_band` 行缓冲：评估 `ln` 的读口能否改为"1 写 + 1 读 + 时分复用"，或显式 BRAM 复制（BRAM 尚余 19 块） | 目标再省 10,000~20,000 LUT |
| **P2** | 上述两项落地后重跑 syn，再评估 100 MHz 域的 1024 条 over-quota | — |

> 目标：`#lut` 降到 19,600 以下（最好 ≤ 17,000 留 10% 余量），WNS ≥ 0。

## 6. 复现命令

```powershell
cd /d D:\yingxu-repo
# 1) 确认加密核在位（被 gitignore，需本地提供）
Test-Path src\user_source\hdl_source\hdmi1.4b_transmitter_core\hdmi_1_4b_transmitter_core_wrapper.enc.v
# 2) 综合（脚本见本文件 §1.1）
"D:\Anlogic\TD_Release_2026.2.210.850\bin\td_commands_prompt.exe" "C:/…/run_b_syn.tcl"
# 3) 看结果
Get-Content AC601_B_VQ_p5_Runs\syn_1\gate.qor
Get-Content AC601_B_VQ_p5_Runs\syn_1\AC601_B_VQ_p5_gate.area
```

## 7. 说明与局限

- 以上为 **gate 阶段（综合后）** 数字，非 place/route 最终值；但 248% 的量级
  不可能靠 P&R 收回，问题必须先在上游解决。
- 本次未跑 `phy_1`，未 `save_best_bits`，**未产生 bit、未烧录**。
- `.qor` / `.area` / `*_Runs/` 均在 `.gitignore` 内，不入库；需要时按 §6 重跑。
