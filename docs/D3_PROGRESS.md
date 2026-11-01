# D3 分步记录

2026-11-01，基线a35f9ef；TD/板测由用户本地完成，以下均为软件仿真。

- 文档027060b已推；物理适配917d97e已推。真实自研四口状态机+原样厂商command/control_interface/data_path参与，逻辑1…8word→固定8物理word，DQM保护尾字，读写反压及显示优先级通过。测试模型替代PLL/FIFO/SDRAM介质，不替代自研调度或done。
- SD供给单元：YXV表36帧、288000B PCM预载逐字节零diff，JPEG槽0/1/2与原帧表逐字节一致；坏magic读完整扇区后错误92，停止后续请求。默认SD探针仍5401扇区，动态LBA/count入口只在显式启用时生效。

原始输出（tb_yxv_loader，Verilator，exit0）：

```text
SUPPLYCHK: PASS frames=36 PCM=288000 bytes zero-diff JPEG=0,1,2 exact table-indexed commands=5
HEADERCHK: PASS bad magic code=92 finite reject drained-SD
```

后续：连接100/50MHz CDC、显示消隐交换、WAV字节适配、顶层开关/遥测与3秒验收。尚未宣布D3整体验收通过。

## 显示单元

`tb_yxv_scanout`双缓冲窗口检查：frame0红/蓝、frame1绿/白，高半字先出，消隐才交换，LOAD保持256pix周期覆盖旧128字物理burst尾部；新端口开启且视频活动时RD2 FIFO复位，旧参数关闭行为保持。颜色选择在原player的既有RGB输出寄存器入口，不串入亮度/对比度或sprite组合链。

```text
SCANOUTCHK: PASS centered640x480 high-half-first both banks pixels=306240/305602 vblank swaps=2 stretched flush no-underflow
```

该单元测试覆盖窗口内部并剔除流水边沿，完整图像/帧率/AV仍以最终顶层3秒TB为门禁。

## 音频单元

PCM读口经100/50MHz异步FIFO，生成32B虚拟YXMA头，直接使用原WAV解析、FIFO、增益及输出逻辑。仅增加真实pop观测端口，不改变原WAV消费行为；EOF后再次发头，连续循环。

```text
PCMCHK: PASS pops=512 source_samples=128 loops=4 zero-diff L/R including EOF virtual-header reuse-WAV 48k
```

完整顶层正在接线，尚未宣布3秒集成门禁通过。

## 集成前资源缩减与边界复测

帧表内部改为512×35（19bit扇区偏移+16bit精确JPEG长度），BRAM结构映射由4块降为2块；容器外部格式、512帧上限不变。按32bit流式检查头字段，复用byte assembler，不保留多读口头RAM；最后PCM结束位置也检查256MiB槽边界。PCM地址/字节计数按4MiB约束裁位，虚拟YXMA头改固定slice，仲裁地址改显式三选一。

```text
SUPPLYCHK: PASS frames=36 PCM=288000 bytes zero-diff all packed table entries JPEG through wrap zero-diff commands=40
SUPPLYCHK: PASS frames=512 PCM=4096000 bytes zero-diff all packed table entries JPEG through wrap zero-diff commands=517
HEADERCHK: PASS bad magic code=92 finite reject drained-SD
PCMCHK: PASS pops=512 source_samples=128 loops=4 zero-diff L/R including EOF virtual-header reuse-WAV 48k
ARBCHK: PASS grants=5 priority=display>decode>other owner-until-done stalled-command-stable error-routed
```

scanout在第一帧发布/预充之前禁止RD2弹出，避免启动空FIFO被记为欠载。两bank颜色与消隐交换单测重跑通过。完整3秒顶层门禁和总面积账随最后集成提交提供。

## 最终顶层交付

696bde3已推。最终3秒actual-top门禁通过：144001音频采样、0/72丢帧、AV1849/2000采样、实际HDMI音频144000采样零diff、14条真实UART D帧；坏头/初始化超时回退均通过。完整报告及原始输出见 [D3_MJPEG_REPORT.md](D3_MJPEG_REPORT.md)。估计8740 LUT / 7 BRAM / 21 DSP，未做TD与板测，资源余量341 LUT须本地严守门禁。


## D4a / D4b审查（2026-11-01）

已快进合入372005d/612fe6c，仅补文档。SW77实际top短测在帧0正确解码后触发compositor mismatch，退出非零；入口restart并非直接初始化触发，且新组合下照片回退被game_mode门控。用户TD实测余7414 LUT，撤下旧341余量的当前结论；完整decoder保留和时钟归属待报告。详见 [D4_REVIEW.md](D4_REVIEW.md)，不标D4验收通过。


