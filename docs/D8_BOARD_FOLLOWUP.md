# D8 板测跟进：视频命令转发、独占菜单与 YX-8 卡带入口

> 本文记录 `1ef7a52` 历史交付。该版板测得到 94D000，已进一步定位到 generate
> 内隐式 CLK；最新修复、返回层级及 100ms 按键见 [D10 说明](D10_CLOCK_MENU_RETURN.md)。

交付分支 `feat/unified-menu-photo-video`，基于板测版 `be1f0bc`。
本轮按用户附件继续修复，并按最终选择将现有两个游戏入口直接接到 YX-8 卡带版。
D7/D8 字模、logo、渐变及纯硬件菜单保留；本轮没有调整照片 BMP 的读写时序。

## 1. 新现场 929F / I1=000000 的准确含义

`MISE` 高字节为 `{purpose[1:0], state[2:0], mstate[1:0], invalid}`：

| 阶段 | 含义 | 前后关系 |
| --- | --- | --- |
| 92 | PCM / RECEIVE / mstate=1 | 已攒齐 8 字，等待 SDRAM 写命令被接受 |
| 94 | PCM / RECEIVE / mstate=2 | 命令已接受，发送 8 字或等待事务完成 |

`9F` 仍为进度超时。`ACC=020` 是 **PCM 当前请求的 32 字节**，不是头扇区只读了
32 字节；到这里头扇区和剩余帧表已经读取并通过校验。旧版 I1 在 mstate=1 时
把高 13 位清零，因此 `000000` 只说明 sent=0、物理 state=IDLE、position=0，
无法说明命令在两层仲裁的哪一级停住。

此时 PCM 多块请求已经发出，无须等待“第二块 SD 请求”才能进行这笔写入。
loader 因首个 SDRAM 命令尚未接受而施加背压，之后才超时 abort；SD 被持续复位是
故障收尾的结果。DNE 在请求开始时就被清零，不能据此认定 reader 重进初始化导致故障。
`OFF` 保存首次请求 LBA，不能用它推导当前 PCM 地址。

486 帧测试夹具的三笔请求是：LBA 3,000,000 / 1 扇区（头），3,000,001 / 7 扇区
（剩余帧表），3,002,924 / 7,594 扇区（PCM）。实际卡上 PCM 地址为
`3,000,000 + audio_off`，其中 `audio_off` 由帧表末项结束位置按扇区向上对齐得出；
**3,002,924 仅为测试夹具地址，当前板测帧不足以确定卡上该值。** 完成 PCM 预载后
才读取帧表给定的 JPEG 扇区，不能把这笔尚未发生的读当成首笔 PCM 写的前提。

## 2. 视频生产改动与证据边界

两层 `yingxu_mjpeg_arbiter` 现在分别寄存 pending、owner 及完整命令载荷。
VALID 不再穿过两层组合优先级选择器直接到物理接收端；每层保持命令，直到真实
下游确认，完成/错误之前保持事务归属。所有路由使用显式常量切片与 case。
每层多一拍命令延迟、26 位命令载荷寄存器；保留 D8 的“先锁存、下一拍 ACK”。
没有增加重试次数、伪造 done 或修改 SD 初始化/分频。

另一个**已复现并修复**的问题是：未接受命令让 quiet 永久为 0，用户退出后仍
无法释放 owned/SD reset。现在退出仅在物理口空闲、两层仲裁均无已接受事务时取消
pending 命令并复位工作状态。若已有部分写入，必须等整笔真实完成后再取消，不能
丢弃已接收数据。取消同步到 SYS 后 abort 当前 SD 读，随后释放所有权；诊断保留到
操作者退出。CANCEL_PENDING=0 对照会卡住，新逻辑可以释放；4/8 字部分写入用例
先保持所有权，解阻后完成全部 8 字并逐字比对，再释放。健康预载中主动退出同样通过。

正常同钟 RTL 中，“VALID 持续到达、接收端已使能且未复位，但始终 IDLE”不能稳定
存在。故障注入可复现现象，却不能证明板上的物理触发因素。此次寄存转发缩短相关
组合路径，接收端增加独立观察点；**云端未运行 TD，尚未证明板上视频黑屏消失**。
下一版仍异常时，用下述快照定位到发送级或接收端时钟/使能/复位，再核对 TD 实现。

## 3. I1：扩展命令等待编码，94 格式保持

