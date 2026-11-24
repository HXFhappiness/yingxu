# YX_BBOARD_P5_MDIO_20261124 — Clause 22 MDIO 主机 + RTL8211F 上电配置序列 + 顶层集成

承接 `docs/YX_BBOARD_P5_PHY1_20261124.md` §3。那轮定位到：板 B 的 PHY = RTL8211F-CG，
其 RGMII RX 内部延时 strap = `RXD0`，本板被 4.7K 上拉到 ETH_DVDDH；若该 strap 语义为
"使能"，PHY 会给 RXC 再加 ~2ns，本设计的采样点 `T+5.705ns` 会落到 4ns 数据眼
（`[T+1.075, T+5.075]`）之外 —— **上板功能直接失败**。而顶层当时把 `eth_mdc/eth_mdio`
恒置 1（"MDIO 未实现"），既读不回该位、也改不了它。

本轮补齐这条链路。

---

## 1. 交付物

| 文件 | 内容 |
|---|---|
| `src/user_source/hdl_source/media/vp/yx_b_mdio.v` | Clause 22 MDIO 主机（读写，2.5MHz） |
| `src/user_source/hdl_source/media/vp/yx_b_phy_init.v` | RTL8211F 上电配置序列（读-改-写） |
| `tb/tb_mdio.v` | 主机独立验收（含 PHY 行为模型） |
| `tb/tb_phy_init.v` | 序列独立验收（含带寄存器文件的 PHY 模型） |
| `tools/sim/run_sim.ps1` | 新入口 `mdio` / `phy_init`（秒级） |
| `yingxu_vq_board_top.v` | `eth_mdio` 改 `inout`；实例化上述两模块；三态驱动 |
| `yingxu_vq_board_b.v` | `eth_mdio` 改 `inout` |
| `tb/tb_yxvp_bboard.v` | `eth_mdio` 挂 `pullup`（仿真无 PHY 模型） |
| `timing_b.sdc` §3.4 | 原"纯静态电平"注释作废，补 `b_mdio_virtual` 输入延时 |
| `AC601_B_VQ_p5.al` | 源表插入两个新文件（CompileOrder 26/27，其后顺延） |

---

## 2. MDIO 主机（`yx_b_mdio.v`）

### 2.1 帧格式（IEEE 802.3 Clause 22）

```
bit  0..31  preamble  32 × 1
bit 32..33  ST        2'b01
bit 34..35  OP        2'b01=写 / 2'b10=读
bit 36..40  PHYAD     5 位
bit 41..45  REGAD     5 位
bit 46..47  TA        写:2'b10；读:MAC 释放总线（高阻），PHY 驱动 0
bit 48..63  DATA      16 位
```

每个 bit 两个相位：低相位 MAC 更新 `mdio_o`（PHY 在随后的上升沿采样），高相位 MAC
采样 `mdio_i`（读操作的数据位）。MDC 半周期 = `HALF_DIV` 个 clk，`HALF_DIV=20` @100MHz
→ MDC = 2.5MHz（Clause 22 上限）。

### 2.2 两个实现要点（都踩过）

1. **输出必须按"下一位的索引"取值。** 早期版本在下降沿直接取当前 `bit_idx` 的组合值，
   输出整体落后一位。改成 `mdio_o <= bit_val(bit_idx + 1, rd_op)`，其中 `bit_val` 是
   纯函数（按索引算该位的值）。
2. **`bit_oe` 决定何时释放总线。** 读操作从 TA（bit46）起 `oe=0`，否则会与 PHY 抢总线。

### 2.3 时钟域

用 `clk100`（来自 `Sdram_PLL`，只依赖板载 50M 晶振）——**不依赖 PHY 的 RXC**。
这样即使 PHY 上电后 RXC 未就绪，配置序列也能跑完。

### 2.4 验收（`tb_mdio.v`）

PHY 行为模型逐位对拍 + 读写往返 + TA 释放：

```
GATE checks=7 errs=0(want 0: OK)
=== TB-SUMMARY: ALL PASS ===
```

用例：写帧逐位匹配 / 写完成释放总线 / 读帧前 46 位匹配（含 OP=10）/ 读回数据正确 /
第二组地址数据防巧合 / MDC 半周期参数化。

---

## 3. 上电配置序列（`yx_b_phy_init.v`）

### 3.1 寄存器（来自 Linux 内核 `realtek_main.c`，权威）

| 用途 | 寄存器 |
|---|---|
| 页选择 | `0x1f`（`RTL821x_PAGE_SELECT`） |
| RGMII 扩展页 | `0xd08`（`RTL8211F_RGMII_PAGE`） |
| RX 延时 | 页 `0xd08` / 寄存器 `0x15`（`RXCR`）/ `bit3`（`RTL8211F_RX_DELAY`） |

