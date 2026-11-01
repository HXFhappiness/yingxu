# 视频 949F：零字写事务恢复与 SD 复位因果核验（2026-11-02）

基线：`feat/mjpeg@0863c41`。用户已确认该版本 syn 通过、phy-only 重跑产出位流、mem_clk 无新负 slack，read_design 不崩溃。按后续指示，本次**只处理视频**：不修改 hardware_test、design_top_wrapper、照片或菜单逻辑，不包含用户本地 e9bfba6。之前临时调查照片/菜单的改动已撤下。

## 现场解码：已进入 PCM，收到的是 32 字节

用户确认原始帧来自 0863c41：

```
A SEEN=1 BUSY=1 ERR=0 DNE=0 POR=1 FLU=0 KIL=0 RET=0 WFT=0 GM=0 CA=0
B CTRL=4 INIT=0 RSP=D459585631 RD=0 RDT=00 DIV=3E SPIK=1 CNT=0 SEL=0 ADS=0 DDS=0 CSN=1 MOS=1 SCK=0 MISO=1
C SST=0214 SNX=0214 SDN=4C69 ACC=020 OFF=D02DC6C0 VLD=0 W2F=0 R2E=0 HB=1
D MISE=949F SCE=8000 SW=77 LS=6 WC=000 BU=0 SP=0001 F=A PC=3FF DW=0000 I0=859FE6 RC=0000 I1=000000
```

- UART 的 ACC 是三位十六进制：`020 = 0x20 = 32`，512 字节会显示 `200`。故障快照 fail_count 是**当前 loader 请求**的收到字节数 mod2048，不能当累计头扇区计数。
- 94 是 purpose=2（PCM）、state=2（RECEIVE）、mstate=2、invalid=0。32 字节正好组成第一批 8word。loader 已完成格式/帧表验证、发过内存命令、尚未送出第一个 word。
- I0 的帧数是 `{01,E6}=486`，PCM 请求应为 ceil(486×8000/512)=7594 扇区。
- OFF 的 D 前缀表示**保留的首次请求 LBA**，不是实时 PCM sector/offset；D02DC6C0 不说明当前仍停在头读取。
- core 只有收到完整单扇区 ctrl_done 后才进入 RAM drain。至少当前 PCM 首扇区已由 SD 控制器取回；32 字节之后能因写背压停在 drain，停止 SPI 时钟是正常等待方式。
- DNE 是每笔 reader 请求的完成锁存，新的 PCM 请求开始即清零。真正 init_done 是 F.bit2/视频 LS.bit0。
- LS=6 是 sd_rst=1、video_sd_reset=1、init_done=0；F=A 是 owned=1、init_done=0、busy=1。当前 SD **被 abort 保持复位**，并不是从这些数值观察到 CMD0 正在重跑。

## 可证明的因果与尚未证明的部分

`tb/formal/sd_init_once.v` 对生产 core 做归纳证明：复位释放后的合法 RTL 执行，不论 start/count/ready/ctrl_done 如何变化，一旦初始化成功，init_done 不再下降，也不再发 mode0。另实际 probe/reader/core 完成 38 笔普通读和 count=1/7/7594；3911680 字节逐点比对，初始化一次、init_done 下降零次。

自动超时注入记录到：**先 MEM 9F，后 SYS video abort reset，再 init_done 下降**。控制器在复位中保持 IDLE；不会在复位仍保持时运行新一次初始化。没有修改 reader、SD SPI 频率或复位策略来掩盖这条因果链。

新增 block7 只让物理口漏收命令、保留上游看到的 ready，就能得到相同的 `949F/SP0001/ACC020/sent0/state0/position0/LS6/FA`。这证明该现场可由写命令/所有权失配产生，而不需要 SD 重新初始化。

**尚未证明板上是什么因素造成这次失配**：原 I1 没有两级 owner/handshake 位，不能排除命令漏收、仲裁状态丢失、复位瞬态或实现侧异常。云端注入不是板上触发源的证明。本交付修复的是与现场相符、可复现的零字写事务卡死机制；最终板上结论仍需此次构建板测。

## 修复：仅零字事务的一次性重提交

pipeline 默认启用 RECOVER_LOST_WRITE=1。只有以下条件同时成立才触发：

1. loader mstate=2 且 sent=0；物理 burst adapter idle；外部 cmd_ready=1、wvalid=1、wready=0；
2. 内层 arbiter active/owner=1/loader(1)，外层 active/owner=1/other(2)；
3. 无 mem_done/mem_error、无 fault、当前会话未复位、这笔事务尚未重提交。

同一 MEM 边沿将**这两级 loader 所有权释放**，让 loader 从 mstate2 返回 mstate1，再提交原命令。cursor、filled、8word buffer 和 SD 接收计数不变；没有重新读 SD，也没有跳过/伪造内存 done。