低 11 位始终为 `[10:7] loader.sent`、`[6:4] 物理 state`、`[3:0] position`。
物理状态 0=IDLE，1=COLLECT 送数，2=WAIT 等授权，3=TRANSFER 等物理数据/done，
4=DRAIN 读回输出，5=ACCEPT 已锁存命令/确认。

仅当 loader.mstate=1（例如 MISE=929F）时启用以下高位编码：

| 位 | 含义 |
| --- | --- |
| 23 | 扩展标记 1 |
| 22:20 | 内层 `{active, owner[1:0]}`，loader owner=1 |
| 19:17 | 外层 `{active, owner[1:0]}`，loader 所在分支 owner=2 |
| 16 | 本次命令等待期间观察到接收端 clock_tag 变化 |
| 15 | 内层输出 command VALID |
| 14 | 外层输出 command VALID |
| 13 | 接收端时钟实际采到 command VALID，空闲且 VALID 撤去后清除 |
| 12 | 接收端 enable |
| 11 | 接收端 reset（1 表示复位有效） |

active=0 时 owner 表示所选 pending 客户端，而不是已接受事务。

| 注入条件 | MISE | I1 | 区分依据 |
| --- | --- | --- | --- |
| 接收端持续看不到 VALID | 929F | 95D000 | 两级 VALID=1，时钟活动，但接收端未采到 VALID |
| 仅接收端时钟停住 | 929F | 94D000 | 时钟活动位为 0，enable=1、reset=0 |
| 仅接收端 enable=0 | 929F | 95E000 | 时钟活动且采到 VALID，enable=0 |
| 仅接收端 reset=1 | 929F | 94D800 | reset=1，时钟观察寄存器保持复位 |

这些是仿真故障签名，不是对下一次板测读数的预言。时钟位表示等待期间曾有活动，
不能证明故障最后一刻仍在跳变；VALID 采样位也是保持观察，不代表任意时刻的原始电平。
若 929F / IDLE 下读到 95F000，则表示时钟有活动、VALID 已被接收端采到、enable=1、
reset=0；这种持久状态不符合正常同钟 RTL，应重点核对实现/时钟与实际构建来源。

mstate=2（例如 949F）沿用原编码：bit16=replayed，15=loader command ready，
14=command valid，13=command ready，12=write valid，11=write ready。
因此 0<sent<8 是送数中，sent=8 后用物理 state/position 区分等授权或等 done。
原 DD3000 的含义不变：两级 active=1、重提交已用过、sent=0、物理口 IDLE，卡在首字之前。
MISE 仍保持阶段+错误码，I0/数据快照未恢复。

## 4. 独占菜单、退出清理和两款 CPU 游戏

- menu_override=1 时，menu_real_change 失效。为退出而先拨 SW7、等待超过 20ms，
  不再把模式切到实体 DIP。BOOT_MENU 默认 1；仅显式 BOOT_MENU=0 维护构建使用实体直通。
- key0_exit 仅在模式内或游戏子菜单有效。主菜单上 SW7 保持 ON，key0 仍确认一次。
  照片浏览虽与主菜单共用 PHOTO pattern，但 img_idx!=0，仍可正常退出。
- 返回统一置 override=1、pattern=FF、sel=0、page=0、img_idx=0。
  场景切换 toggle 在 SYS/PIX 两域产生拉宽复位，并执行完整 16 槽精灵表清除。
  仅移动选择条不复位场景。清表结束后重新画选择条，不保留游戏精灵/砖块层。
- yx8_cart_soc_v2 原 cpu_rst 不含 deselect，已加载 CPU 可能继续执行。现在 en
  撤销真正复位 CPU、loader、FIFO、I/O、计数及砖块 staging，不是仅把遥测输出置零。
- 原卡带 restart 是一个像素周期，跨到较慢 SYS 可能丢失；改为 toggle 同步并发完整
  SYS 脉冲。卡带请求先同步到 SYS；SD 字节还必须属于实际镜像 LBA..LBA+5，
  防止请求排队期间把旧照片尾部写入卡带 FIFO。
  卡带每次读取固定 6 扇区，覆盖两个镜像；不再读照片长度的 5401 扇区。

| 现有子菜单文字 | menu_pattern | game_sel | 镜像/仓库约定 LBA | 程序 |
| --- | --- | --- | --- | --- |
| 打砖块 | 5F | 2 | breakout.yxc / 1,001,000 | YX-8 BREAKOUT，492 指令字 |
| 飞机大战 | 1F | 2 | invaders.yxc / 1,000,000 | YX-8 INVADERS（宇宙流浪者），604 指令字 |