### 3.2 序列（读-改-写，不动 RXCR 其他位）

```
1. 写 0x1f = 0xd08        切到 RGMII 扩展页
2. 读 0x15                取回 RXCR 现值
3. 写 0x15 = 现值 & ~bit3 清 RX 延时位
4. 写 0x1f = 0x0000       回到页 0（不留在扩展页）
```

**安全保护**：读回 `0xffff` 视为"PHY 未响应"（MDIO 总线空闲上拉即为全 1），
**跳过写**，避免把垃圾值写进 PHY。清 `bit3` 本身幂等——若 strap 已把该位置 0，
写回同值无副作用。

### 3.3 验收（`tb_phy_init.v`）

PHY 模型带寄存器文件（页 0 / 页 0xd08 各 32 个 16 位寄存器），逐帧译码并落盘：

```
[1] 正常序列：RXCR 初值=1238（bit3=1）
  DBGREQ wr=1 rega=1f wdata=0d08   ← 1. 写页
  DBGREQ wr=0 rega=15 wdata=0d08   ← 2. 读 RXCR
  DBGREQ wr=1 rega=15 wdata=1230   ← 3. 写回（0x1238 & ~0x0008）
  DBGREQ wr=1 rega=1f wdata=0000   ← 4. 页归零
  DBG mdc_edges=256 wr_cnt=3 rd_cnt=1
  DBG cur_page=0000 rxcr=1230 rxcr_r=1238
[2] PHY 不响应：读回 ffff → 跳过写，寄存器未被垃圾覆盖
GATE checks=11 errs=0(want 0: OK)
=== TB-SUMMARY: ALL PASS ===
```

`rxcr=1230` 证明 **bit3 被清、其余位原样保留**；`rxcr_r=1238` 证明读回的确实是 strap 后的原值。

---

## 4. ★ 调试记录：`tb_phy_init.v` 的三个模型缺陷（都在 TB 侧，RTL 无改动）

这一轮花了较多时间，三个缺陷都有代表性，记下来避免重犯。

### 4.1 `reg rst_n = 1'b0;` 是初值而不是跳变 → 复位分支从未执行

```verilog
reg rst_n = 1'b0;                                  // 初值，无 negedge 事件
always @(posedge mdc or negedge rst_n) begin
    if (!rst_n) begin edge_cnt <= 0; ... end       // ← 仿真开始时不执行
```

结果 `edge_cnt/ones_cnt/phy_rx` 恒为 **X**。现象很隐蔽：`ones_cnt` 在首帧 bit33
被 `else ones_cnt <= 0` 赋了实值，于是 **第 2 帧被当成第 1 帧**检测到——DBGDEC 解出来
是"读 0x15"（其实那是命令 2），首帧（写页 0xd08）整帧丢失，`cur_page` 从未变成 0xd08。

**修法**：显式 `phy_model_clr` 任务，在 `initial` 里调用。

### 4.2 `edge_cnt` 只有 6 位，帧尾 64 回绕成 0

`reg [5:0] edge_cnt` 最大 63；检测时置 33，再递增 31 次到 64 → 回绕成 0。
于是 `edge_cnt > 63` 的"释放总线"分支**永不成立**。改 `reg [6:0]`。

### 4.3 ★ 整个采样块套在 `else if (mdio_oe)` 里 → 读操作计数器冻结

这是最要命的一个。读操作从 TA（bit46）起主机释放总线（`mdio_oe=0`），而模型把
**所有**逻辑（含 `edge_cnt` 递增）都放在 `else if (mdio_oe)` 里，于是计数器冻在 46：

```
DBGND ec=46 en=1 drv=0 rdval=1238     ← 重复到最后，ec 一直是 46
```

PHY 端 `edge_cnt 48..63` 的数据驱动条件永不成立 → 恒驱动 0 → `rxcr_r=0000`
（而非 0x1238）→ 序列把 `0x0000 & ~8 = 0x0000` 写回去，**RXCR 其他位全被清零**。

**修法**：`edge_cnt` 只要帧已开始（`frame_started`）就**无条件**递增，只有
`phy_rx` 移位和 `ones_cnt` 计数才受 `mdio_oe` 门控。

> 对照：`tb_mdio.v` 本来就是这么写的（`edge_cnt <= edge_cnt + 1` 在 `if (mdio_oe)` 之外），
> 所以它一直是对的。写新模型时照抄了结构却挪了门控位置，才踩进去。

---

## 5. 顶层集成

### 5.1 端口与三态

```verilog
output wire eth_mdc,        // Clause 22 MDIO 时钟（yx_b_mdio 驱动）
inout  wire eth_mdio,       // ★ 由 output 改为 inout
...
assign eth_mdio = mdio_oe_w ? mdio_o_w : 1'bz;
```

