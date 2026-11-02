# D11：删去硬件游戏、压缩 UART，保留视频和菜单视觉

交付到 `feat/unified-menu-photo-video`，基于 `4a26c65`。
任务来源是用户的 D10 面积反馈：syn 18250 LUT，phy 18537/19600（94.58%），
希望降到 85% 以下。本轮未运行 TD，这些基线值来自用户，后文代理值均明确标记。

## 1. 按优先级移除两套硬件游戏

- 删除 wrapper 中 `U_hw_inv` / `U_hw_breakout` 实例、restart 寄存器及它们的事件/精灵 mux。
  按用户的 TD 层级数据，这两项原占 740+366=1106 LUT。
- game_sel=0/1 的预留译码保留，精灵/砖块输出为零；它们不再有游戏引擎。tile 背景仍在，
  因此预留模式不保证整个画面纯黑。`BOOT_MENU=0` 下的原硬件 DIP 组合不再提供可玩游戏。
- 主菜单的两个游戏继续都是 YX-8 卡带：BREAKOUT @ LBA 1001000，INVADERS @ 1000000。
  CPU、卡带加载、软件砖块层和四种 PSG 事件音效保留。游戏返回子菜单原选项、
  子菜单返回主菜单“游戏”、100ms 导航锁定不变。
- 两个硬件游戏源文件从 `.al` 注册列表移除；历史 RTL 留在仓库供独立参考，未实例化。
  prepare_unified_td.py 会拒绝重新注册它们，防止误恢复旧工程列表。

## 2. 遥测：保留全部 A/B/C/D 字段，改用一个同步格式 ROM

旧 `char_at()` 在字符 mux 之前分别调用 107 次 hx，复制了大量 ASCII 比较/加法器。
本轮保留 347 字节的原报告模板，改为：

1. 512×8 的只读同步格式 ROM，内容为字面 ASCII 或“十六进制 nibble 索引”。
2. 一个密集 nibble 选择器和一个共享 hx 编码器。窄字段的补零与旧格式一致。
3. 发送当前字节的 4340 个 SYS 周期内，预取下一字节的格式 token。数据字段仍在旧版
   相同的装载边沿读取 live 值，未增加字符间空隙、未冻结整包或改变诊断取样时机。

波特率仍为 50MHz/434 的 115200 8N1，整包结束后等待 1000 万 SYS 周期再报告。
MISE 阶段+错误码、I1 的 D9 控制位、I0、RSP、ACC、LS/F、SST/SNX/SDN 全保留。
这些 SPI 计数仍是 16 位上升沿累计计数，不是读请求数或扇区地址。

额外裁掉顶层旧 G6 音乐模式对 PC/DW/I0/RC/I1/MISE/SCE/SP 的覆盖 mux，空接 8 个
音乐诊断端口，使只供它们使用的计数/保持寄存器可被综合删除。音乐播放状态、FIFO
占用和看门狗仍服务于音乐 LED；`dbg_pop` 真实样本消费脉冲继续连接视频调度，
与退役的 `dbg_pops` 累计诊断计数不是同一信号。播放器、混音和视频音频逻辑未改。
音乐模式的 D 帧现在使用默认 YX-8/菜单字段；旧 music_telem 脚本的 G6 字段解释仅适用
历史冻结固件，统一版用通用串口报告。

同步格式 ROM 用 **1 个 BRAM** 换取逻辑面积；初始化内容直接写在 RTL，未依赖外部文件。
原生代理映射确认得到 1 个带非零 INIT 数据的 EG_PHY_BRAM。它的读延迟被 UART 字节
间隔吸收，不影响像素链路。本地 TD 需保留这份 ROM 初始化；若未映射为 BRAM，
必须重新看实际 LUT 总量，不能沿用以下估算。

## 3. 面积结果：代理已达目标，TD 85% 门禁尚未实测

同一 Yosys 0.52 原生 Anlogic 映射、同一完整 UART 输入接口：

| 指标 | D10 UART | D11 UART |
| --- | ---: | ---: |
| 原生 LUT 单元（LUT1..6 各按一个单元计） | 1360 | **355** |
| 保守 LUT4/进位折算（LUT5×2、LUT6×4、进位单列计入） | 3098 | **611** |
| BRAM | 0 | **1** |

这是可复现的模块前后对照，**不是 TD 的 LUT/REG/BRAM 实测**。不能把两个不同
计量口径混用。原生 LUT 单元减少 1005，符合遥测模块压到 300–400 的代理目标。

仅作规划，用用户的旧 TD UART 1298 按代理比例校准：

