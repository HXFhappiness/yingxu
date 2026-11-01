# D4i / D5：写等待控制位诊断与 TD 菜单条读取兼容改写

基线：`feat/mjpeg@c1738d7`。本交付不改变 SD 频率、SDRAM 调度、握手或时序约束。云端没有安路 TD；下述软件验证不能替代本地 syn/phy 和 mem_clk 时序验收。

## 故障诊断编码

仅在视频故障诊断有效时，D 帧 `I1[10:0]` 改为首故障控制快照：

| I1 位 | 来源 | 解码 |
| --- | --- | --- |
| 10:7 | loader.sent[3:0] | 0…7 = 已送出字数，仍在发送；8 = 8 字已送齐，loader 等回执 |
| 6:4 | 物理 burst adapter.state[2:0] | 0 IDLE、1 COLLECT（收集 loader 的字）、2 WAIT（等物理授权）、3 TRANSFER、4 DRAIN（读返回） |
| 3:0 | 物理 burst adapter.position[3:0] | COLLECT 时已收字数；TRANSFER 时已服务的物理拍数，8 = 已齐、等 phy_done；其余状态按原 FSM 值解释 |
| 23:11 | 常量 | 0 |

软件解码：`sent=(I1>>7)&15; state=(I1>>4)&7; position=I1&15`。

MISE 保持阶段+错误码，例如 `949F` 仍为 PCM / RECEIVE / mstate=2 / watchdog。SP 原因和等待 flags、ACC 收到字节数、WC=0、RDT=0 均不改。正常视频的 I1 仍表示样本进度，不能用控制位规则解码。

新增的只有两个 11-bit 首错寄存器（MEM 冻结和 SYS 保留）；源为已有功能寄存器 sent/state/position 的直接连线，不读取 SD byte/assembly、不做额外数据校验、不恢复被 D4g 删除的宽数据快照。复用原稳定快照跨域和提前发布机制；诊断不是实时总线追踪，故障后功能状态变化不覆盖首错。清除沿用原复位/退出会话语义。

实际控制器参与的六种注入均保持 `MISE=949F SP=0001 ACC=020`，新 I1 分别为：

| block | 注入 | I1 | sent / state / position |
| --- | --- | --- | --- |
| 1 | 不给首个写数据 | 010 | 0 / COLLECT / 0 |
| 2 | 给 4 字后背压 | 214 | 4 / COLLECT / 4 |
| 3 | 禁止物理授权 | 420 | 8 / WAIT / 0 |
| 4 | 丢失上层完成回执 | 408 | 8 / IDLE / 8 |
| 5 | 已授权，禁止数据拍及物理 done | 430 | 8 / TRANSFER / 0 |
| 6 | 物理 8 拍已齐，禁止物理 done | 438 | 8 / TRANSFER / 8 |

后两例区分“物理送数未开始”和“等待物理完成”。4 与 6 区分上层回执丢失和物理 done 未到；这些是注入判据，不是对现有板上 949F 根因的断言。每例捕获后强制源控制位变化，仍检查首错快照不变。

## D5 读取崩溃范围与改写

用户提供的 TD 二分结果：D4h、v1（虚拟 DIP）、v2（顶层菜单分支）通过；完整 D5、v3（只加入 wrapper FSM/线束，不改 mux）、v5（提取 reduction AND）均在 read_design 崩溃；v6 禁用 bar_we 且删除 bar_y 三元链后通过 syn。由此定位到 wrapper 菜单条写通路，**尚不能仅靠该二分在 bar_we 与 bar_y 两者间证明唯一触发语法**。

本版恢复有效写通路，将 clocked bar_y 的嵌套三元链改为显式 case，保留五个原坐标 268/355/442/529/616、slot15、12×56 绿色条及原 mux。用像素域稳定后的选择值同时生成写脉冲与坐标；清表结束立即重写，不再等 2^23 周期；退出菜单写 en=0，避免条残留在照片上。保留 bisect-d5 的 source_ready_mem 声明前移修正。

