# D10：修正物理写口时钟绑定与菜单返回层级

> 后续 D11 按面积预算移除了硬件游戏并压缩遥测。最新工程、资源代理和验证见
> [D11 面积裁减](D11_AREA_REDUCTION.md)；本页保留 D10 时钟定位记录。

基于 D9 板测提交 `1ef7a52`，交付到 `feat/unified-menu-photo-video`。
本轮生产改动仅在顶层菜单 FSM 及控制器/游戏实例的声明顺序；D9 命令协议、I1 位表、
安全取消、SD reader、loader、JPEG 解码、照片播放、字模/logo/渐变均保留。

## 1. 94D000：命令已到两级出口，物理接收端没有运行

现场 `MISE=929F / ACC=020 / I1=94D000` 的 I1 按 **mstate=1 命令等待格式** 解码：

| 位 | 值 | 含义 |
| --- | --- | --- |
| 23 | 1 | 扩展快照 |
| 22:20 | 001 | 内层 active=0，选择 loader owner=1 |
| 19:17 | 010 | 外层 active=0，选择 loader 分支 owner=2 |
| 16 | 0 | 本次等待期间没观察到接收端 clock_tag 活动 |
| 15 / 14 | 1 / 1 | 内层 / 最外层 command VALID 均已保持 |
| 13 | 0 | 接收端没有采到 command VALID |
| 12 / 11 | 1 / 0 | 接收端 enable=1、reset=0 |
| 10:7 / 6:4 / 3:0 | 0 / 0 / 0 | sent=0、物理 IDLE、position=0 |

两层 VALID 均来自 pending 寄存器，因此此处是待接受命令，不是传输 8 字中、等 SDRAM
授权或等 done。它与 D9 的“仅接收端停钟”注入签名相同。本轮找到了一个无需故障注入、
就在生产 RTL 中出现的时钟绑定原因。

## 2. 原因：generate 内使用了尚未声明的模块 CLK

`yingxu_sdram_control_4port.v` 原先按下列顺序组织：

```verilog
generate if(MJPEG_PORT) begin: mj_port
    yingxu_sdram_burst_port port_adapter(.clk(CLK), /* ... */);
end endgenerate
// ...
output wire CLK;
Sdram_PLL sdram_pll1(/* ... .clk0_out(CLK) ... */);
```

Icarus 在实例端口首次引用处创建 **generate 局部隐式 wire `mj_port.CLK`**，它没有驱动；
后面的模块级 `output CLK` 属于另一个作用域，不会把前者补接到 PLL。于是父级 SDRAM
控制器和 MEM pipeline 正常计时、解析帧表、超时，但只有 burst adapter 一拍也不执行。
Verilator/Yosys 会把该引用绑定到模块 CLK，因而此前这些工具的功能回归没有暴露问题。
此前仅用 Verilator 运行完整顶层回归，确实漏掉了这个前端差异。

这也解释阶段演变：旧 IDLE-ready 可以让上游在未运行的接收端前误认 ACK，表现为
949F；D8 改成捕获后 ACK，停止误认后表现为 929F；D9 的独立时钟观察进一步得到
94D000。板上寄存器初值为 0 时也会一直呈现 IDLE/position=0、时钟标志=0。

修复是把 `output wire CLK` 前移到 generate 之前，并在该生产文件启用
`default_nettype none`。所有工具现在都只能引用同一根已声明的 PLL 时钟。
没有换时钟频率、增加 SD 复位/重试或伪造完成。

**生产控制器原样对照，非注入测试：**

| Icarus 运行 | 父级时钟 | 接收端时钟 | 命令结果 |
| --- | --- | --- | --- |
| `1ef7a52` 原控制器 | 28 拍 | 0 拍，clk=Z | 0 ACK，编译器报告隐式 CLK |
| 声明前移后的控制器 | 18 拍 | 18 拍 | 1 ACK，接收 8 字，进入 WAIT |

原始编译/运行日志见 [evidence/D10/clock_binding](evidence/D10/clock_binding)。基线直接
取自 git，未对其时钟做 force/gate，也未为它改写声明；PLL/FIFO 是功能模型。
Icarus 需要 `-gno-io-range-error` 容许厂商原有 CS_N 标量/向量声明差异，其余原有
厂商位宽告警仍记录，隐式网络告警作为失败门禁。

同时前移 `clr_active`、程序 RAM 的 `raddr_q` 声明，并将菜单绘制实例放到其同步
控制寄存器声明之后，消除同类前向实例端口引用。最终实际工程顶层 Icarus 展开检查
通过，**隐式网络告警为零**。这几项只调整声明/实例顺序，不改变游戏和像素运算。

云端没有 TD，尚未直接读取该板的 TD 网表。上述前端差异和生产 RTL 修复已经复现，
与三轮板测阶段吻合；新位流是否消除板上黑屏仍需本地 syn/phy 和板测确认。

## 3. SST / SNX / SDN 不能作为读请求数或扇区地址

顶层分别把 `sd_dbg_spi_start`、`sd_dbg_spi_next`、`sd_dbg_spi_done` 接入 UART。
`yx8_uart_telem.v` 对上升沿做 **16 位累计计数**，仅全局复位清零，会溢出，也会计入
初始化、不同请求和故障前的活动。

