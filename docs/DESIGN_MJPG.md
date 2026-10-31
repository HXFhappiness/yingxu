# YXV MJPEG 解码器设计（待审阅）

本稿基于 `main@3397925`，工作分支为 `feat/mjpeg`。D0设计稿已审阅，本次依批注进入D1；Python模型/转换器的已实现部分与结果见 [D1验证报告](D1_MJPEG_REPORT.md)。以下RTL文件/端口仍为拟实现规格，不代表已有RTL或板上性能。初赛固件及厂商 IP 保持冻结。

依据：[HANDOFF_FULL.md §10](HANDOFF_FULL.md#10-进行中yxv-视频管道)、[YXV_FORMAT.md §7](YXV_FORMAT.md#7-硬件消费模型)，并核对了 SD 探针、`sd_stream_reader_core`、SDRAM 自研控制封装、BMP 写入器、显示读出器和 WAV 播放器的现有接口。

## 1. 方案与适用范围

首版选 **50 MHz 解码、8 路乘加复用的两遍 IDCT、动态 DHT/DQT、RGB565、640×480 原尺寸居中显示**。所有熵解码、反量化、IDCT、色彩转换、地址运算均在 `sys_clk` 域；100 MHz 域只做 SDRAM 突发接入；pix 域只保留寄存后的读出、黑边选择和音频计数快照。首版不做缩放，避免将“640×480 播放”暗换成 720p 全幅写入。

预算目标为新增 **7.6K LUT、19 块 BRAM9K、13 个 DSP18×18**，分别留下约 1.5K LUT、6 块 BRAM、16 个 DSP 余量。DSP 类型/打包方式最终以 TD 映射报告确认，禁止把宽乘法静默综合成 LUT。

实时能力针对“可接纳素材”而非任意合法 JPEG：固定 640×480@24，单帧含 JPEG 头不超过 40 KiB，帧数不超过 512，且通过后述复杂度及实际 SD 服务率检查。纹理过密的素材需要降低 JPEG 质量或拒绝转换，不能用平均码率掩盖最坏帧。完整 4 分钟曲目与任意尺寸不属于首版。

### 1.1 先纠正带宽口径

| 项目 | 计算 | 结果（十进制 MB/s） |
|---|---|---:|
| MCU / 帧 | 640/16 × 480/16 | 1,200 |
| 8×8 块 / 帧 | 1,200 × (4Y + Cb + Cr) | 7,200 |
| RGB565 写入 / 帧 | 640 × 480 × 2 | 614,400 B |
| 视频有效写入 | 614,400 × 24 | **14.7456** |
| PCM 音频 | 48,000 × 2 声道 × 2 B | **0.192**（走 BRAM/WAV，不写 SDRAM） |
| 显示保守预留 | 沿用现有系统约束 | **110** |
| 显示 + 视频有效数据 | 110 + 14.7456 | **124.7456 < 150** |

交接文档中的约 11 MB/s 不能作为 RGB565@24 的写入值。剩余 40 MB/s 还要覆盖短突发、换向和刷新等损失；本稿不把 25.25 MB/s 的差额全部承诺给其他功能。

## 2. 现有接口差异及集成决策

### 2.1 单 SD 总线必须分时，不能把音视频当成两条物理通道

现有 `yingxu_sd_integration_probe.v` 通过参数固定 `SECTOR_COUNT`，顶层实例为 **5401**；`restart` 仅在空闲后启动，不能抢占正在读取的事务。其内部 `sd_stream_reader.v` 已具有运行时 `sector_count[15:0]`、`busy`、`done`、`stream_first/last`。底层一次 CMD17 把一个扇区读入 RD_RAM，再用 SET/GET 两拍吐一个字节，读卡与吐流不重叠。

后续在自研探针封装增加兼容默认值的动态事务入口，把调度器锁存的 LBA/count 送给现有 reader，向上导出真实完成脉冲；旧照片/音乐/卡带仍用默认 5401。**不复制第二套 SD 控制器，不改厂商命令层。** 使用事务拥有者锁存值对 `valid` 和 `ready` 同时分流：音频、表、JPEG 中只有一个接收者能看到有效字节，不能继续盲广播。

视频模式下每次最多读 8 个连续扇区（4 KiB），事务结束才允许切换音频。JPEG 的 reservoir、DHT、预测器和 MCU 状态跨事务保留；SD 读请求边界不是 JPEG 帧边界。帧尾只向解码器交付表中 `len` 字节，余下扇区填充仍握手排空。物理板上 LBA 为 `slot_base + file_offset/512`；**板上不减 2048**，那是 PC 原始卷写卡时的补偿。

### 2.2 现有 WR2 不能伪装成随机地址写口

已核对：`i_wr2_addr/max_addr/len/load` 配置的是顺序 FIFO 窗口，不是每字地址；FIFO 的 `aempty` 阈值固定为 127，攒够 128 个 32-bit 字才会调度。`WR2_USE` 当前未连接，也没有写入已落 SDRAM 的完成确认。简单把 `len` 改成 8 或反复 `LOAD` 都不成立，`LOAD` 也不负责清掉所有在途写入。

MCU 是 16×16，而目标帧是线性行存储。完整一条 MCU 行重排需要 `640×16×2=20,480 B`，单这一项就约 20 块 BRAM，叠加音频/表/IDCT 会超过余量，故不用全宽条带缓存。

选取**两个相邻 MCU 组成 32×16 小条带**，RGB565 双 bank 各 1 KiB。每条带按 16 行输出，每行是 16 个 32-bit 字的连续突发：

`word_addr = back_base + y*320 + (x>>1)`，`data[31:16]=左像素`、`data[15:0]=右像素`。

后续给 `yingxu_sdram_framebuffer.v` 及其**自研** `yingxu_sdram_control_4port.v` 增加视频带地址突发侧口；保留原 WR2 照片通路。新侧口把已完整缓存的 16 字突发接入现有 `mADDR/mLENGTH/mDATAIN/IN_REQ/mWR_DONE` 调度，在自研封装里补充拥有者、流控和提交确认。复用原命令/数据路径，不改 `src/5640/`、`al_ip/` 或 HDMI enc IP。它是必要的后续集成改动，**不是现有 WR2 已支持的能力**。

正常数据按 16 字一组，命令发布前全部数据必须已在异步 FIFO 可见；不能让 SDRAM burst 中途等 `ready`。仅非活动视频模式保持旧仲裁行为；视频模式对读端紧急状态优先，其余时隙给完整待发视频写 burst，禁止读请求永久饿死写端。最后一个 `mWR_DONE` 才产生 frame commit，FIFO 接收完成不等于落盘完成。

### 2.3 PCM 与 WAV 的真实接法

YXV 音轨是裸 PCM，不能直接送到寻找 `YXMA` 的 WAV 解析器。`yingxu_yxv_pcm_bridge` 在第一次 PCM 前合成 32 B YXMA 头（2 声道、16 位、48000 Hz、frames=`audio_bytes/4`），然后从 4 KiB 音频 reservoir 连续送字节，握手接现有 `u_wav.sd_data/sd_valid/sd_ready`。

视频模式下屏蔽 `wav_base/wav_restart` 对物理 SD 的控制；调度器独立维护 PCM 文件游标。WAV 原有 chunk 请求只记录，不用于重新插头或跳扇区；chunk 长度是 4 的倍数，跨 chunk 保持 L/R 字节相位。EOF 后不喂下一轮头，等尾部 FIFO 样本播完后结束，由 YXV 控制器统一重新开始。不要在“最后一个 PCM 字节已入 FIFO”时清掉 `music_active` 截掉尾音。

现有 WAV FIFO 物理为 1024 个立体声采样帧，背压水位 768 帧，常规可用时间约 **16 ms**，不是半秒。新增4 KiB reservoir为21.33ms；满reservoir加WAV约16ms共37.33ms，约为8ms gap的4.67倍（不是低水位时也有4倍）；不能只凭 WAV 小 FIFO 支撑整帧 SD 独占。

### 2.4 呈现与时钟

首版增加视频专用 RD2 读出分支：线性 640×480 RGB565，显示在 720p 的 `(320,120)..(959,599)`，外部黑边。沿用 128-word RD2 burst、垂直消隐期 LOAD/预取和像素对顺序；窗口外不消耗视频数据，不每行 LOAD。现有照片显示分支保持原逻辑。视频侧另有`rd_flush_req/ack:1`（P↔M toggle）及`cfg_base:21,cfg_max:21,cfg_len:9`稳定配置总线，全部锁存确认后再读。窗口判定、RGB、DE/HS/VS 对齐均寄存，新增输出选择最多一级 mux；禁止把 IDCT、除法、色彩转换或可变移位放进 pix 原有组合链。

视频模式复用 SDRAM，两槽建议按 32-bit 字地址保留 `[0x100000,0x130000)`、`[0x130000,0x160000)`，每槽实际用 `0x25800` 字（614,400 B），合计预留 1.5 MiB，末端小于 `0x200000`（8 MiB）。进入视频模式先停照片加载/轮播，退出后照片重新加载，不能把这两槽与旧照片 scratch 当成同时有效内容。

实际RD2 FIFO当前也只接全局reset，`RD2_LOAD`不清FIFO。视频换槽必须在自研封装里加独立`rd_flush_req/ack`：先停新的RD2 burst并等在途读完成，再通过现有FIFO的reset端口清空旧数据、同步释放、锁存新base及重装地址，最后预取。不要改FIFO厂商文件，也不要复位整个SDRAM控制器。跨域配置用held-bus+toggle确认，不能直接把P域脉冲/21位base接到M域状态机。

双缓冲只在消隐期换前后台；sys 发 `{slot,frame_id,epoch}` 并保持至 pix 应答，pix 在 RD2 完成重装前不提前释放旧前台。写端只能复用已释放槽。第三帧不得覆盖正在显示的槽，阻塞解码即可。初始先解码帧 0，再启动音轨，随后提前准备下一帧；采样计数用于决定**呈现时刻**，不是等到时刻到了才开始读卡解码。

## 3. 模块层次与拟建文件

以下新增 RTL 均在后续审定阶段才创建，Verilog-2001 风格。

```text
src/user_source/hdl_source/media/yxv/
  yingxu_yxv_player.v              顶层、epoch/错误恢复、前后台槽管理
  yingxu_yxv_sd_sched.v            单 SD 分时、音频优先、事务路由
  yingxu_yxv_container.v           YXV 头/512 项帧表/边界校验
  yingxu_yxv_pcm_bridge.v          4 KiB reservoir、虚拟 YXMA 头 → 现有 WAV
  yingxu_yxv_avsync.v              WAV 计数快照、sys 时间轴、呈现 mailbox
  yingxu_yxv_scanout.v             视频模式 RD2 读出、居中黑边
  yingxu_yxv_cdc_fifo.v            数据/描述符 FIFO，Gray 指针、复位 epoch
src/user_source/hdl_source/media/jpeg/
  yingxu_jpeg_decoder.v           组合子模块、每帧启动/错误/完成
  yingxu_jpeg_marker.v            SOI/SOF0/DQT/DHT/DRI/SOS/EOI、RST
  yingxu_jpeg_tables.v            DQT、canonical DHT 构建与查表 RAM
  yingxu_jpeg_bits.v              FF00 去填充、marker 分离、位 reservoir
  yingxu_jpeg_huffman.v           DC/AC 解码、幅值扩展、DC 预测、ZRL/EOB
  yingxu_jpeg_blockbuf.v          双 bank 系数块、清零/反 Z 字序/反量化
  yingxu_jpeg_idct.v              8 DSP、两遍 8×8 整数 IDCT
  yingxu_jpeg_mcu_rgb.v           MCU 双 bank、4:2:0 近邻展开、YCbCr→RGB565
  yingxu_jpeg_fb_writer.v         32×16 RGB 条带双 bank、16-word 行 burst
  yingxu_sdram_vwrite_port.v      burst 数据/描述符跨域、提交确认
```

```mermaid
flowchart LR
  SD[现有 SD reader/探针] --> S[YXV SD 调度器]
  S --> H[容器头与帧表]
  S --> A[PCM reservoir / 虚拟 YXMA]
  A --> W[现有 WAV FIFO与48k输出]
  S --> M[JPEG marker / tables / bits]
  M --> E[Huffman]
  E --> Q[反量化与双块系数 RAM]
  Q --> I[8路DSP IDCT]
  I --> C[MCU RAM / RGB565]
  C --> P[双MCU条带 / 带地址burst]
  P --> D[自研SDRAM封装侧口]
  D --> F[SDRAM后台帧]
  F --> R[视频RD2读出]
  R --> HDMI[现有HDMI管线]
  W --> T[采样计数快照 / 呈现调度]
  T --> R
```

后续集成触点限于自研顶层、`design_top_wrapper.v`、上述自研 SDRAM 封装、SD 探针适配及 TD 工程源文件注册；转换器约束属于之后独立工具改动。本稿不实施这些改动。

## 4. 接口契约

### 4.1 公共规则与通道类型

S=`sys_clk=50 MHz`，P=`pix_clk≈73.30 MHz`，M=`sdram_ctrl_clk=100 MHz`。各模块有其域的 `clk:1`、`rst:1`（高有效、释放在本域同步）；跨域 FIFO 两侧各有 clk/rst。未特别标注的内部接口均在 S 域。`epoch:8` 随启停/错误恢复递增，清理期间停止接收，旧 epoch 的完成/呈现包必须丢弃。

所有 R/V 通道均有 `valid:1`、反向 `ready:1`；只在二者同高时接受，阻塞期间 valid 及全部 payload 稳定，禁止 ready/valid 组合环。脉冲不是 R/V：必须注明只有一个周期，跨域改用 FIFO/mailbox。错误 `err_valid:1,err_code:8` 锁存到清帧，顶层统一处理；计数器除明确模计数外均饱和并报错。

| 通道 | payload（逐字段位宽） | 语义 |
|---|---|---|
| `SDREQ` | `lba:28, nsector:16, owner:2, tag:8` | owner=表/JPEG/PCM；只在 reader 空闲提交，count=1..8 |
| `BYTE` | `data:8, last:1` | last 指本通道对象结束；JPEG 为有效 len 的最后字节，不含扇区填充 |
| `FRAME` | `id:9, offset:32, length:32` | 文件内绝对偏移及 JPEG 有效字节数 |
| `TABWR` | `kind:3, tid:1, index:8, value:8` | kind=0:DQT、1:DC counts、2:DC symbols、3:AC counts、4:AC symbols；一张表收齐后发携带kind/tid的R/V commit |
| `TOKEN` | `block:3, mcu_x:6, mcu_y:5, k:6, qcoeff:s16, write_coef:1, block_last:1` | block=Y0/Y1/Y2/Y3/Cb/Cr，k为zigzag序号；EOB发送write_coef=0的结束token，ZRL只推进索引；不能丢掉全零块的结束事件 |
| `BLOCK` | `bank:1, block:3, mcu_x:6, mcu_y:5` | bank 中完整 64 项反量化系数，可被 IDCT 占有到 release |
| `SAMPLE` | `block:3, x:3, y:3, value:8, last:1` | IDCT 最终裁剪后的 8×8 样本，last 为该块最后一个输出 |
| `PIXEL` | `x:10, y:9, rgb565:16, mcu_last:1` | MCU 内行优先输出，带整帧绝对坐标，不承诺全帧行优先 |
| `WCMD` | `word_addr:21, words:9, tag:16, epoch:8` | words 首版恒 16，tag 标识该帧行 burst；无隐式地址自增跨行 |
| `WDATA` | `data:32, last:1` | 与最早未结束 WCMD 严格对应，last 在第16字 |
| `COMMIT` | `tag:16, epoch:8` | 该 burst 已完成 SDRAM 写，而非仅 FIFO 接收 |
| `PRESENT` | `slot:1, frame_id:9, epoch:8` | 前后台交换 mailbox，必须等待消隐与最终 ack |

### 4.2 控制、SD、音频及显示模块

以下“入/出”均相对于本行模块，通道全部字段采用上表位宽；跨域的位置在时钟列列明。

| 文件 / 模块 | 接口信号（方向） | 域 | 握手及约束 |
|---|---|---|---|
| `yingxu_yxv_player` | 入 `play_valid/ready:1`, `slot_base:28`, `stop:1`；出 `playing:1`, `frame_id:9`, `err_*` | S | play 接收一次锁存槽；stop 为 S 单拍，先排空/丢弃旧 epoch，再停 |
| 同上 | 出 SDREQ、入 SD 完成；入 FRAME；出解码 `start_valid/ready:1, jpeg_bytes:32, back_base:21, frame_id:9`；入 `decode_done:1`、最终 COMMIT；出 PRESENT | S / S↔P | decode_done 只表示 JPEG 结束；还须所有写提交后才能发布后台 |
| `yingxu_yxv_sd_sched` | 入上层读请求、`audio_occ:13`、`jpeg_space:10`；出 SDREQ 对探针；入 `sd_init:1,sd_busy:1,sd_done:1,sd_error:1` | S | 事务不可抢占；PCM 低水位优先，LBA/tag/count 全程锁存 |
| 同上 | 入 `stream_data:8,stream_valid:1,stream_last:1`，出 `stream_ready:1`；出表/JPEG/PCM BYTE | S | 对拥有者的 data/valid/ready 成对路由；完成须收到 nsector×512 字节和 done，不看 sticky done |
| `yingxu_yxv_container` | 入 BYTE；出 FRAME；出 `hdr_valid/ready:1`, `frames:10,width:16,height:16,fps:16,audio_off:32,audio_bytes:32`；入 `lookup_valid/ready:1,id:9` | S | 头先验证再装表；同步表 RAM 查表有显式响应 valid，不能假设零拍读 |
| 同上 | 出 `table_req`（SDREQ 的表拥有者）；出 `err_*` | S | 32+N×8 向上取整读；audio_off 由最后一项 offset+align512(len) 推导；无 audio_off 头字段 |
| `yingxu_yxv_pcm_bridge` | 入 PCM BYTE、`audio_bytes:32,begin:1`；出 `occ:13`；出 `wav_data:8,wav_valid:1`，入 `wav_ready:1`；出 `producer_eof:1` | S | 缓存容量4096B，合成头也遵守 WAV ready；last 后仅丢弃扇区填充，不插入 PCM |
| 同上 | 入 `wav_restart:1,wav_base:28`，出 `wav_music_active:1` | S | 视频模式隔离物理读请求；维持 active 到真实播放尾部；非视频模式走旧连线 |
| `yingxu_yxv_avsync` | 入 `wav_pops:16,wav_out_ticks:16`；入/出快照 req/ack toggle:1，held snapshot:32 | P↔S | P 收请求后一次锁存两个16位计数并保持，ack 经2FF；S 再取稳定总线，不把二进制计数器逐位2FF |
| 同上 | 出 `samples_played:32,due_id:9`；入/出 PRESENT 与释放 ack | S↔P | ≤0.5ms轮询，16位计数模差扩展32位；同一epoch不能间隔≥65536/48000秒；每2000采样帧推进一次deadline；EOF单独标识，不让第512帧回绕为0 |
| `yingxu_yxv_scanout` | 入 PRESENT；出 `release_slot:1,ack_toggle:1`；入 `pixel_x:11,pixel_y:10,pixel_active:1,video_mode:1` | P | 仅垂直消隐换槽，独立rd_flush握手、LOAD/预取结束再ack；扫描窗口/黑边均寄存 |
| 同上 | 入 `rd2_data:32,rd2_empty:1`；出 `rd2_en:1,rd2_addr/max_addr:21,rd2_len:9,rd2_load:1,rgb:24,underflow:1` | P | 沿用连续行存储与128字 burst；空时不采垃圾；RD2未完成旧读请求前禁止释放旧前台 |
| `yingxu_yxv_cdc_fifo` | 入 `w_data:W,w_valid:1`，出 `w_ready:1`；出 `r_data:W,r_valid:1`，入 `r_ready:1`；两侧 epoch:8 | S↔M | 注册 Gray 指针+2FF；深度为2幂；同步读RAM延迟由 valid 覆盖；恢复握手后再启流 |

采样帧是一个 L/R 对，不是单声道样本。启播前先完成epoch内基准计数快照，再放行music_active；EOF单独结束时间轴。时间轴使用 WAV 的真实 pops，不使用 SD 已读字节或 HDMI 刷新帧数；输出 tick 同时用于检查断流。前台重复时音频继续，下一次选最新已完成且到期的后台；正常接纳素材验收要求不丢帧。59.3Hz 显示与24fps内容不整除，呈现相对音频 deadline 的延迟上限为一次刷新周期加快照误差（约17.4ms），不是承诺每帧恰好保持2或3次刷新。

### 4.3 JPEG 计算模块

| 文件 / 模块 | 接口信号（方向；未另标均 S 域） | 握手及宽度补充 |
|---|---|---|
| `yingxu_jpeg_decoder` | 入 start 与 BYTE；出 `start_ready:1,done:1,err_*`、PIXEL；出 `active_cycles:32,input_wait_cycles:32,output_wait_cycles:32` | 每帧清表有效位、预测器、reservoir及 bank 所有权；done 须 EOI、7200块和307200像素全部吻合 |
| `yingxu_jpeg_marker` | 入 BYTE 与 bits 返回的 `marker_valid/ready:1,marker_code:8`；出 `entropy_enable:1`、TABWR、`commit_valid/ready:1,kind:3,tid:1` | 头段按大端长度消费；JPEG 大端与YXV小端严格分开；段解析不识别元数据中的伪 FFD8 |
| 同上 | 出 `scan_valid/ready:1`, `width/height:16`, `qt_y/qt_c:1`, `dc_y/dc_c/ac_y/ac_c:1`, `dri:16`；出 `restart_valid/ready:1,rst_index:3` | 只在完整合法 SOS 后启熵解码；restart 必须 MCU 边界 |
| `yingxu_jpeg_tables` | 入 TABWR/commit（kind:3,tid:1）；入 `hreq_valid/ready:1,table_sel:2,nbits:5`，出 `hrsp_valid/ready:1,first_code:16,count:8,base:8` | 同步 canonical RAM；table_sel={DC/AC,tid}；code-first<count 才命中 |
| 同上 | 入 `sym_req_valid/ready:1,table_sel:2,index:8`，出 `symbol_valid/ready:1,symbol:8`；入 `qreq_valid/ready:1,tid:1,k:6`，出 `qvalid/ready:1,q:8` | DHT symbol RAM 4×256×8；Q RAM 2×64×8；仅支持的标识范围内查表，禁止缺表默认填零 |
| `yingxu_jpeg_bits` | 入熵区 BYTE；入 `get_valid/ready:1,nbits:5`；出 `bits_valid/ready:1,value:16`；出 marker 通道；入 `align:1` | nbits=0..16，32位 reservoir；FF00 变为一个FF；未消费完marker前不跨marker取位；align只能在块/MCU规定边界 |
| `yingxu_jpeg_huffman` | 入 scan 配置、bits 及table响应；出 TOKEN、`mcu_done:1,mcu_x:6,mcu_y:5`；入 restart；出 `err_*` | AC size≤10、DC size≤11；每分量独立 DC predictor:s16，运算先扩位再检查；不可把block_last当丢失系数的补救 |
| `yingxu_jpeg_blockbuf` | 入 TOKEN、量化表响应；出 BLOCK；入 `block_release_valid/ready:1,bank:1` | 每bank先清64项，zigzag ROM映射至自然顺序；一个DSP乘 qcoeff×Q 后检查范围、写s16；两个bank共128×16 |
| 同上 | 入 `coef_rd_valid/ready:1,bank:1,index:6`，出 `coef_valid/ready:1,value:s16` | BRAM同步读，bank冻结到IDCT完成；EOB后未写项必须确实是0 |
| `yingxu_jpeg_idct` | 入 BLOCK 与 coef读响应；出 SAMPLE；出 `release_valid:1,release_bank:1`（入release_ready:1）、`block_done:1,cycles:16` | 8乘法lane，双遍转置RAM；output stall保留sample及地址，不能继续覆盖MCU槽 |
| `yingxu_jpeg_mcu_rgb` | 入 SAMPLE、`mcu_x:6,mcu_y:5`；出 PIXEL；出 `mcu_release:1` | 两个MCU sample bank，block6齐才允许渲染；一个RAM读口每像素3拍取Y/Cb/Cr，另一口供IDCT写下一bank |
| `yingxu_jpeg_fb_writer` | 入 PIXEL、`back_base:21,frame_id:9,epoch:8`；出 WCMD/WDATA；入 COMMIT；出 `frame_committed:1` | 两MCU条带双bank；只发布完整16字行；最后一burst落SDRAM后才committed |
| `yingxu_sdram_vwrite_port` | S侧入 WCMD/WDATA、出 ready；M侧出 `vwr_valid:1,addr:21,len:9,data:32`，入 `vwr_ready:1,data_take:1`；入 `vwr_done:1`；S侧出 COMMIT | 数据FIFO256×32、描述符FIFO16×64；描述符在全部16字写入后发布，M侧还须等同步后的数据credit≥16；完成事件保持/确认，不能丢M单拍 |

M侧实际接入自研控制器时，`vwr_ready` 只接受一个完整 burst 的控制权，数据随后按 `IN_REQ` 每拍提供；完成等 `mWR_DONE`。全帧9,600个行burst，16位tag足够；配置及epoch高位可在整帧期间稳定保持、mailbox传递，64位描述符以 `{addr:21,len:9,tag:16,epoch:8,reserved:10}` 存储。首选在一块32位宽物理BRAM中分两拍写/读描述符的高低半部，逻辑读写指针仅在整条描述符完成后推进；独立64位宽映射的20块备选总预算见§7。

## 5. JPEG 子集与输入保证

### 5.1 接受的编码

| 项 | 首版决定 |
|---|---|
| JPEG过程 | SOF0，8-bit Baseline sequential DCT，单帧独立完整JPEG |
| 尺寸 | 首版只接收640×480，宽高均16整除，无边缘MCU裁剪分支 |
| 颜色/采样 | 三分量YCbCr，ID为1/2/3，Y采样2×2，Cb/Cr各1×1；MCU块序Y0,Y1,Y2,Y3,Cb,Cr；Cb/Cr必须共用相同的DQT/DC/AC表选择 |
| Scan | 一个交织SOS，三分量齐，Ss=0、Se=63、Ah=Al=0，分量顺序与SOF一致 |
| Huffman | **解析每帧DHT**，DC/AC各支持ID0/1。支持标准表和编码器优化的自定义canonical表；不硬编码“标准表一定存在” |
| 量化 | **解析自定义DQT**，8-bit精度、ID0/1，元素1..255。按zigzag入表，SOF选择对应表；帧间可更换，SOS后不再改表 |
| 语法 | 支持DC差分/符号扩展，AC EOB、ZRL、run/size；拒绝超过系数63、非法size或缺码 |
| RST | 支持DRI及RST0..RST7循环；每规定MCU数丢弃到字节边界、验证填充位、复位三路DC预测器。DRI=0不允许RST；末MCU后直接EOI也可 |
| 容器内元数据 | APPn/COM按段长跳过，头总量≤4KiB；不解释ICC/Exif旋转/Adobe颜色转换，转换器须先归一化像素 |
| 数值边界 | 差分先s17求和；qcoeff×Q先完整乘积，反量化结果必须在[-2048,2047]，越界报错而非截断/环绕 |

12位反量化幅度是该硬件profile的额外限制，不声称覆盖所有语法合法的Baseline码流。普通8-bit图像DCT的量级约1024，包含量化误差后仍有余量；仍必须由软件逐块验证，不能仅相信这一经验范围。

### 5.2 明确拒绝的项目

拒绝 progressive/SOF2、扩展顺序SOF1、12-bit、算术编码、lossless、灰度/CMYK/RGB JPEG、4:2:2/4:4:4、非交织/多scan、分量ID/表ID超上述范围、16-bit DQT、缺省/跨帧沿用表的 abbreviated JPEG、DNL/层次编码、熵区内改表、截断或重叠段，以及超尺寸/帧数/长度/复杂度上限的YXV。

RST不能当普通填充丢弃：顺序错误、过早/过晚、DRI不符、码字跨RST、EOF半个marker都报当前帧失败。失败只丢弃后台，继续显示最后一张已提交前台；不能在未知位边界“跳到下一个FF”然后声称帧有效。预期RST点无额外marker却有EOI，只在刚好完成最后MCU时接受。

### 5.3 转换器端的保证（后续工具任务，不在本稿改动）

当前 `tools/video2yxv.py` **没有固定 pix_fmt，也没有JPEG子集/周期验证**，其现有 verify 仅检查容器的一部分不变量，不能作为本解码器输入合格证。

后续转换命令显式增加 `-c:v mjpeg -pix_fmt yuvj420p -huffman default`，固定640×480、24fps，并在缩放/转色时归一化为JPEG full-range YCbCr（明确BT.601矩阵）。`-q:v` 值越大质量越低；default Huffman只是可重复生成的默认，不限制硬件读取DHT。不要依赖未经确认的 ffmpeg restart 选项名：硬件支持DRI/RST，验证器检查实际段即可。

转换后标准库Python验证器必须逐帧解析marker、完整熵解码，验证上述profile、DHT无过订阅/非法码、DQT值、幅度范围、EOI恰在表len末尾、有效像素数和资源限制；按实际有限bank调度模型计算周期。失败时有界提高q值重转，仍失败则拒绝写卡，不自动改变分辨率/格式。还须检查：

- YXV小端头、version=1/channels=2/rate=48000、fps=24、1≤frames≤512、audio_bytes能被4整除；table_off=32，frames_off在表后且512对齐。
- 每项offset单调且**不重叠**，len>0且≤40KiB；所有加法用至少33位检查溢出和256MiB槽边界。
- audio_off由最后帧推导，audio_off+audio_bytes不越槽；视频/音频时长差<0.1s。首版默认通过补/裁PCM使其精确等于N×2000个立体声采样帧。
- 帧表和所有帧均自足，不把超过512项静默截表；首版21.333秒上限用明确错误提示。长片分段是未来格式/读表任务。
- 写卡仍沿用锁卷、-2048补偿、扇区对齐、回读校验；仅提交合成测试向量的生成器，不提交音乐/视频素材。

## 6. 运算与缓存细节

### 6.1 熵解码与反量化

不采用4×65536的完整Huffman LUT。DHT先构建每表16条 `{first_code:16,count:8,base:8}` 描述符，symbol另存RAM；按码长1..16逐位canonical匹配，描述符同步读按保守**每码位2拍**计，幅值一次从reservoir取0..11位。移位/匹配/符号访问分拍，最大码长不是一条16层组合树。

每块64项先清零，DC放自然索引0；AC累加run并由64×6bit固定ROM反zigzag。TOKEN写DC（含0）及真实非零AC；EOB用write_coef=0的终止token结束，k=63的系数token可直接带block_last，ZRL跳16个零但要检查剩余范围。用1个DSP做带符号反量化；Q必须显式零扩展为正数。系数bank交接只传所有权，不能在IDCT读同bank时清零。

### 6.2 IDCT：8个DSP，避免把稠密矩阵做成64个乘法器

定义 `A[n,k]=C(k)/2*cos((2n+1)k*pi/16)`，`C(0)=1/sqrt(2)`，其余为1；ROM常数 `K[n,k]=round(65536*A[n,k])`（有符号16位）。先对每个频域行作8点变换，存T，再按列作同样变换，最后加128并clip至[0,255]。

一拍读一个输入，广播到8路DSP，各路对应一个输出位置，8拍发完8输入；lane累加器为s40。乘法输入最多s16×s16（放入DSP18×18）；第一遍结果以s16转置缓存，输入幅度限制使其理论绝对值≤约5793，不会溢出。每遍采用 `floor((sum+32768)/65536)` 舍入，负数也必须按这个定义，不能由语言默认右移/round替代。

乘法/加法标签流水，两个累加上下文或独立结果寄存器允许“下一向量计算”和“上一向量8结果串行写RAM”重叠。每遍64拍发射，BRAM读/乘法延迟/尾部8拍排出及切换合计预算≤24拍，故每遍≤88拍、**每块≤176拍**，不是1024拍/块。转置RAM只要单读单写；不需要8个BRAM读口。若综合或实现无法做到这一调度，不得继续引用176拍结论。

Python整数模型与RTL必须逐点bit-exact；独立双精度数学IDCT在上述幅度范围的最终8-bit裁剪输出最大绝对误差门槛为3 LSB（两遍Q16舍入及常数量化的保守界约2.63）。不要求与使用不同IDCT/舍入规则的ffmpeg逐字节相同。

### 6.3 MCU与颜色

MCU RAM双bank共 `2×(256Y+64Cb+64Cr)=768B`，放一块1024×8存储。IDCT可写下一bank；渲染器从另一bank按x/y行序取Y、Cb、Cr，每像素3个RAM读拍，Cb/Cr索引为 `(y>>1,x>>1)`，首版近邻展开。

颜色项的round统一定义为`floor((sum+8192)/16384)`（G的两个乘积先相加再舍入）。JPEG为full-range：`R=Y+round(22970*Cr'/16384)`，`G=Y+round((-5638*Cb'-11700*Cr')/16384)`，`B=Y+round(29032*Cb'/16384)`，Cb'/Cr'=输入-128。4个DSP做4个乘积，寄存加法/舍入/clip，再取R[7:3]、G[7:2]、B[7:3]。禁止混用限幅视频的Y-16公式。

32×16 RGB条带双bank一共2KiB；写左MCU的每行前8字，再写右MCU的后8字，完整后按行发16字burst，不填充无用像素到SDRAM。输出侧接受停顿时回压到MCU/IDCT/熵流，所有bank release都必须经过最后一次有效握手。

## 7. 资源账（增量，不重复扣现有39块BRAM）

| 模块组 | LUT目标 | BRAM9K（物理块） | DSP18×18 |
|---|---:|---:|---:|
| YXV顶层、头/表、SD调度 | 1,200 | 4（512×64帧表） | 0 |
| PCM bridge、采样快照/epoch | 550 | 4（4096×8 reservoir） | 0 |
| JPEG marker、bits、输入FIFO | 800 | 1（512×8） | 0 |
| DHT/DQT构建、canonical Huffman | 1,400 | 3（symbol、canonical、DQT各1） | 0 |
| blockbuf、反zigzag/反量化 | 350 | 1（128×16） | 1 |
| IDCT、常数小ROM/控制 | 1,450 | 1（64×16转置） | 8 |
| MCU RAM、色彩流水 | 550 | 1（1024×8） | 4 |
| RGB条带、burst组装/CDC/提交 | 800 | 4（条带2 + 数据1 + 描述符1，见下） | 0 |
| 视频读出、SDRAM仲裁侧口/读FIFO独立flush适配 | 500 | 0 | 0 |
| **合计目标** | **7,600** | **19** | **13** |

上表burst组的描述符不能按逻辑字节数误计：16×64存储在36位宽物理RAM需2块，若独立分配则该组为5、总计20。首选把描述符的高/低32位分置于同一物理双口RAM的不同地址，使用64×32 RAM、两拍组装命令；不需要每拍发布命令，故仍为1块。数据FIFO256×32为1块，条带各256×32为1块。**默认目标为19块；若TD不能推断打包而需要20块，必须记录偏差并复审，不自动消费释放出的6块余量；25是器件硬上限。**

ROM和小描述符寄存器包含在LUT估算中，不能再额外“免费”使用BRAM。目标不是已综合测量；约7.6K LUT的理由是没有全码字Huffman大表、没有可变通用除法器、没有全帧/全宽条带RAM、8 lane重复使用而非展开64乘法，且13个DSP承担全部乘法。常数像素地址用移位加法，fps固定24使每帧为2000采样帧。

硬门槛：增量LUT≤9,081（19,600−10,519，9.1K是约数）、BRAM≤25、DSP≤29；优选总LUT≤18,119（10,519+7,600），目标BRAM总数≤58（39+19），DSP总数13。首次集成报告若预测超过目标，先停在独立模块阶段调整，不挤占未知“可回收”冻结模块资源。必须同时看寄存器、布线拥塞及各时钟slack；LUT能放下不等于时序通过。

### 7.1 D2–D6每阶段都注册TD工程并综合：30%停机线

7.6K LUT只是估算，约占实际剩余9081的83.7%，不能等D9才综合。D2/D3/D4/D5/D6结束后，分别把本阶段模块加入同一TD工程，以相同工具版本/参数/实际连接综合，记录源码SHA、基准、日志路径、LUT/REG/BRAM/DSP总数及增量。未运行或缺失报告时阶段状态是“待本地TD”，不能推进下一RTL阶段。

| 阶段 | 当阶段估算 LUT/BRAM/DSP | 从S1基准起累计估算 LUT/BRAM/DSP |
|---|---|---|
| D2：writer/侧口/读flush适配 | 1300 / 4 / 0 | 1300 / 4 / 0 |
| D3：marker/bits/tables | 1300 / 4 / 0 | 2600 / 8 / 0 |
| D4：Huffman/blockbuf | 1250 / 1 / 1 | 3850 / 9 / 1 |
| D5：IDCT | 1450 / 1 / 8 | 5300 / 10 / 9 |
| D6：MCU/RGB | 550 / 1 / 4 | 5850 / 11 / 13 |

其余YXV/SD调度1200 LUT+4BRAM、PCM/AV 550 LUT+4BRAM，总目标7600/19/13。累计实测增量相对**已完成阶段累计估算**的绝对偏差，任一资源超过30%即停下来重设计；估算为0却实测新增时同样停机，不能用除0规避。超器件硬上限或pix新增负裕量无论偏差百分比多少都停。基准使用S1完成后的同配置综合结果，同时保留冻结基线10519/39/0供追溯；不通过优化删除其他冻结功能来稀释增量。完整工程的综合差值能含优化抵消，须同时记录模块层级利用率。板卡/TD在本地，云端不能填造数字。

## 8. 周期、SD与SDRAM预算

### 8.1 解码核（50MHz）

| 环节 | 每MCU周期预算/模型 | 640×480整帧 |
|---|---|---|
| Huffman+清零+反量化 | `sum(64 + 2*Hbits + 4*Nsymbols + 16)`，对6块求和；Hbits不含幅值位，4拍符号项含取幅值/查符号/反量化开销 | 内容相关；参考模型必须计真实码字、RAM等待、bank占有 |
| IDCT | 6×176 = **1,056** | 1,267,200拍，**25.344ms** |
| MCU读样本+RGB | ≤3×256+16 = **784** | 940,800拍，**18.816ms** |
| 两MCU条带排出到本地FIFO | 每条带256字+切换，摊至每MCU≤144 | ≤172,800拍，3.456ms；不含外部SDRAM等待 |
| 帧周期可用 | 50,000,000/(24×1200) | **1,736.11拍/MCU**；每帧2,083,333.33拍 |

各级通过两块系数bank、两MCU sample bank、两条带bank重叠运行，不把这些整帧时间相加，也不能无条件只取最大值。串行尾部、局部高熵MCU和bank互锁必须由有限缓存的周期参考模型计算。

接纳规则：先以1344拍/MCU（32.256ms/帧）作为熵级预算线；对复杂度超线的MCU明确标记。最终必须在**完整有限bank调度模型**中、输入随时可用且输出不阻塞时，单帧≤1,750,000拍（35ms，含头表解析与流水排空），否则该q值不接纳。该最终门槛优先于均值；不能只凭“每个模块各自够快”宣称整机24fps。

### 8.2 SD：25MHz为设计工作点，12.5MHz只作条件降档

| 项目 | 上界 / 门槛 |
|---|---|
| 视频存储读 | 每帧≤40KiB，含末尾扇区对齐，≤80扇区/帧；24fps为983,040 B/s |
| 音频及扇区尾 | 192,000 B/s，首尾对齐另计，长窗口合计至少约1.18MB/s有效载荷 |
| 必须实测的读服务率 | 含CMD17、卡忙、SET/GET和切音视频的持续有效载荷 **≥1.50MB/s**，且符合音频gap门槛 |
| 无新增硬件能力的当前状态 | 6.25MHz理论仅781,250B/s，低于需求，**必不满足目标** |
| 12.5MHz | 1.5625MB/s是SPI线上上限，串行吐流已把无额外开销上限降到约1.47MB/s；不据此保证首版最坏帧 |
| 25MHz | 原始3.125MB/s；计每扇区额外1024个50MHz吐字节周期，不含其他开销上限约2.78MB/s；实际卡/板能否≥1.50要测 |

8扇区JPEG量子按1.50MB/s约2.73ms。调度器低水位2KiB、高水位4KiB，优先补PCM（每次最多4扇区，且不能超过剩余容量），满后继续JPEG；必须保证音频可服务间隔≤8ms，长卡忙超界就记欠载并停本轮，而非无限重试维持“播放中”。4096B最多缓存21.33ms、低水位仍约10.67ms，与WAV实际水位一起覆盖切换间隙。

单SD共享这一事实使平均带宽不充分：测试必须覆盖JPEG最大帧、PCM低水位、坏扇区延迟、帧表初装、随机ready停顿。SD量子不改变文件布局；音频文件游标和JPEG游标分别保存。首次启动先装表、计算audio_off、预解帧0及储备PCM，再放行音频。

### 8.2.1 S1失败时的降级次序与门槛

优先级固定为 **(c)提高压缩比 → (a)640×480降到15fps → (b)480×360降分辨率**。先保持尺寸/流畅度，再保尺寸牺牲fps，最后降低像素数。B_eff必须取用户板上持续读实测的保守下界，含命令/卡忙/分流，所有档位音频gap仍≤8ms。保留20%时间余量：`SD_required=(fps×align512(max_jpeg_bytes)+192000)/0.8`；按每个素材的最大帧验证，不用平均帧。

| 档位（递次选择） | JPEG最大帧 | SD有效载荷/需求下界 MB/s | RGB565有效写入 MB/s |
|---|---:|---:|---:|
| 默认640×480@24 | 40KiB | 1.175040 / 1.468800；S1实际门槛仍为**1.50** | 14.745600 |
| c1：640×480@24 | 32KiB | 0.978432 / 1.223040，实测≥1.23 | 14.745600 |
| c2：640×480@24 | 24KiB | 0.781824 / 0.977280，实测≥0.98 | 14.745600 |
| a：640×480@15，继承c2压缩 | 24KiB | 0.560640 / 0.700800，实测≥0.71 | 9.216000 |
| b：480×360@15 | 16KiB | 0.437760 / 0.547200，实测≥0.55 | 5.184000 |
| 对照：只降分辨率480×360@24 | 16KiB | 0.585216 / 0.731520，实测≥0.74 | 8.294400 |

若S1在25MHz不稳定或B_eff<1.50，默认D2**停止**；先在稳定SPI频率测B_eff，再提出上表最高可用档位，调整素材并复核视觉质量、解码周期、写入deadline。用户确认降级目标后才可重新定义S1/D2门槛，不能靠选择fallback绕过“未通过不得进D2”。例如稳定读率0.75MB/s选a，0.60选b，<0.55则首版音视频播放不接纳；即使平均达标，gap超8ms也不通过。

降压缩只减SD/熵负载，不减IDCT/像素写带宽；15fps把采样deadline改为3200对/帧、写入周期66.67ms；480×360是30×23 MCU（底部补8行，只输出360行），需要后续RTL加入边缘裁剪、地址/黑边及容器profile，不能对现有640-only RTL直接喂这种素材。D1转换器只产生默认640×480@24，并给明确错误；降级档位不是本次暗改的默认值。对于40KiB仍不改压缩的640@15对照，SD需求为1.008MB/s，而非表中采用24KiB的0.7008。

### 8.3 SDRAM：带地址短突发是关键验收项

32×16条带每帧为20×30=600个，每条带16个行burst，因此每帧9,600 burst、每秒230,400 burst；每burst 16字=64B，正好14.7456MB/s。既不为每个像素切地址，也不将每行填充到128字（后者会多写8倍）。

作为保守预算，用每burst额外开销H个32-bit字服务当量估算：

`W_equiv = 14.7456 * (1 + H/16) MB/s`。

当H≤24时，W_equiv≤36.864MB/s，落在40MB/s余额内。这个归一化上界用于给短突发留账，**不是说控制器已实测H=24，也不把400MB/s峰值当作150MB/s可用带宽**。实际还受RD2优先级、刷新和读写换向影响，必须在显示持续占用约110MB/s的压力下实测/周期仿真短突发有效写率≥15.36MB/s（614400B/40ms）、帧提交≤40ms且读端无欠载。若H或帧时长超界，先调整自研仲裁/条带调度，不能改厂商FIFO阈值或侵占显示预算。

35ms解码核、约32.64ms最坏载荷SD服务及≤40ms写提交是可重叠的不同资源约束。最终系统门槛是：从开始供给下一帧到后台最终commit **≤40ms**，至少连续504帧（21秒）在真实速率/显示压力下零音频欠载、零正常帧丢弃、零读端underflow。只有这个联合检查通过才称640×480@24成立；当前文档只是可实现预算，尚无RTL/硬件性能证据。

## 9. 验证计划：每个模块都有独立Python模型与RTL TB

拟建标准库参考包 `tools/mjpeg_ref/` 与对应 `tb/` 文件；D1已实现的模型/测试/再生命令以D1报告为准，其余模型随对应RTL阶段补齐。每个参考模型输出带序号的中间轨迹，RTL TB仅导出本级可观察数据，不复用DUT内部算法作为期望值。明确记录seed、输入SHA256、epoch、命令、退出码和当前生成文件，防止误读旧日志。

| 模块 | Python模型文件 | 对应RTL TB文件 | 逐点及不变量 |
|---|---|---|---|
| yxv_player | `yxv_player.py` | `tb_yxv_player.v` | 启停/错误/前后台所有权状态与每次commit/present；旧epoch不生效 |
| yxv_sd_sched | `sd_sched.py` | `tb_yxv_sd_sched.v` | 每个LBA/count/owner、分流字节、事务尾排空；PCM gap上界 |
| yxv_container | `container.py` | `tb_yxv_container.v` | 头/每个表项/audio_off；越界/重叠/第513帧等负例 |
| yxv_pcm_bridge | `pcm_bridge.py` | `tb_yxv_pcm_bridge.v` | 虚拟32B头+原PCM逐字节、每个L/R包，跨chunk及EOF不漏尾音 |
| yxv_avsync | `avsync.py` | `tb_yxv_avsync.v` | 模65536计数展开、每2000采样frame deadline、快照异相及epoch清理 |
| yxv_scanout | `scanout.py` | `tb_yxv_scanout.v` | 全部720p坐标的RGB/黑边/DE延迟、读地址与交换应答，换槽前刻意残留FIFO数据，检查flush及旧帧释放次序 |
| yxv_cdc_fifo | `cdc_queue.py` | `tb_yxv_cdc_fifo.v` | 与纯队列逐项比较，异频异相、满/空、同步读延迟、不同域复位 |
| jpeg_decoder | `decoder.py` | `tb_jpeg_decoder.v` | 整帧RGB565按(x,y)重排后逐像素、精确长度/EOI及总周期 |
| jpeg_marker | `markers.py` | `tb_jpeg_marker.v` | 每个段字段、长度、SOS/RST/EOI事件；FF00及截断marker负例 |
| jpeg_tables | `tables.py` | `tb_jpeg_tables.v` | 每条canonical描述符、每个symbol、每个DQT元素；自定义/缺表/非法码树 |
| jpeg_bits | `bits.py` | `tb_jpeg_bits.v` | 每次请求返回的0..16位及marker事件，跨字节/扇区、FF00、RST填充 |
| jpeg_huffman | `entropy.py` | `tb_jpeg_huffman.v` | 每个DC/AC token、预测器、run/k；ZRL/EOB/最长码/负幅值及RST清零 |
| jpeg_blockbuf | `blockbuf.py` | `tb_jpeg_blockbuf.v` | 每块全部64个自然序反量化值（包括零），bank读写互斥和溢出检测 |
| jpeg_idct | `idct_int.py`、独立`idct_float.py` | `tb_jpeg_idct.v` | 每遍64点、最终64样本bit-exact；浮点独立误差≤3，0/DC/单AC/极值/随机块 |
| jpeg_mcu_rgb | `mcu_rgb.py` | `tb_jpeg_mcu_rgb.v` | 每个Y/Cb/Cr地址、每像素RGB565，四象限Y与彩色色块检查4:2:0索引 |
| jpeg_fb_writer | `fb_writer.py` | `tb_jpeg_fb_writer.v` | 每个行burst地址/16字内容/最终帧图；左右MCU重排、满回压、禁止越槽 |
| sdram_vwrite_port | `vwrite.py` | `tb_sdram_vwrite_port.v` | 数据先可见再发命令、每次IN_REQ数据、mWR_DONE/commit；并发RD2与刷新 |

另设 `tools/mjpeg_ref/cycles.py` 和 `tb/tb_yxv_system.v` 做有限缓存周期与整机模型，真实50/73.30/100MHz、SPI事务延迟、不加速48k音频，比较采样时间轴、每帧最终地址图与到期呈现。仿真内存/SD模型可行为化，厂商接口契约必须与现有同步读延迟、FIFO阈值相符，不能用零延迟无限FIFO给假吞吐。

### 9.1 自动判据采用比值、完整轨迹及分母检查

| 判据名 | 必须自动判断的关系 |
|---|---|
| `BYTECHK` | 有效JPEG字节/表len = 1；SD握手字节/(nsector×512) = 1；填充只在路由器丢弃 |
| `BLOCKCHK` | 解出的块数/MCU数 = 6；自然序系数数/块数 = 64；所有中间点零diff |
| `PIXCHK` | 像素数/MCU数 = 256；有效坐标覆盖率 = 1且每点一次；RGB对整数金标零diff |
| `DQTCHK` | 反量化值/(qcoeff×Q) = 1（非零点）；零点单独判0，不能除0 |
| `IDCTCHK` | 无外停顿周期/块≤176；整数逐点零diff，独立浮点maxabs≤3 |
| `RATECHK` | 正常段played_stereo_frames/out_ticks = 1（扣已注明的流水起止边界）；SD字节速率不能代替它 |
| `AVCHK` | due_frame/sample_frames = 1/2000，采用整式 `2000*due≤samples<2000*(due+1)`，同时核对59.3Hz消隐呈现上界 |
| `BURSTCHK` | 接收字数/提交burst数 =16（排空后）；提交字数/帧=153600；burst数/帧=9600；逐字地址图零diff |
| `BWCHECK` | `write_bytes/(frame_cycles/50e6)`≥15.36MB/s；显示110MB/s压力下零underflow，额外服务开销与40MB/s余额一起报告 |
| `DEADLINECHK` | 核周期/(50e6/24)≤0.84（35ms）；联合commit周期/(50e6/24)≤0.96（40ms） |
| `QUEUECHK` | 所有时刻0≤occupancy≤capacity，接受-释放守恒；停顿时payload稳定；reset前后epoch不串帧 |

每个比值要先检查分母>0、目标数量与轨迹长度精确相等；零测试、仅比较公共前缀、超时后退出0、打印FAIL却不返回失败都不算通过。重复/漏点可能维持总数量，所以必须比较序号/坐标全集和最终内存图。

向量至少包含：两套以上自定义DHT/DQT，非默认表选择，最大16位Huffman码，DC负差分、长ZRL，全部FF填充组合，DRI=1/3/40及跨7→0 RST，EOI/RST/段长度截断，最大40KiB帧、复杂度超界帧、513帧容器和超槽音轨。正确支持与预期拒绝分别统计。

### 9.2 集成后仍需跑的基线与本地验收

动态读数/提SPI频率、自研SDRAM侧口、音频适配分开提交与验证；每次都运行照片、卡带、音乐的原有仿真/构建判据，包括WAV 48k与44.1k的RATECHK/CHUNKCHK、PSG tick。现有CPU cosim测试台取指延迟不匹配为已记录基线问题，不能在本任务顺手修或把失败标通过。

TD综合/布局布线及板卡只能用户本地完成：核对工程Path、资源与所有真实时钟域slack，尤其pix不能新增负裕量；视频侧额外mux/扇出也可能影响时序，需要报告对比。核对新bit路径/时间戳后烧录，读回真实SPI服务率、音频gap/欠载、WR提交时间和显示underflow。未执行的本地检查明确标“待测”，不声称本稿已证明硬件24fps。

## 10. 分阶段实施与完成门槛

D0已经审阅；D1获准实施。每阶段再分成“一处功能改动+相应模型/TB/判据”的小提交，不把整个列表当作一次改动授权。

| 阶段 | 工作范围 | 自动完成判据 / 不通过即停止条件 |
|---|---|---|
| D0（已完成） | 设计文档并处理四条批注 | D1范围不写RTL、不改SPI共用冻结通路；演示素材≤21秒（504帧），512项是硬件容量而非建议素材时长 |
| D1 | Python标准库profile验证器、整数/浮点参考及周期模型；转换器约束单独提交 | 合成向量各阶段轨迹可再生；正例通过、负例精确错误码；40KiB/512帧/35ms等边界自动拒绝越界；不写卡 |
| S1（独立任务，D1后、D2前） | 仅把共用探针SPI_HIGHFREQ改为25MHz，独立提交/回归 | 照片、音乐、卡带三路仿真和TD构建回归全过；用户板上实测持续读率≥1.50MB/s且gap≤8ms。任一失败或板上待测都不得开始D2；既有CPU测试台失败要先建立可通过的有效基线，不能标通过 |
| D2 | 独立验证带地址16字SDRAM侧口及条带writer，不接JPEG | 压力模型RD2=110MB/s，BURSTCHK/BWCHECK/QUEUECHK全过；614400B帧commit≤40ms；TD增量资源仍在预算内。此门失败不继续堆解码器 ；当阶段模块加入TD工程综合，记录累计实测增量，任一资源偏差>30%停机（§7.1） |
| D3 | marker/tables/bits，分别逐模块实现 | 全部支持段与负例轨迹零diff，随机背压下BYTECHK/QUEUECHK通过；FF00/RST不串流 ；当阶段模块加入TD工程综合，记录累计实测增量，任一资源偏差>30%停机（§7.1） |
| D4 | Huffman、blockbuf/反量化分别实现 | 全64点零diff，BLOCKCHK/DQTCHK通过，量化溢出及非法run明确拒绝；周期模型与RTL逐拍计数一致 ；当阶段模块加入TD工程综合，记录累计实测增量，任一资源偏差>30%停机（§7.1） |
| D5 | IDCT单模块 | 每块176拍上限、整数点零diff、独立浮点≤3 LSB；TD映射8DSP且不溢出时序/资源 ；当阶段模块加入TD工程综合，记录累计实测增量，任一资源偏差>30%停机（§7.1） |
| D6 | MCU/颜色、条带接入，先存储器字节源喂JPEG | 307200像素及153600字地址图零diff；正常帧≤35ms无外部停顿；错误帧绝不发布前台 ；当阶段模块加入TD工程综合，记录累计实测增量，任一资源偏差>30%停机（§7.1） |
| D7 | S1通过后动态SD入口，再加PCM bridge/avsync（不在此时才验证提速） | PCM逐字节零diff，RATECHK/AVCHK通过；实际50MHz模型中音频gap≤8ms，基线回归结果逐项记录；本地SPI≥1.50MB/s待用户测 |
| D8 | 视频scanout与全系统接入，各阶段已注册工程后完整接入 | 504帧/21秒整机零丢正常帧/零音频欠载/零RD2underflow，后台commit≤40ms，呈现不超过一次刷新+0.5ms；所有旧模式单独回归 |
| D9 | 用户本地TD与板上验收 | LUT增量≤9,081且总数≤19,600、BRAM增量≤25、DSP增量≤29，各真实域无新时序失败；板上同一素材满足实际SD、WR/AV/欠载判据。没有这些实测不宣布完成24fps |

当前推进到D1；S1是独立硬门槛，S1未通过不能开始D2。短突发侧口、19块BRAM打包、40KiB最坏帧周期、各阶段综合增量都必须逐项验证，不用估算代替实测；不更改冻结main或发布云环境配置。
