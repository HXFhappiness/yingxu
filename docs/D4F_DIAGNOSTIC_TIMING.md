# D4f：诊断快照分拍、恢复 mem_clk 时序验收（2026-11-01）

基线 feat/mjpeg@0018a81（D4e）。用户提供TD对照：mem_clk=100MHz域新增10条负slack，全部从loader/assembly_reg到D4d引入的debug寄存器，最差−0.765ns；冻结P0同域零违例。另10条TMDS/LVDS历史违例独立，不将它们混入本次判决。

**D4f优先修诊断时序，生产RTL只改 `yingxu_yxv_loader.v`。不将尚未证明的SD协议假设写进修复，也不叠加新的物理遥测。TD与板测尚未执行；不能先宣称mem_clk已零违例或楔死已消失。**

## 1. 本次现场的正确解码

`MISE=949F`：低byte9F为无进展超时；高byte94=`{purpose=2,state=2,mstate=2,invalid=0}`，即PCM/RECEIVE/写数据或等待完成/无格式错误。

`SP=0001`：reason=0；rx_complete=0、ack=0、当前sd_done=0、sd_valid=0、sd_ready=0、filled非0、mstate非0，且MEM字节FIFO有效。说明PCM写事务已接受、loader正在背压后续SD字节；不是停在头校验或SDREQ。`ACC=020`是**当前传输已收字节数mod2048**，可以是32、2080等，不能据它断言第一笔写，更不能当作头512B计数。

`LS=6/F=A` 是首fault之后video abort持续保持SD复位的结果；从这个复位后的状态不能倒推出首fault之前SD从未回idle。SD RAM排空被下游背压时，reader BUSY与无SPI新时钟也可同时出现。SST/SDN均为累计SPI边沿计数，不当作error或扇区个数。

## 2. 7594不会在现有请求链中溢出

| 信号/计数 | 位宽 | 本素材/上界 |
|---|---:|---|
| loader `pcm_sectors` | 14 | 7594；512帧最多8000 |
| loader请求扇区数、44bit邮箱低段、SYS sd_sectors、probe dynamic_count | 16 | 原样传递7594 |
| reader sector_count / sectors_left | 16 | 7594逐sector减至0 |
| reader current_sector / ctrl_sector_addr | 28 | 每次向vendor发一个sector的mode2命令 |
| loader expected/count | 22 | `{sectors[12:0],9'd0}`；7594/8000均<8192，3888128/4096000均<4194304 |
| reader byte_count / stream_byte_offset | 32 | 可容纳本次完整字节流 |
| cart WC | 10 | CPU卡带词计数，与SD sector_count无连接 |

486帧PCM有效3888000B，ceil512后7594扇区=3888128B，末尾128B不进入音频播放。SDRAM word地址100000到1ED4FF可容纳本次补齐预载，仍在8MiB内。SD物理初始化和按sector读命令层完全保留。

## 3. 实际修复：诊断专用两段路径

旧路径把表项判定、优先级编码、观察值三选一、first-error门控全塞在同一拍：

`assembly/SD byte → 表项比较/末端加法 → entry_reason优先级 → entry_observed选择 → remember输出寄存器`。

新路径在表项第8字节被接受时：

1. 直接寄存raw offset32、raw size32、audio_end20、index10及8个**并行**错误谓词；捕获使能仅由表项接收位置决定，不再由entry_reason控制宽数据。
2. 下一MEM拍从这些诊断专用寄存器选择reason/observed/index并调用remember。宽字段选择直接使用寄存的flag，绕开“原因编码→再次比较原因→选择字段”的串联。

新增102bit诊断寄存器。原invalid/error_code、表BRAM写入、SD/SDRAM状态机、握手及所有功能计数不变；头字和SDRAM错误原有remember路径不变。D4e的首fault MEM冻结、SYS提前显示、owned/failed/abort行为和UART字段编码均保留。没有新增CDC，也没有pix路径、频率或约束变更；不使用false_path掩盖违例。

最坏边界时序：在最后一个字节的T边沿标记invalid并捕获诊断候选；T+1发布reason/word/index，同时FINISH最早才置loader_failed；T+2 pipeline fault；T+3冻结首fault。诊断在冻结前已稳定。done提前4拍/同拍/晚16拍、错误位于扇区最后一字节的用例均必须验证，避免为了时序修复而漏首错。

## 4. 验证方法与可判定结果