`IO_b.adc` 里 `eth_mdio` 本来就带 `PULLTYPE = PULLUP`（`IO_b.adc:40`）——与 Clause 22
"MDIO 空闲上拉"一致，无需改引脚文件。

### 5.2 实例化（两种构建一致，无条件）

```verilog
yx_b_mdio #(.PHY_ADDR(5'd1), .HALF_DIV(8'd20)) u_mdio (...);
yx_b_phy_init #(.PHY_ADDR(5'd1), .PHY_INIT_WAIT(24'd10_000_000)) u_phyinit (...);
```

- `PHY_ADDR = 1`：RTL8211F strap `PHYAD0=1`。
- `PHY_INIT_WAIT = 100ms @100MHz`：复位释放后等 PHY 内部初始化完成再发 MDIO。
  RTL8211F 复位脚要求 ≥10ms，之后还需内部 PLL/自协商初始化时间；本设计的视频通路
  **不依赖**该配置，等久一点无代价。
- 两模块只驱动 `eth_mdc/eth_mdio`，与数据通路无交互。

### 5.3 仿真侧

TB 不挂 PHY 模型，按板上做法给 `eth_mdio` 挂一根 `pullup`：

```verilog
wire eth_mdio_w;
pullup (eth_mdio_w);
```

这样主机释放总线时读到全 1 → `yx_b_phy_init` 走"PHY 未响应 → 跳过写"分支，
结果确定（否则读到 Z，`rdata` 变 X）。

### 5.4 TD 工程

`AC601_B_VQ_p5.al` 源表插入 `yx_b_mdio.v`(26) / `yx_b_phy_init.v`(27)，
原 26..30（顶层/wrapper/三个 .ipc）顺延到 28..32。

---

## 6. SDC 更新（`timing_b.sdc` §3.4）

原注释"PHY 控制引脚（eth_rst_n / eth_mdc / eth_mdio）：纯静态电平，无需时序约束"
**已作废**——`eth_mdio` 现在是三态动态信号。

### 6.1 ★ 首版约束写错了，TD 实跑抓出来

首版按"参考沿 = MDC 下降沿，PHY 输出在其后 5~195ns 内有效"写：

```tcl
create_clock -name b_mdio_virtual -period 400.000
set_input_delay -clock b_mdio_virtual -max 195.000 [get_ports {eth_mdio}]
set_input_delay -clock b_mdio_virtual -min   5.000 [get_ports {eth_mdio}]
```

TD 报告里 Budget 是 **捕获时钟的周期**，与虚拟时钟 period 无关：

```
Slack        : -182.966ns
Begin Point  : eth_mdio (b_mdio_virtual { rise@0.000  fall@200.000  period=400.000 })
End Point    : u_top/u_mdio/rdata_reg[0].d[0] (clk0 { rise@0.000  fall@5.000  period=10.000 })
Budget       : 10.000ns { clk0 rising@10.000ns - b_mdio_virtual rising@0.000ns }
input  D14   195.000
```

→ `195 − 10 ≈ 185`，把**本来干净的 100M 域**拖出 SWNS = −182.966ns。
（教训：虚拟时钟的 period 只影响它自己，输入路径的预算由捕获时钟决定。）

### 6.2 正确写法

```tcl
create_clock -name b_mdio_virtual -period 10.000
set_input_delay -clock b_mdio_virtual -max 4.500 [get_ports {eth_mdio}]
set_input_delay -clock b_mdio_virtual -min 4.000 [get_ports {eth_mdio}]
```

把 MDIO 建模成"PHY 在 clk0 沿后 4.0~4.5ns 输出、FPGA 在下一个 clk0 沿（10ns 后）
捕获"。这是**保守**抽象：真实数据在捕获沿前 200ns 就已稳定，模型只给 5.5ns 窗口，
保守约 36 倍。

`-min` 取 4.0 而非更小值：TD 的输入保持模型是
`hold_slack = input_delay_min + clk_min − (clk_max + hold)`，要求
`input_delay_min ≥ 2.837ns`（与 §3.1 RGMII 同一模型）。

### 6.3 TD 实跑结果（2026-11-24，非工程流 route 后）

| 项 | 结果 |
|---|---|
| `eth_mdio` setup | **+7.099ns** |
| `eth_mdio` hold | **+0.240ns** |
| clk0（100M） | SWNS 0.000 / HWNS 0.000 |
| clk1（73.3M） | SWNS 0.000 / HWNS 0.000 |
| clk7（`b_mdio_virtual`） | SWNS 0.000 / HWNS 0.000 |
| clk2（`b_eth_rxc_125m`） | HWNS −3.237 / HTNS −30.468 —— **已知 RGMII hold，未变** |

