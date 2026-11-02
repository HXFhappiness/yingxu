# D8：视频接收确认、硬件打砖块与菜单视觉

> 本文记录历史版 `be1f0bc`。该版板测视频仍黑屏，最新修复及卡带菜单映射见
> [D8 板测跟进](D8_BOARD_FOLLOWUP.md)。下文游戏入口与旧 I1 说明仅适用于历史版。

交付分支：`feat/unified-menu-photo-video`，基于板测过的 D7 `d0d12ca`。
视频补丁独立提交 `be4ee9f`；logo/任务书来自用户的 `766653f`，字模保持原样。

## 视频：DD3000 的含义与改动

`DD3000` 表明：两级仲裁 active/owner=101/110，已重提交一次，但
loader.sent=0、物理口 IDLE/position=0；外部 command valid/ready=0/1、
write valid/ready=1/0。停在**命令接收失配、首字之前**。`ACC=020` 是 PCM
当前请求收到 32 字节，DNE=0/LS=6 是请求开始清完成标志及故障后 SD abort
的表现，不能据此认定 SD 重新初始化导致卡死。

新物理口先保存命令，再在下一周期确认 ready，随后进入写 COLLECT/读 WAIT。
旧 ready 只表示空闲许可，收到 command valid 之前就可能让上游认领；新 ready
只出现在“命令已保存”的 ACCEPT 状态。valid 暂时丢失时上游继续持有命令；
确认拍被屏蔽也仍按锁存字段执行。没有增加重试次数或伪造完成。

I1 旧编码保持，物理 state 新增 5=ACCEPT；0=IDLE、1=送数、2=等待授权、
3=物理传输/等待 done、4=读回输出。MISE 仍是阶段+错误码。
完整解码、故障复现、形式证明和 7594 扇区数据验证见
[视频补丁说明](D8_VIDEO_CAPTURE_ACK.md)。注入复现不等于已证明板上的物理触发
因素；新握手是否解决该板上的黑屏，仍需本地 TD 和真机确认。

视频生产改动只在 `yingxu_sdram_burst_port.v`。pipeline、loader、双层
arbiter、SD reader、SDRAM 控制器与照片 player 保持 D7 字节一致；菜单
没有串入视频仲裁或数据握手。

## 游戏：采用方案 (b)

`yingxu_breakout.v` 已有可用的分级硬件引擎，D7 缺少实例与图层连接。
现将其接入 `game_sel=0`：

- 虚拟 `7F` → 硬件打砖块，ball/paddle/生命 sprite、60 位砖块层和 PSG 事件接好；
- 虚拟 `5F` → 原硬件 `yingxu_invaders`，保持 D7 菜单映射；
- 两者均用 key0 左、key1 右；SW7 OFF 时可正常作为游戏操作键，
  SW7 ON + key0 按 D6 返回菜单，2 秒长按保留兜底；
- 进入打砖块产生 restart，离开时清 sprite；音乐模式明确禁止启动打砖块，
  包括实体开关从游戏切音乐但 game_sel 同为 0 的情况；
- 实体 DIP 的原卡带路径与镜像选择保持，菜单这两个游戏均不依赖卡带镜像。

实际顶层测试从菜单按键进入两游戏，检查模块 enable、真实 sprite 表写入、
砖块 mask，以及持续按真实左右键跨真实帧后 paddle/player 的位移，
避免仅验证模式译码却没有游戏内容的问题。

## 菜单视觉

- 对角坐标 x+y，按每 200 个坐标划分任务书给定的 10 色带，最后一带覆盖
  1800..1998。仅比较/常量，无乘除器。
- 用户的 160×160 logo ROM 原样使用，外框 x40..199/y28..187，MSB 左、
  1 为纯白，透明位显示渐变。
- 原面板、文字、绿标坐标不变；两个页面逐像素保留同一背景/面板/logo，
  选择变化只移动绿标。菜单继续完全绕开 BMP。

![主菜单仿真合成](evidence/D8/main.png)

![游戏子菜单仿真合成](evidence/D8/games.png)

## 验证入口

| 命令 | 范围 |
| --- | --- |
| `python3 tools/port_capture_ack_verify.py` | 接收先于确认的归纳证明，允许任意 valid 屏蔽 |
| `python3 tools/yxv_d3_units.py` | 物理 1..8 字、边界/掩码/背压、loader、scanout、PCM |
| `python3 tools/yxv_preload_verify.py --fast-card --block 8` | 首次 valid 延迟，486 帧/7594 扇区 PCM 全量比对 |
| 同上 `--no-build --block 9` / `--block 10` | 确认拍屏蔽 / 每笔命令延迟，全量比对 |
| 同上分别使用 `--no-build --block 1` 至 `--no-build --block 7` | 真实送数/授权/done 阻塞及永久无命令的有限超时 |
| `python3 tools/d8_menu_verify.py` | 7 场景/6,451,200 像素，全部 logo 位/字模/图层、页间不变、全 1999 个对角坐标单调性 |
| `python3 tools/menu_mode_verify.py` | 全 2500 万周期开机窗口、10 组模式/返回/毛刺、游戏 sprite 与实际按键位移 |
| `python3 tools/d5_menu_verify.py` | 菜单条生产过程读取、清表恢复和退出 |
| `python3 tools/yxv_d3_verify.py --frames 72` | 实际顶层 72 帧/3 秒播放、像素/PCM/速率/SD 预算/遥测/退出 |
| 同上 `--no-build --bad 1` | 坏头硬件菜单回退和真实 UART 故障快照 |

原始日志、源码哈希与测试输入在 `evidence/D8`，视频单独补丁证据在
`evidence/D8_VIDEO`。FIFO/PLL/SD 卡/SDRAM 单元为功能模型；快卡仅加速
事务模型。TD、SD 引脚电气和板上时序不由这些测试证明。

上述检查均已通过。完整视频实际播放 144001 个采样、持续 3.000000066 秒，
掉帧 0，PCM/HDMI 音频零差异、48 kHz 误差 0 ppm；11,212,800 个解码写字、
54,988,800 个扫描像素零差异，退出时释放所有权。实际 UART 遥测及坏头诊断
检查均通过。菜单 645 万像素与四组真实游戏左右键操作、完整开机窗口和
10 组模式控制也通过。

## 本地构建

在用于 TD 的统一分支检出目录：

```sh
git pull --ff-only
python tools/prepare_unified_td.py
```

打开生成的 `out/unified/AC201_AL_board_test.al` 或使用生成的 full Tcl。
共 66 个工程引用，生成器强制检查 font/menu/logo/breakout 都已注册；
记录当前检出路径和源文件 SHA256，避免实际仍读取旧目录。云端未运行 TD，
未生成位流。本地需重新 syn/phy，检查 MEM 10 ns 与像素时钟的新增路径后板测。

本轮照片漂移实验未合入生产，原照片播放与 D6 开机/返回规则均保留。