因此 BD13 / BD13 / 0DC9 不是“48403 次 SD 请求 / 推进到 0DC9 扇区”，跨构建数值
增大也不能证明请求持续完成。15 秒稳定不变只说明捕获期间对应计数没有再变化。
ACC=020 仍是 PCM 当前请求的首批 32 字节，OFF 保留首读 LBA；头和帧表已通过后，
首笔 SDRAM 写受阻，背压后才发生 9F 超时/SD abort，不能倒推为 SD 先断供。

本轮使用 486 帧、PCM 3,888,000 字节 / 7594 扇区的同规格生成夹具做全量回归。
当前云端没有卡上原 YXV 的字节副本，不能把生成夹具称作“同一文件”。此次时钟绑定
问题在未接 SD、也未读任何文件的控制器对照中就能复现，不依赖视频内容。

## 4. A：菜单接管只允许复位或显式取得

`1ef7a52` 中的 menu_real_change 本已含 `!menu_override`；仅凭新视频帧，无法证明
退出时确实发生过 override 从 1 到 0。本轮彻底移除了该检测器在键控 FSM 中的分支：
实体开关事件既不能清 override，也不能把 img_idx 强行置 1 跳到照片浏览。

复位决定 BOOT_MENU 初值；复位之外仅 menu_return 可以把 override 置 1，
**不存在把它写成 0 的赋值**。BOOT_MENU=0 维护构建仍通过 sw_eff 直接跟随实体 DIP，
一旦显式回菜单便保持菜单接管。0.5 秒开机稳定窗口和 20ms DIP 观察器保留。

对实际生产键控 FSM 的归纳证明同时覆盖 BOOT_MENU=0/1，在任意开关/按键/模式/
返回输入下，一旦接管就保持接管。测试还覆盖：先拨 SW7、等待超过 20ms、再按 key0，
以及退出键持续按住超过完整 100ms 锁定，不会自行确认进入照片。

## 5. B / C：返回来源页面和选项，100ms 锁定

- 进入模式时保存 menu_return_page / menu_return_sel。图片、视频、音乐返回主菜单的
  原选项 0/2/3；两款游戏返回游戏子菜单，并停在刚才的游戏 0/1。
- 游戏子菜单本身按 SW7 ON + key0，返回主菜单的“游戏”（sel=1）。
- 返回仍置 pattern=PHOTO、img_idx=0，执行已有场景复位/精灵清表；只是恢复来源页面
  与选择，背景、面板、logo 不因切页变化。故障返回和 2 秒长按兜底沿用相同来源规则。
- 全部 key_lock 装载统一使用 `KEY_LOCK_CYCLES=5_000_000`，即 50MHz 下 100ms，
  取消分散的 24'hFFFFFF。菜单导航、确认、返回及照片导航使用同一锁定值。
- 主菜单 SW7 ON 时 key0 仍确认；游戏子菜单和模式内该组合用于返回，选择游戏时将
  SW7 置 OFF。游戏镜像/卡带译码保持 D9：BREAKOUT=1001000，INVADERS=1000000。

## 6. 本轮验证

| 命令 | 结果/范围 |
| --- | --- |
| `python3 tools/sdram_clock_binding_verify.py` | Icarus 生产控制器前后对照；实际顶层展开，零隐式网络 |
| `python3 tools/menu_keys_verify.py` | 两种 BOOT_MENU 接管归纳证明；真实 500 万周期锁定、提前按键抑制、按住不重复、返回后按住不重确认 |
| `python3 tools/yxv_preload_verify.py --fast-card --block 10` | 486 帧 / 7594 扇区；121504 bursts、972032 words 全量零差异；零重试、零重复初始化 |
| 同一构建 block 12 / 13 / 14 | 部分接受事务完成后退出、健康预载退出；停钟注入仍准确报告 94D000 |
| `python3 tools/menu_mode_verify.py` | 2500 万周期开机窗口；10 组模式/毛刺与来源页面/选项恢复；真实两卡带左右操作；退出 CPU/精灵零残留；921600 像素菜单合成 |
| 同上 `--direct` | 维护构建原实体模式及显式取得菜单接管保持 |
| `python3 tools/d5_menu_verify.py` | 生产菜单条 Yosys 读取、选择/返回/清表和故障路径 |
| `python3 tools/yxv_d3_verify.py --frames 2` | 实际顶层循环含第 3 帧；460800 解码写字、1986976 扫描像素、4001 PCM 样本零差异；48kHz、SD 预算、退出通过 |

本轮没有重复运行 D9 的 72 帧长播放；视频事务 RTL 字节未改，新增关键门禁为
Icarus 作用域对照。新 PCM 全量、短播放和菜单完整路径均在本轮运行。原始日志、
源码/夹具哈希及范围在 [evidence/D10](evidence/D10)。这些测试不提供 SD 引脚电气、
TD 时序或真机结果。

## 7. 本地统一构建

```sh
git switch feat/unified-menu-photo-video
git pull --ff-only
python tools/prepare_unified_td.py
```

打开生成的 out/unified/AC201_AL_board_test.al 或运行 build_full.tcl，完整重跑 syn/phy。
66 个工程引用、127 个 HDL/IP/工程输入的 SHA256 与当前检出路径写入 source_manifest.json。
菜单视觉资产不变，无需重写卡或重新生成字模；本轮云端未生成位流。

板测优先检查视频能否越过 PCM 首笔写：MISE 不再停在 929F，随后 decoded/displayed
计数推进并出现画面/音频；I1 格式沿用 D9。其次验证每款游戏退出回子菜单原选项，
再从子菜单返回主菜单“游戏”，及 SW7 保持 ON 时主菜单确认正常。