```text
估算新 UART = round(1298 × 355 / 1360) = 339
估算总 phy LUT = 18537 - 740 - 366 - 1298 + 339 = 16472
估算占用 = 84.04%
```

这里尚未计顶层 G6 mux/计数裁减的额外收益。由于前两项的规划值已低于 85%，
按任务优先级 **保留 U_tile**（用户给出的旧面积 525 LUT），不改游戏背景。
本地 TD 的实际总 LUT 必须 **<16660/19600**；云端不能宣称该门禁已经通过。

## 4. 中文字和 logo 确实进入菜单输出

当前提交保留 `4a26c65` 的字模和 logo 字节，不改版面/颜色/组合读相位。
`yingxu_menu_ui` 中的字体 bit 参与 ink，logo bit 参与 background，最终进入 menu_rgb；
wrapper 的菜单背景又进入 sprite 合成及 HDMI 图像路径。

验证不只检查实例名：

- 实际 RTL 的两页 7 种选择场景，**6451200 个活动像素**与逐位资产金标一致，
  包括全部 logo 区域、字形、渐变、面板与绿标合成。
- 将菜单 UI 和两个 ROM flatten 并综合成 LUT4 网表后，重新求值 **323 个像素**，
  覆盖 **17 个字形**的墨点/空点和 **160 行 logo** 的亮点/透明点，全部正确。
  如果字/标志被整体优化掉，这些带颜色对照的断言会失败。

这证明本提交的源码及 Yosys 映射链路中资产是有效逻辑；不能仅凭“logo 7 LUT / 未见
独立字体层级”认定内容消失，层级扁平化/常量压缩会改变归属。异步组合 ROM 也无需
一定推断为 BRAM；将其改为同步读则需要重新对齐像素相位，本轮没有这么做。

附件提到的 `f638fb6` 不在当前云端对象库或远端分支 HEAD 中，统一远端当时仍为
`4a26c65`；本轮未取得该本地 D10c 提交，不能替它的 ROM 数组版本提供验证结论。
请使用本交付完整检出及生成的 source_manifest.json 构建。

## 5. 验证与证据

| 命令 | 本轮检查 |
| --- | --- |
| `python3 tools/d11_area_verify.py` | 两版 UART 原生映射、LUT/进位/BRAM 数、ROM 非零初始化及明确标记的校准估算 |
| `python3 tools/uart_compact_verify.py` | 全 512 字符地址、任意输入/计数值的格式等价证明；实际时钟下 2 包/694 字节的每一个 TX bit 与 D10 相同 |
| `python3 tools/menu_mapped_verify.py` | 映射后字体/logo 的 323 像素求值 |
| `python3 tools/d8_menu_verify.py` | 6451200 个菜单活动像素、页间背景不变、完整资产与合成 |
| `python3 tools/menu_mode_verify.py` | 10 组模式/毛刺；真实 YX-8 两游戏加载与左右操作；来源页面/选项恢复；CPU/精灵清理和 921600 像素退出合成 |
| 同上 `--direct` | game_sel 0/1 无精灵输出；实体卡带路径及显式回菜单 |
| `python3 tools/d5_menu_verify.py` | 菜单条生产过程读取、返回、清表和视频故障回退 |
| `python3 tools/sdram_clock_binding_verify.py` | D10 时钟修复保持；实际工程顶层 Icarus 展开，零隐式网络警告 |
| `python3 tools/yxv_d3_verify.py --frames 2` | 实际顶层循环含第 3 帧；460800 解码写字、1986976 扫描像素、4001 PCM 样本零差异；48kHz/SD 预算/退出 |
| 同上 `--frames 72 --no-build --bad 1` | 坏头回退及真实 UART 诊断字段保留 |

视频 pipeline/loader/decoder、SD reader、SDRAM 控制器、照片 player、WAV player、字体、
logo、menu_ui 与 D10 保持字节一致。本轮未重跑 72 帧长播放或完整 PCM 预载；修改集中在
包装层与遥测，已完成上述针对性回归。SD/PLL/FIFO/SDRAM 为功能模型，不是板上时序结果。
原始日志、源码/测试输入哈希及范围见 [evidence/D11](evidence/D11)。

## 6. 统一构建

```sh
git switch feat/unified-menu-photo-video
git pull --ff-only
python tools/prepare_unified_td.py
```

本工程现在注册 **64 个输入**；generator 强制检查 font/menu/logo 均在，两个硬件游戏
不在列表，记录所有源文件 SHA256 和实际检出路径。使用生成的完整 build_full.tcl，
重新 syn/phy，并以新 TD 总 LUT、BRAM、时钟 slack 为准。云端未运行 TD，未生成 bit。
