# D4d：首扇区后失败定位（2026-11-01）

基线b74cf15（D4c）。用户板测确认OFF=D02DC6C0、RSP=D459585631、DNE=1、首count=1，接管、初始化/首读和自动回退均已工作。当前快照缺完整I0，**不能直接断言本次fault_code具体是多少**。D4d仅补观测，不改SD握手、厂商初始化、SPI12.5MHz、两拍排空、JPEG/显示/音频算法或回退策略；不改main及冻结位流。

## 1. 首512B后实际顺序

固定头32B分8个32bit字边收边检查，随后同一个扇区的表项0…59边收边写BRAM。不是收完512B之后才另外启动表装载。BRAM同步写没有独立done/ack；后续LOOKUP才使用其同步读返回。

首扇区结束后loader在FINISH等待 `rx_complete && ack && mstate==0 && filled==0`。元数据不发SDRAM写，正常mstate/filled都为0，关键只有：MEM实际握手计数满512、SD读完成经跨域mailbox返回并锁存ack。UART DNE=1是SYS探针reader_done的历史锁存，不能代替MEM ack或证明MEM已消费512字节。

486帧：表共32+486×8=3920B，按512补齐4096B，因此首扇区之后依次：

1. 若头或前60表项无效：读完扇区并等ack后报92/93，不发下一请求。
2. 若有效：请求LBA3000001、count7，补完表项60…485并记录末帧对齐末端audio_off。
3. 预载PCM到SDRAM word地址100000；若486帧精确20.25秒，应为3888000B，读7594扇区，尾部补齐不进入音频消费。
4. PCM预载完才进入SELECT→LOOKUP→PREPARE，按表请求首JPEG到双槽；按486帧标准最小布局，首JPEG的LBA为3000008，长度取表，不硬编码。
5. 槽就绪才解码，成功后台才呈现；首两帧及首次前台就绪后才启用原WAV消费。

因此当前全零的decoded/displayed/samples既可能是尚未预载完，也可能是owned释放后local_rst清掉了计数，不能反推此前精确阶段。

## 2. 可能的等待点及错误区别

首512B阶段的候选：SD完成回执未在MEM锁存（FINISH、rx=1/ack=0），或SYS虽完成但MEM字节未收满（RECEIVE、rx=0）。这两类无进展会走9F；不是BRAM写done缺失。若头/表字段不符，分别92/93，通常在完成首扇区及ack后立即失败。

后续SDREQ还可能等待mailbox接收；RECEIVE可能等后续数据；PCM/JPEG写入可等cmd_ready、wready、mem_done/error。只依据现场DNE=1/计数零不能确定哪一项。本次不猜测性修改这些握手，先冻结真实失败现场。

## 3. 新字段：均为十六进制，仅故障时切换

SYS端故障快照在owned释放、MEM local_rst之后继续保持；拨出并清失败后才清除。正常播放时MISE仍是解码计数、SP仍BB80、WC仍首请求count1。

| 字段 | video_failed=1 时含义 |
|---|---|
| **MISE** | 高8位阶段，**低8位精确fault/error_code** |
| **SP** | 高8位首个校验失败原因reason，低8位等待标志 |
| **ACC** | MEM loader本次传输已接受字节数，mod2048；首扇区200=512、1FF=511 |
| **WC** | 92时为内部已解析的frames（reason1…3发生时尚未解析，所以为0）；93时为首坏表项编号；其他0 |
| **RSP=D5xxxxxxxx** | reason非零时xxxxxxxx为首坏32bit字段值；不依赖D帧尾部是否可见 |
| RDT / I1 | 同一个坏字段的高8位 / 低24位，供冗余核对 |

reason=0时不替换RSP，仍按D4c保留D4首magic或原SPI响应；不要把D5字段当CMD响应。D4=原始头4字节顺序（59585631），D5=小端组装后的字段整数（magic期望31565859），字节表示方式不同。

故障时SP不应再固定BB80；若仍如此先核对D4d源/网表/位流版本。原UART逐字符输出，切换瞬间的一条可能混合旧字段，请取随后两条稳定帧。

无需I0/P0也能定位。建议板测直接回贴 **B.RSP、C.ACC、D.MISE/WC/SP**；这些均在已有帧较前位置。

### 阶段与等待标志