## D4c交付

设计1596178、实现162e91f；77/E7完整3秒均通过，0/72丢帧、AV1849/2000，四种错误回退和SD排队交接通过。板测首OFF/WC/RSP字段与完整证据见 [D4C_REPORT.md](D4C_REPORT.md)。TD及真实SPI待用户本地验收，不再将旧F/响应快照误当唯一初始化结论。


## D4d诊断交付

用户板测已确认D4c首读及回退，失败收窄到首扇区后。318ceb7只加MEM/SYS故障冻结和早期UART字段：MISE低8错误/高8阶段、SP原因/握手标志、ACC接收计数、WC帧数或坏表项、RSPD5坏字段。17例注入、36/512表/PCM与真实UART留存验证通过，正常短程图像/HDMI音频通过。具体486帧首扇区后的7扇区表→PCM→JPEG顺序和判读见 [D4D_DIAGNOSTICS.md](D4D_DIAGNOSTICS.md)。


## D4e：连续读与首fault可见性（2026-11-01）

源码44ad637。确认reader正常restart已是init-once，DNE是每笔读完成锁存、DIV3E也可能是idle，F=A才表明真正init_done为0。复现PCM命令未接受→9F→持续SD reset、owned无法退出、D4d诊断仍0000的盲点；仅提前公开既有快照，视频LS={sd_rst,video_sd_reset,init_done}。38笔普通与1/7/7594动态count、18项诊断、pending实际UART、正常短程和坏头回退通过，原始证据见 [D4E_SD_REQUEST_REVIEW.md](D4E_SD_REQUEST_REVIEW.md) / [evidence/D4e](evidence/D4e)。未更改厂商层/读调度/退场，不宣称板上根因已确定或楔死已修复。


## D4f：诊断时序隔离（2026-11-01）

生产RTL6823dce，仅loader：表项raw字段与并行错误谓词先寄存，下一拍再选reason/word/index，打断assembly→remember的长组合锥，保留D4e提前显示。用户TD指出D4e mem100域10条诊断路径负slack、最差−0.765ns；本轮必须由本地TD复验mem域零负slack后才作板测判决。未叠加SD/仲裁/物理遥测改动。

27项诊断、正常短程及实际UART回退/pending、36/512帧单元通过；完整7594扇区972032字/121504突发零diff，最大写等待44/1000拍。代理−35 LUT4/+102FF/BRAM不变，旧组合锥已在映射图断开，非TD时序结论。949F表示PCM写已接受后的等待；ACC为mod2048，不能据020断言首写或头阶段。见 [D4F_DIAGNOSTIC_TIMING.md](D4F_DIAGNOSTIC_TIMING.md) / [evidence/D4f](evidence/D4f)。


## D4g：删除数据快照，TD门禁优先（2026-11-01）

生产RTL6e84711。接受用户D4f TD FAIL（同类mem负slack最差−0.765ns）；D4f代理检查不足以覆盖头字/写错remember与TD实现，不能当作mem干净基线。D4g删除loader候选数据/word/index、pipeline MEM/SYS word/index及D5输出；仅从已有功能寄存器取compact reason，93统一B8，保留D4e首fault提前显示及phase/flags/ACC。

27例、真实UART坏头/退场未完成、正常短程与36/512帧相关单元通过。loader代理−258 LUT4/−146FF/BRAM不变，不是全工程TD或时序结论；必须本地确认mem100零违例才烧写。见 [D4G_COMPACT_DIAGNOSTICS.md](D4G_COMPACT_DIAGNOSTICS.md) / [evidence/D4g](evidence/D4g)。


## D4h：previous_end写使能去内容校验（2026-11-01）

生产RTL0f50ee6，仅loader移动一条赋值：完整表项到达即更新候选previous_end，校验仍读旧值，坏表不提交且invalid锁存后不再使用候选。保留全部范围/重叠检查、D4g快照删除、时钟域和约束。用户D4g诊断端点已清零，余1条assembly→previous_end.ce −0.221ns；本轮仍须TD mem100整域零违例后烧写。

27例及10/10拒绝不变量、36/512帧表/PCM/回绕、正常短程和pending真实UART通过。代理+2LUT4/FF与BRAM不变，raw数据至previous_end.CE锥在代理中断开，D端仍有计算，非TD时序通过。见 [D4H_PREVIOUS_END_ENABLE.md](D4H_PREVIOUS_END_ENABLE.md) / [evidence/D4h](evidence/D4h)。
