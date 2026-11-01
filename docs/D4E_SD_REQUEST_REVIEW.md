# D4e：连续读与初始化语义审查（2026-11-01）

基线 feat/mjpeg@0f41ef1。用户 D4d 两组板测：旧文件头 word5 多3996B，转换器已修复并重写卡；新文件头全通过，后续出现 BUSY=1、DNE由1变0、DIV=3E、SST冻结、F=A、PCM/解码尚未开始。**本轮不能由这些值宣布板上首故障的具体错误码，也不能把SST=520当错误码。**

## 1. 回答：restart 是否重新初始化？

**不会。现有 reader 已经是 init-once；无需也不应加一个“DNE=1则跳过CMD0”的修补。** DNE不是初始化有效标志，也不能用作跳过初始化的门禁。

真实请求链：MEM loader `sd_valid/lba/count` → 44bit mailbox → SYS `source_valid && source_ready` → `sd_start`（先锁存LBA/count）→ 顶层 `.restart(video_owned ? video_sd_start : ...)` → probe `restart_hold` → `reader_start = trigger_rise & init_done & ~busy & ~legacy_inhibit` → stream core `start`。

core只在复位后的 ST_INIT_START 发 `ctrl_start/mode=0`；ST_INIT_WAIT收到ctrl_done后置init_done=1进入IDLE。IDLE接start只复位本次LBA、计数和RAM读地址，进入READ_START，发 `ctrl_start/mode=2`；每个后续sector也只发mode2。多扇区完成回IDLE，init_done一直保持1。正常start不存在进入ST_INIT_START的边；异常状态的default恢复和真正rst会清init_done并重新初始化。

探针的 **DNE=dbg_done_latched** 在reader_start时清0，reader_done时置1；真正init_done在F的bit2。7扇区表读取、7594扇区PCM读取各是一笔stream事务，因此DNE会在其间保持0直到整笔结束。不是每个512B扇区完成都置DNE。

## 2. DIV=3E 与卡带38次读取

原SD控制器IDLE=4。IDLE时 `select_num <= nxt_state[1:0]`；继续IDLE的低2bit是00，因此选择初始化侧输出、多路器给低速DIV=62=0x3E，但 **init_start=(state==INIT=0)** 此时为0。空闲选择INIT信号组不等于发起初始化。core排空已读RAM期间可以BUSY=1、DIV=3E、SST不涨；若下游不ready会持续如此。

卡带与视频共用同一reader；多次正常读取均保留真正init_done。卡带加载完成后保持空闲，DNE自然恒1；这与视频首笔完成、紧接下一笔清DNE并不冲突。如果“38读”指一笔请求内38个sector，DNE只在整笔结束后置1；如果指38笔独立start，DNE必在每笔start清0、每笔完成再置1。周期级断言比最终UART采样更能区分两者。

本轮38笔合成卡带式事务验证不是重跑真实卡带游戏，不能把它宣称为新的WC/PC/SP板测。它证明接口语义，且视频动态count=1/7/7594与普通count路径使用相同初始化状态机。

## 3. F=A 真正说明什么、谁能使SD复位

F的现定义是 `{owned,init_done,busy,handoff}`，A=1010。因此用户这条F确实表明 **真正init_done已为0**，不能只用“DNE正常清零”解释全部现场。

顶层实际复位源：`sd_rst = video_sd_reset | ~rst_n | !por_done | flush_active | (sd_retry_pulse!=0) | (busy_kill!=0)`。

- video_sd_reset = owned && abort_sys[1]，abort_sys是MEM首fault到SYS的两级同步。loader错误91/92/93、PCM读95、decoder错误、AV9E、无进展9F都可触发。它**与新读restart无关**。
- busy_kill：busy连续达1,000,000,000个50MHz周期（约20秒）后，SD复位8周期。它会重新初始化，不能误称restart触发。
- sd_retry_pulse：首次成功初始化之前约5秒重试，sd_seen成功后永久禁用（直到rst_n）。其重试还会重启flush。
- por_done/flush是上电流程；全局rst_n则复位整机。正常初始化成功后，它们不应因新读而重新触发。
- 另有core非法状态default恢复；必须与正常start区分，不能凭DIV推定。