一般阶段byte=`{purpose[1:0],state[2:0],mstate[1:0],invalid}`：purpose 0首元数据、1剩余表、2 PCM、3 JPEG；state 0 IDLE/1 SDREQ/2 RECEIVE/3 FINISH/4 SELECT/5 LOOKUP/6 PREPARE/7 FAIL；mstate 0空闲/1等待写命令接受/2写数据与物理done；invalid为校验失败锁存。

保留阶段06=SYS获取所有权超时，0E=PCM读故障，16=decoder故障，1E=AV超期；其mstate编码3不可达，故不会与正常loader阶段混淆。错误91=loader SDRAM写错误，92=头不支持/不一致，93=帧表/范围，95=PCM读，9E=AV，9F=无进展/获取超时，其余沿用D2错误码。

SP低byte各位：7 rx_complete、6 ack、5当前sd_done脉冲、4 sd_valid、3 sd_ready、2 filled==0、1 mstate==0、0 sd_byte_valid。这是首次fault之后、abort改变loader状态之前的快照；reason/坏字段则保留首个校验错误，后续错误不覆盖。对非loader类阶段，SP仅作loader上下文，不能当JPEG错误细因。

### 92：头字段 reason

| reason | 头字编号/字节偏移 | 期望 |
|---:|---|---|
| 01 | 0 / 0 | 31565859（YXV1） |
| 02 | 1 / 4 | 02800201（版本1、双声道、640宽） |
| 03 | 2 / 8 | 001801E0（480高、24fps） |
| 04 | 3 / 12 | 帧数1…512 |
| 05 | 4 / 16 | 0000BB80（48000Hz） |
| 06 | 5 / 20 | WC所示frames×8000；486帧应003B5380 |
| 07 | 6 / 24 | 00000020（table_off） |
| 08 | 7 / 28 | frames_off按512对齐，≥ceil512(32+8×frames)，<256MiB；486帧最小1000 |

93 reason：10表项编号越界，11 offset不对齐，12 offset超256MiB，13 len不在4…65535（D5显示len），14首offset不同于frames_off，15重叠/逆序，16帧末端越界，17音轨末端越界（D5显示audio_end扇区数）。其余D5显示offset；WC为表项编号。91 reason20时D5显示失败写地址（word）。

### 已注入验证的判读例

| MISE / SP / ACC | 结论 |
|---|---|
| 3992 / 06CE / 200 | 首元数据读完且ack已到，头PCM长度不符；比较D5字段与WC×8000，不是done挂死 |
| 3993 / 11CE / 200 | 首元数据的某表项offset不对齐；WC指出表项、D5指出offset |
| 189F / 0086 / 200 | 首512B收满，FINISH等不到MEM完成回执（ack=0） |
| 109F / 004E / 1FF | SD ack到了，MEM只消费511字节，RECEIVE等最后一字节 |
| 069F / 0000 / 000 | SYS等待init_done/SD空闲，尚未取得owned |

例如先前现场若仍报92，不能只重复“首magic正确”：magic只覆盖word0，word1…7仍可能拒绝。D4d会指出具体字段及实际数值。若D5值、WC推导的期望完全相等仍拒绝，应进一步检查真实时序/内部字段及综合结果，不降低校验掩盖问题。

## 4. 验证与构建

`python tools/yxv_diagnostics_verify.py`：486帧合成头，六种done相位(-4/0/1/2/4/16 SYS周期)均进入下一3000001/7请求；八个头字拒绝、坏表项、缺done、缺字节共17例，检查owned释放及MEM复位后保留数据。

`python tools/yxv_d3_units.py`：重跑36/512帧完整表、PCM预载、回绕、物理burst、scanout及PCM单元。顶层故障用 `python tools/yxv_d3_verify.py --bad 1` / `--noinit`，保持至真实115200 UART发出报告并核验MISE/SP/ACC/WC/完整坏字段。正常路径使用 `--no-build --frames 2` 核对实际图像、HDMI音频与退出行为。D4c既有两组完整3秒结果保留历史；本轮不把短程结果冒充重跑3秒。

本轮只增加mem/sys标量诊断寄存器及UART选择，无新像素域路径、RAM数组或乘法；TD面积/时序仍由用户本地构建确认。首读/回退沿用D4c已板测通过的逻辑。软件原始结果在最终证据目录记录；真实故障码仍以本次板测读数为准。