配套仿真发现并修复 c1738d7 的功能遗漏：菜单寄存器缺复位、sw_real_q 无更新；加入首拍采样有效位以免上电非 FF 的实体 DIP 直接退出菜单。补齐 idx0 菜单 LBA76032、原八图顺移、IMG_COUNT9、load_idx 复位；修正游戏虚拟开关为 1F（卡带流浪者）、音乐为 6F，视频仍77。照片确认进入 idx1；照片翻页可回菜单；各模式长按 key0 2s 返回；菜单视频失败返回 idx0；实体 DIP 改动保留维护直通。菜单态 WC[3]=menu_override、WC[2:0]=menu_sel；视频故障 WC 不变。

保留 c1738d7 的矩形菜单条作为本次兼容改写对象，没有加入仓库缺失的 arrow_cursor.bmp/BRAM 箭头资产。“关于”仍是任务书约定的占位项。此次测试验证控制和表写通路，不声称已验证真实菜单背景的像素或板上箭头素材。

## 可复现验证

先激活 Icarus；Python/Node/ffmpeg 由基础镜像提供，Verilator 5.032、Yosys 0.52（含 yosys-abc）在 /workspace/.yingxu-env 的用户目录。

- `python3 tools/d5_menu_verify.py`：通过。实际 hardware_test + wrapper 验证上电（实体 DIP=77 仍先入菜单）、五档循环/坐标、boot wipe 后恢复、退出清条、照片/卡带/视频/音乐确认、关于占位、长按终点、DIP 直通、视频失败返回。仅加速测试的 key_lock 与 2s 计数器，不替换菜单 RTL。对直接提取的生产菜单条进程做 Yosys read/proc/check，通过；实际顶层由 Verilator 读取/编译。
- `python3 tools/yxv_preload_verify.py --block 1`，其余 block2…6 用 `--no-build`：通过上述六种编码与冻结检查。使用486帧/7594扇区请求，但负例在首 burst 阻塞；**不声称重跑了完整7594扇区正向预载**。
- `python3 tools/yxv_d3_verify.py --write-pending`：通过。实际顶层、真实 UART pad 解码：`MISE=949F I1=000214 LS=6 F=A`，owned=1/failed=0、SD reset 已保持。证明非零控制快照经过实际连线和 UART 格式化路径。
- `python3 tools/yxv_diagnostics_verify.py`、`python3 tools/yxv_pending_verify.py`：通过27项头/表/边界诊断与提前发布。
- `python3 tools/yxv_d3_units.py`：通过真实物理服务16笔1…8word读写、36/512帧表/PCM/JPEG/回绕、scanout 和 PCM。
- `python3 tools/mjpeg_d2_verify.py --prepare-only` 后 `python3 tools/yxv_d3_verify.py --frames 2`：通过短程4001音频样本、460800解码写字、1985280扫描像素、HDMI4000样本零差异、48k误差0ppm、退场一次；不冒充3秒全程回归。
- `python3 tools/yxv_d4h_structure.py`：通过。previous_end CE 无原始 assembly/SD byte 组合来源；loader 的 word/index 常量端口保持。此为 Yosys 结构代理，非 TD 时序。

精简原始日志见 [evidence/D4i_D5](evidence/D4i_D5)。顶层回归在启动菜单后通过实际 DIP 变化进入旧维修直通场景；未绕过新的上电菜单逻辑。旧 TB 的数字截断等历史 warning 保留，不视为本次新增错误。

## 本地构建板测

构建 feat/mjpeg 新 HEAD，先确认 TD read_design/syn 完成，再确认 mem_clk/clk2=100MHz 零负 slack。特别查看新增 frozen_write/fail_write 的寄存器输入及 sent/state/position 扇出；不改变历史 TMDS/LVDS 路径或用例外约束豁免本次路径。

云端不宣称已复现安路读取器崩溃或 TD 修复已通过：本版是依据二分范围的兼容改写，需本地 TD 结果闭环。若仍崩溃，请保留本版与 v6 对照结果，下一步只二分显式 case 坐标写和常量 bar_we 写，不回退到删除完整菜单。

时序通过后板测：上电菜单/五档/各模式/长按返回；随后切换实体 DIP 到77维修直通复测原949F。记录同一 D 帧的 MISE/SP/I1，按上表判断 loader 与物理口停在哪层。维修直通可保留视频故障诊断；从菜单进入的视频失败会退出会话回菜单，沿用会话退出后的诊断清除行为。