重要候选链：**PCM/SDRAM先停顿→首fault→abort_sys→SD被持续保持复位→init_done=0、busy=1、SST冻结**。若已等待的内存事务无法完成，quiet不成立，owned保持1，failed尚未置1；原D4d直到owned释放才输出diagnosis，故这种现场仍可能MISE=0/SP=BB80。这里SD复位是首故障之后的结果，并非CMD0/ACMD41主动运行。不能屏蔽rst去掩盖它。

## 4. D4e 唯一生产逻辑变化：提前显示首fault

不改SD请求、restart、初始化、厂商文件、SD频率、两拍排空、SDRAM仲裁或退场策略。

MEM已有首fault冻结寄存器保持不变；SYS收到两级fault后立即把稳定冻结快照写到已有diagnosis/detail/count/index/word寄存器，不再依赖quiet/owned释放。输出error_code同步更新；failed的控制语义完全保留，仍只在实际释放后置1。顶层以 `video_failed || diagnosis低8bit非零` 决定显示故障字段。

| 字段 | D4e含义 |
|---|---|
| MISE | 高8bit loader/故障阶段，低8bit首fault；沿用D4d编码，即使owned=1、ERR=0也有效 |
| SP / ACC / WC / D5 RSP | 沿用D4d原因/计数/坏字段快照，发生首fault后立即可见 |
| **LS（视频上下文）** | **bit2=实际sd_rst、bit1=video_sd_reset、bit0=真正init_done**。LS=6表明正被视频abort持续保持复位；正常初始化后无复位为1 |
| F | 保留owned/init_done/busy/handoff，LS=6且F=A支持“持有所有权期间abort复位”的判断 |
| ERR | 保留video_failed含义；pending fault时仍可能0，不能单独用ERR排除MEM已发生fault |

若板测LS=6，先解MISE低8bit：91查PCM写口错误；9F按MISE高byte和SP/ACC查缺数据/等待写命令/写数据或done；93查表。若LS=0且F=A且MISE无fault，检查真实CTRL/INIT/RD/SEL及复位短脉冲/非法状态，不能归因abort。若LS=4，表示非视频复位源当前有效，应同时看FLU/KIL/RET/POR。若bit0=1且LS=1，则卡仍已初始化，DNE=0是本次读尚未结束。

请取故障后两条稳定的完整A/B/C/D帧，至少保留 **LS/F、MISE/SP/ACC、CTRL/INIT/RD/SEL/DIV、FLU/KIL/RET/POR**。B帧RSP的D4前缀是保留的首magic，不是实时CMD0响应；SST是累计SPI start上升沿数，冻结值520不能定位指令。

## 5. 可复现判据与限制

1. `python tools/sd_restart_verify.py`：实际probe+reader+core、事务级SD服务模型。38笔普通count读取，再按视频动态count=1/7/7594读；逐字节/偏移/LBA比对、含ready停顿。要求总41笔、7640个sector、3911680B零diff、mode0仅1次、init_done在成功后零下降、后40笔DNE清零40/40。另独立实例化未修改真实vendor controller，验证IDLE CTRL4/SEL0/DIV3E但init_start0；mode2无卡响应时停留读侧而非init。
2. `python tools/yxv_pending_verify.py`：486帧真实规模表载入后，PCM首32B形成8word写命令，故意不给cmd_ready，等待实际STALL_LIMIT故障。**修改前**复现F=A、owned1、failed0、reset1但diagnosis0000；**修改后**要求同一故障路径MISE929F、ACC020在owned释放前稳定可见。仅抽象SD服务，不声称重现板上SD电气问题或已找到板上首故障。
3. `python tools/yxv_d3_verify.py --pending`：实际板级top，测试专用force保留PCM命令并注入9F，验证真实115200 UART在owned1/failed0时可见MISE低9F、LS6、FA。此项用于验证UART接法；首fault自动产生由上一项验证。
4. `python tools/yxv_diagnostics_verify.py`：原17例加真实事故形态（PCM尾巴3996B）为18例；reason06/WC486/D5实际PCM长度必须保留。旧内容拒绝契约正确，但此前只有合成素材，未覆盖ffmpeg尾巴，是测试覆盖不足；不放宽头校验掩盖问题。转换器修复由用户确认，本轮不声称修改了转换器。
5. 顶层正常短程和坏头回退回归，确认提前显示不改变正常出图、音频和回退。未执行TD/板测，不把本次软件通过称为板上楔死已修复。

本轮仅SYS诊断寄存器写使能及UART选择改变，没有新RAM/DSP或像素域路径；面积/时序仍需本地TD实测。原始输出见本轮evidence目录。
