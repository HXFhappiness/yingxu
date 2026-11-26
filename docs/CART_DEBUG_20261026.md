# 卡带调试记录 — 2026-10-26 夜

> 结论先行：**卡带程序现在能完整写进 FPGA 的程序 RAM 了**（板上回读到真实指令），
> 但 CPU 执行几条指令后就飞出程序区，精灵一次都没提交。剩余问题定位到 CPU 执行层，尚未解决。

---

## 1. 已确认可用的（板上实测）

| 项 | 证据 |
|---|---|
| 卡带模式激活 | `GM=1 CA=1`，SW7+SW5 ON（`SW=5F`，OFF=1 已标定） |
| SD 读卡带区 | `OFF=0x2A3200` = 5401×512，一次完整读；`MISE=1` 无反复重试 |
| 头部解析 | `LS=4 (L_DONE)`，`WC=0x1B3=435` 词（= invaders 代码量） |
| **程序写入 RAM** | 板上回读 `I0=511200` = invaders 第一条 `JSR init` ✅ |
| 仿真全链路 | 同一 RTL 在 iverilog 里：精灵提交 28978 次、`ram0=511200 ram2=512B00` |

## 2. 失败现象

```
D MISE=0001 SCE=0012 SW=5F LS=4 WC=1B3 BU=0 SP=0000 F=F PC=212 DW=0000 I0=511200
```

- `SP=0`（精灵提交 0 次）、`DW=0`（CPU 数据写 0 次）→ 游戏逻辑一条都没执行
- `PC` 稳定停在 `0x210–0x216`，偶尔 `0x013`
- `0x212`（=530）**超出本程序 435 词的范围** → RAM 该处为 0 → 全 0 是 NOP，不应形成回环
- 屏幕上只有 tile 星空背景

## 3. 本轮修掉的真 bug（都已上板验证有变化）

1. **`restart_pend`/`prog_we` 从不清零** → 卡带每 ~4 s 无限重读。改为自清零脉冲。
2. **看门狗 4 s 且不可仿真** → 参数化 `WD_CYCLES`，板上一版 0.5 s。
3. **程序 RAM 跨时钟写被工具吃掉**（写口 sys_clk / 读口 pix_clk，TD 推断后未生效，板上回读全 0）
   → 改为 **8 深度 34 位异步 FIFO**（地址+数据一起过界），pix_clk 单时钟写 RAM。**这一条让 `I0` 从 000000 变成 511200。**
4. **UP 上传 FSM 在 loaded 后立刻读 meta 字**，此时 FIFO 里的 meta 还没落盘 → 加 16 拍 settle 延迟。
5. 回读 mux（`addra = loaded_s ? 0 : prog_waddr`）曾把 meta 字写到地址 0 → 端口 A 只做写，回读改用"第一取指锁存"。

## 4. 夜里新增的关键发现：程序字被"丢包"

在仿真里逐词比对 RAM 与卡带镜像（`tb_pc_mon2.v` 的 `BADC0UNT` 检查）：

```
MISMATCH word 4: ram=000000 expect=513b00
MISMATCH word 14 / 19 / 24 / 29 ...
BADC0UNT=85 of 435      FIFO_FULL_CYCLES=390
```

**85/435 个词丢失，且呈周期性（每 5 个丢 1 个）**，因为：
探针把整扇区的 512 字节**按 50MHz 连续吐出**（不是每 1.28 µs 一个），
而程序字 FIFO 每 2 拍才排一个（27 ns），写入侧 3 字节一个词（60 ns）——
短时突发下 FIFO 满，`prog_we` 被 `!fifo_full` 直接丢弃。

这解释了板上的一切现象：**词 0 正确（所以 `I0=511200`），但后续词残缺 → CPU 执行到缺口就飞**。

### 试过但失败的做法
把 `O_bmp_sd_ready` 与卡带 FIFO 的"快满"信号相与（流控反压）→ 板上变成 `WC=000, LS=4`，
头部直接被判非法。原因：`sel_cart` 在 wrapper 里是**先用后声明**，TD 会为它隐式建一个
1 bit 线网，门控表达式实际拿到的是未驱动的隐式网，行为不可预期。已回退。

### 明天要试的正确做法（三选一，按推荐度）
1. **字节级深 FIFO**：给 SD 字节流做 512 深度异步 FIFO（正好一扇区），加载器在 pix_clk
   域按电平消费；程序 RAM 与加载器同域，不再需要程序字 FIFO。这是最干净的架构。