每笔最多一次；loader 的真实 done/error 才重新允许下一笔重提交。原进展 watchdog 不因重提交清零。已经送过任何数据、物理 COLLECT/WAIT/TRANSFER、其他客户端 owner、正常 done/error 均不会触发。两个仲裁器仍归 loader 所有且物理空闲，所以此操作不撤销其他客户端已接受的事务。

RECOVER_LOST_WRITE=0 仅用于复现对照。block7 永久漏命令时，开关两种配置在**完全相同 watchdog tick**报 9F；有恢复时 replay_count=1，无无限循环或延迟超时。

## I1 扩展：低 11 位保持兼容

只在 loader 写等待（mstate=2）的首错快照中使用空闲高位；MISE/SP/ACC/WC/RDT 格式保持。非写等待的头/表拒绝等保持原低位编码和高位零。

| 位 | 含义 |
| --- | --- |
| 23 | 扩展控制快照标志 = 1 |
| 22:20 | inner：{active, owner[1:0]}；loader 所有权应为 101 |
| 19:17 | outer：{active, owner[1:0]}；loader 经 other 所有权应为 110 |
| 16 | 本笔已重提交过 |
| 15 | loader cmd_ready |
| 14 | 外部 cmd_valid |
| 13 | 外部 cmd_ready |
| 12 | 外部 wvalid |
| 11 | 外部 wready |
| 10:7 | 原 loader.sent |
| 6:4 | 原物理 state |
| 3:0 | 原物理 position |

inactive 时 owner 只是保留值，不代表仍拥有事务。共增加两个 13bit 高位控制快照和一个重提交标志；没有数据/地址快照或原始 SD byte/assembly 比较锥。guard 与这些 owner 信号均在同一 MEM 时钟域。TD 需重新检查 guard→arbiter reset/loader mstate、write_replayed、frozen_write/fail_write 的时序；云端 Yosys 检查不能替代该门禁。

示例：

- 无恢复、持续漏命令：I1=DC3000（低11位=000），两级仍拥有 loader 命令，外部 ready=1、wvalid=1。
- 恢复一次后仍持续漏命令：I1=DD3000，bit16=1，仍按原 watchdog 报949F。
- 实际 top 的半写阻塞注入：I1=DC0214。该测试同时 force 外部 wvalid/wready=0，所以 bit12=0；低位仍是 sent4/COLLECT/position4。

## 验证与复现

`python3 tools/reader_reset_audit.py`：

- core 初始化单次的归纳证明、38+1/7/7594 完整读语义；
- block1/4/6/7 的真实 watchdog、fault→abort reset→init_done 下降顺序；
- block7 的恢复关闭/开启对照，相同 timeout tick，最多一次重提交；
- block8 一次性漏命令后自动恢复，完整486帧规模 PCM 预载：7594 扇区、121504 bursts、972032 words 零差异，init_done=1、failed=0、无 SD reset、init_commands=1。

block8 使用 `--fast-card` 加速**事务级卡服务模型**，真实 reader、两级仲裁、burst adapter、四口物理服务和写数据比较保留。不把该测试称为 SD 引脚/电气时序或真实卡速验证。默认卡模型保持原速；快/慢模型及构建目录分开保存。

其他验证：

- `python3 tools/yxv_diagnostics_verify.py`：27项格式/边界诊断，通过。
- `python3 tools/yxv_pending_verify.py`：所有权尚未释放时的首fault发布，通过。
- `python3 tools/yxv_d3_units.py`：物理口1…8word读写、36/512帧 loader、scanout、PCM，通过。
- `python3 tools/yxv_d3_verify.py --frames 2`：正常短程4001样本、HDMI4000样本、460800解码写字和1985280扫描像素零差异、48k误差0ppm、退出照片一次；新增断言要求健康流**没有重提交**。不冒充3秒整段播放。
- `python3 tools/yxv_d3_verify.py --no-build --write-pending`：实际115200 UART验证949F/I1=DC0214。
- Yosys read/hierarchy/proc/check 对全部生产 MJPEG 模块检查为零问题；未执行 TD。

原始日志与源码哈希见 [evidence/VIDEO_949F_RECOVERY](evidence/VIDEO_949F_RECOVERY)。

## 本地下一步

本提交基于0863c41，照片/菜单文件未修改，可与用户的 e9bfba6 叠加。先确认 TD syn/phy 及 MEM 时序门禁，再沿原 SW=77 复测视频。成功判据是 PCM 预载完成并进入解码/播放，而不是 DNE 单独变化。

若仍949F，请保留整帧新 I1；高位可区分两级 ownership、外部握手、是否已经重提交。DD3000 说明一次重提交仍未使物理口接收命令；其他 owner 值则把调查范围指向相应仲裁层。不要据此重写卡、重复初始化或跳过内存完成。