- `python tools/yxv_diagnostics_verify.py`：原18例加3种最后字节坏表项done相位、6种表项原因/优先级用例，共27例。覆盖可达的11…17原因及多错误优先级；10的entry_index≥512被有效头frames≤512与表范围门控排除，不用不可达刺激冒充自然用例。必须逐字段正确且owned释放/MEM复位后仍保留；包括用户实际事故形态PCM尾巴+3996B。
- `python tools/yxv_pending_verify.py`：D4e的PCM命令未接受就超时用例，必须仍在owned1/failed0时读到929F/ACC020，保留提前显示机制。
- `python tools/yxv_d3_verify.py --bad 1` / `--pending`：真实top及115200 UART校验。正常短程用 `--frames 2`，不冒充重跑3秒播放。
- `python tools/yxv_preload_verify.py`：生成非版权合成486帧素材、非零并跨sector变化的PCM；实际probe/reader（默认两拍排空）、SYS50↔MEM100 CDC、完整pipeline、两层仲裁、四口控制器及原command/control/data层共同工作。SD服务模型按1.30MB/s供给并实际写512B RAM；PHY/FIFO/PLL/外部卡以模型表示，不能声称pin级SD时序或板测已复现。必须读1头+7表+7594 PCM，972032个SDRAM字逐字零diff，121504个8字突发完成，成功初始化后init_done保持1。
- 同一preload测试 `--block 1/2/3/4` 分别不给首写数据、给4字后背压、以LOAD阻止物理授权、丢弃完成回执；四者均要求949F/SP0001/ACC020/FA。它们用于证明旧现场码不能唯一判成SD问题，不是板上根因断言。正常写完成周期用比值 `max_latency/1000≤1` 验收；不要只数完成个数。
- `python tools/yxv_d3_units.py`：物理侧口、36/512帧完整表/PCM/回绕、scanout和PCM单元回归。
- `python tools/yxv_d4f_structure.py`：Anlogic native LUT代理及组合锥检查，自动确认assembly至最终debug寄存器的原组合通路在新版本被打断。功能验证使用上述逐点回归，不宣称已完成形式等价证明。代理映射和组合路径断开不能替代TD的10ns检查。

## 5. TD/板测门禁（本地执行）

先构建此提交，确认 **mem_clk/clk2 100MHz零负slack**，并检查新diag_entry_*寄存器的端点，而不只是旧debug_*端点；记录最差起点、终点及slack。任何mem负slack仍存在就停在D4f，不解释为板上协议结论。TMDS/LVDS历史路径单独保留对照，不以其同款历史违例替代mem验收。

时序干净后用修复后的同卡同内容板测：

- 楔死消失并完成PCM/解码/播放：支持诊断负载/时序回归判断，保留报告、遥测和位流对应关系。
- mem干净但949F仍稳定：继续PCM写数据/物理授权/done二分；本版没有叠加SD参数或仲裁改动，能保持判决单一。
- 干净构建中的其他fault：按原D4d/D4e的MISE/SP/ACC字段诊断。早期RSP=D4仍是首magic保留值，不是实时初始化响应。

本地TD是下一门禁，云端交付源码/自动化/原始日志；不生成或声称已烧录固件。


## 最终软件结果（生产RTL 6823dce）

27项诊断、最后字节坏表项的早/同/晚done、首错保留及D4e提前显示均通过；真实top坏头回退和pending UART通过。正常短程4001采样/83,333,334ns、0/2丢帧、AV1849/2000，460800写字、1985280扫描像素与HDMI4000样本零diff，48k误差0ppm，退出照片一次。36/512帧loader及PCM/回绕、scanout、物理端口单元通过。

完整486帧/7594扇区预载在本次源码下通过：3888000B有效PCM、3888128B补齐，121504/121504突发、972032/972032字零diff；首写31拍、最大44/1000拍，init_done=1、failed=0。四种受控写等待也都产生949F/SP0001/ACC020/FA，不能用该码唯一归因SD。完整预载仿真约3秒，不把它称为3秒播放测试。

Anlogic native代理中loader计费1373→1338 LUT4（−35）、566→668寄存器（+102）、BRAM2→2；DSP本模块为0且未新增乘法。映射图自动确认旧assembly至最终debug寄存器组合通路存在、新版该直达组合通路不存在。此结果不等于TD slack，特别要查新diag_entry_flags/diag_audio_end等端点。

原始输出、源码/向量哈希、代理统计及 [verification.json](evidence/D4f/verification.json) 在 [evidence/D4f](evidence/D4f)。生产RTL仅loader修改；后续文档/测试提交不改变6823dce的生产代码。未执行TD或烧录，不宣称板上根因已结案。