2. **正确实现反压**：把 `sel_cart` 与 `cart_ready` 显式声明在 wrapper 顶部（不依赖隐式网），
   再与 `bmp_sd_ready` 相与；同时验证探针在 ready 拉低时确实保持数据不推进。
3. **显式厂商 RAM 原语**（如 SDP_RAM9K）：彻底摆脱推断不确定性。

## 5. 现在的遥测字段（build22）

D 行：`MISE SCE | SW=<开关原始字节> LS=<加载器状态> WC=<词数> BU=<忙> SP=<精灵提交数> F=<{cpu_on,up_done,loaded,en}> PC=<cpu_next_pc> DW=<CPU 写次数> I0=<第一取指>`

LED（在卡带模式下）：`LED0=SD已初始化 LED1=加载中 LED2=收到过字节 LED3=帧计数翻转`
（注：LED3 是帧计数器 `frame_cnt[4]`，**不是** CPU 心跳——早期文档这条写错了）

## 6. 仿真工装（可直接复用）

`C:\Users\HXF\Documents\deepseek-harness\default-workspace\sim_ce\`
- `tb_pc_mon2.v`：喂 invader.yxc（`cart.bin`）→ 打印 PC/指令/精灵提交/CPU 写次数
- 自带 **`BADC0UNT` 逐词比对**（RAM vs 卡带镜像）与 `FIFO_FULL_CYCLES` 探针
- 编译：`iverilog -g2012 -o tb.vvp tb_pc_mon2.v _zi.v _fm.v c_sim_cart_soc.v c_sim_cpu.v clk_div_var.v cnt.v ram_dual_port_simple.v`
  （`_zi.v` 把 RAM 预置 0 排除 X 传播，`_fm.v` 统计 FIFO 满拍数）


## 7. 下一步（按性价比排序）

### A. 先做最小自检卡带（不需要重新综合，只写卡）
`cartridges/test_draw.asm`（21 词）已备好：只提交一个 200×100 青色方块到槽 3，然后死循环。
- 若 `SP` 变 1、屏幕出现方块 → **CPU+RAM+IO 通路是好的**，问题在 invaders 程序本身（回到汇编层查）
- 若 `SP` 仍为 0 → 通路坏在 CPU 执行/取指，转 B

⚠️ 卡现在在 PC 读卡器之外（E: 盘消失），写卡前需要物理插回。

### B. 若 A 失败，查三处（按怀疑度；夜里已确认丢包，优先做 §4 的三选一）
1. **CPU 的堆栈 RAM**：`yx8_cpu.v:53 reg [15:0] stack [0:63]` 用组合读 `stack[sp_m1]`；
   若 TD 把它推成同步读 BRAM，`RTS` 会取到错地址 → PC 飞。检查 `syn_1/run.log` 里 `stack` 的 RAM 提取类型，必要时改为显式 LUTRAM 或加寄存器读+一拍对齐。
2. **取指时序**：`instr` 是 RAM 的**寄存输出**（`doutb <= ram[addrb]`，`addrb = cpu_next_pc`）。
   仿真里能跑通，但硬件 BRAM 的"地址→数据"延迟若与仿真模型差一拍，就会整体错位。
   验证方法：把 `instr` 换成组合读（改 RAM 为 `assign doutb = ram[addrb]`，仅用于验证）。
3. **`dwe` 是电平不是脉冲**：`assign dwe = is_str;` 只要译码到 STR 就为高，
   在 S_F2 状态也可能为高 → 可能对同一指令写两次。检查是否需要 `& (state==S_RUN)`。

### C. 兜底
11.2 冻结前若仍不通：以**照片模式 + YX-8 CPU/汇编/卡带体系**为参赛主体，
卡带游戏用**模拟器实机录像**呈现（模拟器里两款游戏都已通关，可出完整演示视频）。

## 8. 当前板子状态

- 固件：build22（seed 36，已回退到"能完整加载"的版本），**照片模式正常工作**（SW7 OFF）
- 卡带模式：能加载、不能执行（如 §2）
- 卡上内容：LBA 1,000,000 = invaders.yxc（435 词）；LBA 1,001,000 = invaders.yxc 旧版本
  （breakout 已被覆盖，需要时用 `tools/write_cart.py` 重写）