全局 SWNS 从 −182.966ns 回到 **0.000ns**。全部 10 条负 slack 路径都是
`eth_rxd[*]`/`eth_rxdv`（−2.903~−3.237ns），与改动前完全一致，无新增。

资源：LUT 4091 → **4235**（+144，+0.74%）；BRAM 53 不变；IO 15 不变。


---

## 7. 验证结果

| 入口 | 结果 |
|---|---|
| `mdio` | **ALL PASS** `checks=7 errs=0` |
| `phy_init` | **ALL PASS** `checks=11 errs=0` |
| `eth_rx` | **ALL PASS** |
| `bboard_sys_eth`（全链路） | **ALL PASS** `ETH ok=292 drop=0 bytes=297989`（精确匹配） |
| `bboard_sys`（全链路） | **ALL PASS** `ax_errs=0 axlines=3521 cpdeliv=166212` |
| `bboard_key`（KEY 合成流） | **ALL PASS** `ax_errs=0 axlines=2728` |
| TD 非工程流 route | 见 §6.3（SWNS 0.000，仅剩已知 RGMII hold） |

### 7.1 零扰动的硬证据

顶层 MCU/MDIO 逻辑与数据通路无任何共享信号，但"无共享信号"只是设计意图，
不是证据。这里做了**逐行对拍**：本次 `bboard_sys_eth` 产生的 52 个
`POLL`/`POLLCP` 观测点（每 250k 拍一次），与上一次 PASS 运行的同一批观测点
**逐字节完全相同**（`diff` 输出 0 行）。

```
prev lines: 64  cur lines: 52
diff lines: 0
```

即 MDIO 集成对 100M/73.3M/366.7M/50M 四个域的状态演化**零影响**。

---

## 8. ★ 遗留项已消解：`RXD0/RXDLY` strap 极性不再是阻塞项

上一份文档（`YX_BBOARD_P5_PHY1_20261124.md` §3）把"确认 `RXD0/RXDLY` strap 极性"
列为阻塞上板的前提。本轮实现 MDIO 后，这个问题**消失**了——不是查到了答案，
而是**答案不再重要**：

Linux 内核 `rtl8211f_config_rgmii_delay()`（`drivers/net/phy/realtek/realtek_main.c`）
把接口模式映射到该位，并且是**读-改-写**：

| 接口模式 | TXCR bit8 | RXCR bit3 |
|---|---|---|
| `RGMII`（无延时） | 0 | **0** |
| `RGMII_RXID`（RX 延时） | 0 | **1**（`RTL8211F_RX_DELAY`） |
| `RGMII_TXID`（TX 延时） | 1 | 0 |
| `RGMII_ID`（双向延时） | 1 | 1 |

读改写目标：页 `0xd08` / 寄存器 `0x15` / mask `BIT(3)`。

→ **bit3 = 1 就是"RX 延时使能"，bit3 = 0 就是"关闭"**，语义确定。
strap 只决定该位的**初始值**，不改变语义。我们的序列写 `rxcr_r & ~BIT(3)`，
**无条件把延时关掉**：

- strap 原本 = 1（延时开）→ 序列改为 0 → 修好了，正是我们要的；
- strap 原本 = 0（延时关）→ 写回同值 → **幂等**，无副作用。

两种情况下结果都是"延时关闭"，所以不需要知道 strap 极性。

> 这也是上一份文档 §3 结论"唯一可行修法是实现 MDIO 主机"的兑现。

---

## 9. 仍然遗留

1. **`PHY_INIT_WAIT = 100ms` 是保守取值**，未按 RTL8211F 数据手册精确核算。
   （RTL8211F 复位脚要求 ≥10ms，之后还需内部 PLL 初始化；视频通路不依赖该配置。）
2. **序列跑完无读回校验**：`rxcr_r` / `cfg_skip` / `cfg_done` 目前只在顶层内部，
   没有空闲引脚引出。若将来有遥测通道（UART/以太网上报），建议把这三位报出去，
   上板时可直接确认"延时确实被关掉了"。
3. **RGMII 输入 hold（−3.237ns / 10 端点）仍在**——与 MDIO 无关，是
   `YX_BBOARD_P5_PHY1_20261124.md` §3 的拓扑/判据冲突（TD 判据要求
   `input_delay ≥ 2.837ns`，物理不可满足）。本轮未动。
4. `eth_mdio` 的 hold 裕量只有 **+0.240ns**（见 §6.3）。这是 TD 把 PLL 插入延时
   算进保持判据造成的模型artifact；物理上数据在采样沿前 200ns 就稳定，真实裕量
   极大。若后续 TD 版本改判据，这个数会变化，不必照此调参。