上述镜像由仓库 .asm 重新汇编后与提交的 .yxc 逐字节一致，哈希见证据。
这确认仓库镜像及写卡配方，不能替代读取用户真实卡片；本轮没有写 SD 卡。
硬件游戏仍可在 BOOT_MENU=0 维护构建用原实体译码进入，菜单两项均为 CPU 版本，
无需新增中文字模。正常游戏操作保持 SW7 OFF；SW7 ON + key0 用于返回。
游戏子菜单中该组合也返回主菜单，选择游戏时应把 SW7 置 OFF。

## 5. 验证与复现

| 检查 | 本轮结果/入口 |
| --- | --- |
| 命令保持与归属归纳证明 | registered_arbiter_verify.py，任意阻塞/输入，PASS |
| 接收先于 ACK 归纳证明 | port_capture_ack_verify.py，含接收端采样标记，PASS |
| 486 帧 / 7594 扇区 PCM | block 8、9、10：各 121504 bursts / 972032 words 全量零差异，无重试/重新初始化 |
| 真阻塞诊断 | block 1..7：送数、授权、done、无命令分别有限超时并冻结；14..16 区分接收端条件 |
| 退出安全 | block 11 取消未接受命令，12 完成部分接受事务，13 健康预载中退出；均释放 owned/reset |
| 顶层完整播放 | 72 帧目标 / 3 秒，循环含第 73 帧；144001 PCM 样本零差异，48kHz 误差 0ppm，掉帧 0 |
| 图像与 SD 预算 | 11212800 解码写字、55055360 scanout 像素零差异；实测模型字节率 1121279B/s < 1300000B/s |
| UART 与坏头 | 真实 TX 引脚解码首读 LBA、计数、magic；坏头回退/诊断与 27 个诊断用例通过 |
| 菜单/游戏 | 完整 2500 万周期开机窗口、10 组路径/毛刺、两 CPU 游戏实际左右操作、退出零残留，通过 |
| 返回后合成 | 一整帧 921600 像素只含菜单/选择条，通过 |
| 维护与菜单条读取 | BOOT_MENU=0 直通及显式回菜单通过；Yosys 读取生产菜单条过程通过 |

主要命令：

```sh
python3 tools/registered_arbiter_verify.py
python3 tools/port_capture_ack_verify.py
python3 tools/yxv_preload_verify.py --fast-card --block 10
# 同一构建可用 --no-build 分别跑 block 1..16；block 11 的 --no-cancel 是死锁对照
python3 tools/menu_mode_verify.py
python3 tools/menu_mode_verify.py --direct
python3 tools/d5_menu_verify.py
python3 tools/yxv_pending_verify.py
python3 tools/yxv_d3_verify.py --frames 72
python3 tools/yxv_d3_verify.py --frames 72 --no-build --bad 1
```

原始证据及范围说明在 [evidence/D8_FOLLOWUP](evidence/D8_FOLLOWUP)。SD 卡、PLL/FIFO、
SDRAM 为功能模型；快卡只加速事务模型。完整顶层播放运行后调整了诊断用
command_seen（从原始 VALID 改为接收端时钟采样标志）、卡带扇区归属门控及注释；
最终视频功能通路不变，最终版本已重新验证接收端形式证明、所有 PCM/退出/接收端
故障用例，以及包含旧照片字节注入的完整菜单/卡带路径；最后再用完整顶层短播放检查最终接线。时序、电气与板上视频结果仍需本地验证。

## 6. 本地统一构建

```sh
git switch feat/unified-menu-photo-video
git pull --ff-only
python tools/prepare_unified_td.py
```

打开生成的 out/unified/AC201_AL_board_test.al，或使用同目录 build_full.tcl。
生成器核验 66 个工程引用及 127 个 HDL/IP/工程输入的哈希，font/menu/logo/breakout
均已注册；source_manifest.json 记录实际提交与读取路径。需完整重跑 syn/phy，并核对
MEM 10ns 下新增寄存器与返回路径的时序。云端没有 TD，未生成 bitstream。

若视频仍黑屏，请保留进入后首次稳定的完整 A/B/C/D 帧（尤其 MISE/I1），并保留
本次 source_manifest.json；本轮格式能区分命令转发和接收端条件。退出动作已覆盖
故障挂起，SW7 ON + key0 应回到干净菜单。
