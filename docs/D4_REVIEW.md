# D4a / D4b 审查与板测补记（2026-11-01）

审查分支feat/mjpeg，已快进包含用户提交372005d和612fe6c。本次只更新文档与取证日志，不代改RTL、测试台或厂商IP。结论：入口单拍的意图可以保留，但**当前两提交不能标为初始化/视频集成验收通过**；下列阻塞项需要先解决。D3旧E7组合的软件结果不适用于D4新77组合。

## 用户板测记录与资源纠正

用户报告：视频模式只有背景，ERR=1、DNE=0、RSP全FF，重试125次后停；同卡同槽卡带模式正常。用户本地将入口restart钳0列为根因并提出D4b，尚不能把该描述视为云端已独立证实的协议根因或修复后板测结果。

| 用户提供的D3构建数据 | 数值及口径 |
|---|---|
| LUT | 12186 / 19600，62.17%；**剩余7414** |
| 相对冻结10519 LUT | 增量1667；不是增量7400 |
| BRAM | 41 / 64；相对39为+2 |
| DSP | 0；相对0为0 |
| Fmax | 74.6 / 76.2MHz，待原始报告标明对应时钟域/构建版本 |
| TD phy | 用户今日5/5启动即崩，均以phy-only重跑恢复 |

上述是用户提供的实测，不是本次云端综合。旧“8740 LUT增量、只余341”是代理估算，不再作为这次构建的实际余量。原估算文件保留历史，不能覆盖实测。但DSP0、BRAM仅+2明显不同于完整decoder预计的5块RAM+DSP乘法，须查综合层次、删除逻辑报告及实际工程源清单，确认decoder/IDCT/RGB没有因不可观察输出/配置被删除；不能仅用小面积证明整个解码器资源已经验收。

Fmax不能脱离域归属宣布时序通过：pix目标约73.33MHz，mem目标100MHz；如任一个数属于mem100域则未达标。phy-only是本地构建工具恢复措施，不是RTL修复，也不证明前后配置完全相同；保留失败/重跑日志、最终bit哈希与对应git版本。

## 1. 阻塞：新开关组合仍进入游戏显示分支

D4a指定组合为SW7 ON、SW3 ON、SW4/5/6 OFF；其余OFF时管脚SW=0x77。遵从用户演示选择，不恢复旧E7组合。

然而新条件要求game_mode=1，hardware_test仍将该原始信号直接接design_top_wrapper.I_game_mode。后者在S_base_rgb处优先执行 `I_game_mode ? 24'h000000 : ... S_player_rgb`，会覆盖已由video_owned选出的有效视频RGB。游戏sprite/tile等控制也仍按游戏模式运行；请求条件不与音乐/卡带相交，不等于显示模式已独立。

已对**372005d**实际top运行 `python tools/yxv_d3_verify.py --frames 2`，退出非零：

```text
TOP_FRAMECHK tag=0 cycles=2458703 pixels=307200/307200 zero-diff t=292880975000000
[306455443000000] %Fatal: tb_yxv_top.v:105: Assertion failed in tb_yxv_top: actual replay/compositor video mux mismatch
```

即在约306.455ms，帧0已经正确解码，但实际replay/compositor不符。612fe6c没有修改这些显示分支，静态问题仍存在；本日志不是612fe6c的完整重跑。建议单独处理“视频拥有显示时压过游戏/照片选择并关闭游戏叠加”，并保持pix已有寄存流水边界，再复跑新77组合的完整3秒门禁。

## 2. 阻塞：D4b单拍不等价于重新初始化

实际D4b增加video_req_q/qq和寄存的上升沿单拍，替换等待owned时的restart=0。稳定请求只形成一拍，这部分逻辑形式合理；但请求生命周期及协议解释有三处必须区分：

1. sd_stream_reader_core复位后自行进入ST_INIT_START，主动发ctrl_mode=0/ctrl_start，**不等待reader_start或外部restart**。探针reader_start反而被 `dbg_init_done && !dbg_busy` 门控。因此入口restart不能直接启动或重启尚未完成的初始化。RSP全FF的初始化失败原因，不能仅从原restart=0推出。
2. 管线I_video_sd_init接sd_dbg_init_done（init_done），不是DNE。UART DNE接dbg_done_latched，它在reader_done（读事务完成）后置位。初始化完成与读完成不是同一事件，DNE=0不能单独证明初始化未完成。
3. 上电时若开关已经在77，入口脉冲可能发生在SD上电等待/flush期间。探针restart_hold在sd_rst期间每拍清零；该脉冲不会自动保留至SD复位解除。反之若已有legacy事务busy，脉冲可能被restart_hold保留，在下一次空闲启动旧LBA/旧5401扇区数。owned切换与reader_start若同拍，需验证采样到的是哪一组地址/长度。视频loader未收到自己的命令握手前不消费字节，错误的提前读可造成FIFO满、busy不释放。

所以“单拍”不等于“请求必达/请求被正确接受”。需分别验证冷启动已拨77、初始化后再拨入、legacy busy期间拨入、退出再进入、失败再进入。以实际reader_start的LBA/count及ctrl_mode时间线为证据：首个被视频消费的请求应是LBA3000000/count1，不能多出无人接收的legacy读；SD复位期间请求需保留到可接受，且只能接受一次。是否需要reset重初始化或只需header读触发，应按这条时间线分别修，不混成一个restart动作。

原D3 TB把整个sd_card_control建模成自动完成的扇区服务，覆盖不到真实SPI初始化失败；本次不将旧TB结果冒充该问题的修复证据。

## 3. 阻塞：照片回退条件与新组合冲突

hardware_test.video_photo_reload仍受 `!game_mode` 门控。77组合下game_mode=1，视频失败/释放owned不产生照片重载，wrapper也保持游戏显示分支。必须明确视频失败后有效媒体模式如何变为照片，保持用户指定开关组合，同时验证一次重载、在途事务排空、不自动无限重试。只改restart不能满足此判据。

## 4. 测试断言基线未同步完整

D4a只改TB初始SW为77，tools/yxv_d3_verify.py的UART断言仍硬编码0xE7。后续修复显示后，完整门禁仍会在TELEMCHK失败；应与新的单一模式定义同步，不能删掉该断言规避失败。旧docs/evidence/D3的E7 UART和3秒通过日志继续保留为旧版本证据，不重新贴为D4通过。

## 建议独立门禁

- 先分离视频/游戏显示和失败回退；新77短测应通过实际compositor检查，坏头/noinit应各触发一次照片回退。
- 单独定位启动请求：记录sd_rst、video_requested、entry脉冲、owned、restart_hold、reader_start、init_done、ctrl_mode/start/done、首读LBA/count；先证明请求不会在复位期丢失或启动错误legacy读取，再测真实SPI。
- 同步UART的77断言，完整budget 3秒仍要求0/72丢帧、AV严格小于2000采样、PCM逐点一致。
- 核对综合根与decoder保留、所有时钟域时序、phy-only前后版本/bit哈希，再给板上视频通过结论。

本审查未改RTL，也未把用户正在构建的D4b标为板测通过。源代码已快进合入；**审查尚有阻塞项**。
