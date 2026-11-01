# D3 顶层集成交付（历史记录，2026-11-01）

> 更新：用户板测发现启动/仅背景问题。当前已合入D4a 372005d、D4b 612fe6c；新演示组合SW=77，不能沿用旧E7的软件通过结论。用户TD实测12186 LUT、41 BRAM、0 DSP，余7414 LUT；旧“仅余341”为代理估计，已被这次实测取代，完整解码逻辑是否保留仍待层次报告核对。审查阻塞项和Fmax/phy记录见 [D4_REVIEW.md](D4_REVIEW.md)。

代码提交 `696bde3`，分支 `feat/mjpeg`。实际 `hardware_test` / `design_top_wrapper` 已连接 SD→帧表/预载→JPEG→物理SDRAM→RD2显示、原WAV和原UART。3秒软件集成门禁通过；未生成bit、未运行TD、未声称板上验收通过。main、冻结固件、厂商IP、SPI频率和旧两拍排空均保持本阶段基线。

## 构建与进入

本地切到 `feat/mjpeg` 并pull，TD打开仓库根 `AC201_AL_board_test.al`，顶层仍为hardware_test。全部MJPEG源已登记，不需手工加文件。`SIM_FAST_BOOT` 默认0，`VIDEO_ACQUIRE_LIMIT` 默认250000000个sys周期（5秒），测试使用的启动加速参数不得带入板上构建。

当前演示入口按D4a改为SW7 ON、SW3 ON，SW4/5/6 OFF（其余OFF时SW=77）。本报告以下3秒日志使用历史D3的E7组合；D4新组合存在审查阻塞，见D4_REVIEW。首版读视频槽0，LBA3000000；写卡仍使用现有YXV格式/工具。只接受640×480@24、48k stereo，1…512帧，PCM长度严格等于frames×8000；演示素材仍≤21秒。不静默改fps、分辨率或压缩质量。

视频进入后先完整预载PCM，再准备两帧RGB及首次呈现，最后预充原WAV FIFO至256样本并放行48k节拍。budget启动首个音频采样约329.355ms（仿真缩短了SD上电/刷时钟等待；此数不是板上启动时间）。循环36帧两遍取3秒，PCM首尾逐样本连续。退出/格式错误/解码错误先排空已接受事务再释放所有权，触发一次照片重载；失败锁存，拨出再拨入才重新尝试。等待SD空闲/初始化也有5秒获取超时。没有卡时只能回到照片模式/原错误显示，不能保证照片能从缺失的卡加载。

## 模块、时钟及握手

新文件均在 `src/user_source/hdl_source/media/mjpeg/`。

| 模块 | 域及主要接口 | 行为 |
|---|---|---|
| yingxu_yxv_pipeline.v | sys50 / mem100 / pix73.33；enable/owned/failed、SD事务、burst、RD2、PCM和统计 | 所有权/启动/解码/呈现调度；错误后排空；音频pop推进PTS |
| yingxu_yxv_loader.v | mem100；SD cmd valid/ready,LBA28,count16,done；byte8 R/V；write burst | 流式检查32B头，512×35同步帧表；PCM预载；两JPEG槽，release后才复用 |
| yingxu_media_async_fifo.v | sys↔mem；WIDTH位R/V，ABITS+1位占用 | 分布式RAM；Gray指针两级同步；背压不前进 |
| yingxu_yxv_pcm_feed.v | mem100→sys50；read burst、PCM bytes32、WAV byte8 R/V | SDRAM连续8word读，16word异步FIFO，合成32B YXMA头，EOF后继续发头 |
| yingxu_yxv_scanout.v | pix；{tag32,bank1} valid/ready/done；RD2 data32/empty/en/LOAD/base21/max21/len9 | x320…959,y120…599中心窗口，565高半先出；y600消隐换bank |
| yingxu_sdram_burst_port.v | mem100；cmd R/V,write,addr21,words4；data32 R/V,last；done/error | 逻辑1…8word转固定8word物理访问；短写DQM保护、短读丢尾；真实done才完成 |
| D2 decoder/arbiter/mailbox | mem100；沿用D2端口 | 解析/熵/IDCT/RGB主体未改变；两个仲裁层及held-bus邮箱连接新调度 |

所有R/V只在valid&&ready前进，反压保持地址/数据/last。物理写预存完整burst，读收齐后再返回。命令一旦暴露/接受，owner冻结至真实done/error；不能用WR2_LOAD模拟随机写。合法21bit地址按8word对齐且长度≤8，天然不越8MB；物理TB额外验证最后8word及非法对齐/0/9长度。

控制器优先级为物理刷新 > RD2显示 > 解码写 > 其他；其他内部为PCM读 > SD staging写 > JPEG读。低优先不打断既有事务。SD命令用44bit邮箱跨域，字节经64B FIFO；呈现用17bit邮箱（16bit循环tag+bank）。实际音频pop在pix累计32bit、Gray同步至mem/sys；呈现提前960采样请求，在随后消隐交换。PTS低22位用有符号模差比较，计数回绕不改变调度；内部帧tag及D帧计数模65536，PC模1024。

LOAD保持256个pix时钟，覆盖旧128word读尾；仅视频活动时清RD2 FIFO，预充完成才ACK并释放旧前台。未成功完整解码不发布后台。启动未发布/未预充禁止弹FIFO。RGB选择放在原player既有输出寄存器入口，未串入原亮度/对比度组合计算。既有timing.sdc已声明sys/HDMI/SDRAM异步时钟组，沿用；所有新算术及仲裁位于mem100，pix仅扫描/切换/音频计数。TD仍须检查新并行路径与旧关键路径。

## 内存及带宽

| 内容 | 32bit word地址 | 容量 |
|---|---|---|
| RGB A / B | 000000 / 040000 | 各614400B，预留槽各1MiB |
| JPEG 0 / 1 | 080000 / 084000 | 各64KiB |
| PCM | 100000…1FFFFF | 4MiB，最大有效4096000B |
| 照片 | 100000起 | 与PCM分时复用，退出重载 |

帧表外部仍offset32/len32；内部只在验证512对齐、offset<256MiB及长度4…65535后压成19+16位。最后PCM末端也检查256MiB视频槽边界。

budget含每帧填充JPEG需1.118549MB/s；同时从SD实时读PCM会升至1.310549MB/s，超出1.30预算。因此本版预载PCM；播放期SD只读JPEG，实测仿真平均1.121450MB/s（含预取边界），未降低24fps。PCM从SDRAM读0.192MB/s。RGB写14.7456MB/s，加JPEG staging写约1.119MB/s，共约15.864MB/s，小于40MB/s写预算。按保守显示110MB/s计，加JPEG/PCM读及写共约127.2MB/s；中心窗口实际读量更低，不据此放宽旧带宽上限。没有SRAM改动。

## 历史资源与时序估计（不是TD；当前实测见D4_REVIEW）

| 项目 | LUT4估计 | BRAM9K增量 | DSP18估计 |
|---|---:|---:|---:|
| 完整pipeline，含D2、供给、两个仲裁、CDC、PCM、scanout | 8233 | 7（D2五块+帧表两块） | 21 |
| framebuffer/四口适配相对关闭配置的差值 | 157 | 0 | 0 |
| 板级复用/复位/模式/遥测预留，人工估计 | 350 | 0 | 0 |
| 合计 | **8740** | **7；全机约46/64** | **21/29** |

冻结10519 LUT加8740估计为19259/19600，当时代理估计仅剩341；此结论不适用于用户当前提供的TD实测（剩7414）。D2解码器≤8K/≤6BRAM的子模块门禁保持，D3的帧表两块另列，不能把整链7块说成D2的5块。TD实际新增>9081、DSP>29、BRAM超器件、任意时钟负slack或累计偏差>30%均停机；容量线优先于30%偏差线。请先综合看资源和pix时序，再构建烧录。

方法：初轮约11.1K未过，实际缩减头缓存/位宽/帧表；最终先做width reduction及真实RAM映射，再以本器件原生LUT4为ABC目标，13个逻辑乘法仅在面积代理中黑盒化，另付344 LUT宽乘合并预留。8233包含实际所有新pipeline控制，没有450估计邮箱重复加账。早期4…6输入LUT折算约9.3K的口径不能直接当作本次LUT4网表；保留TD映射不确定性，不能把代理当实测。物理差值模型保持原PLL/FIFO/SDRAM宏黑盒，对继承CS_N端口/内部宽度不一致只在分析副本显式化，不修改厂商文件。报告JSON及脚本均已提交。

| 路径 | 周期预算/状态 |
|---|---|
| mem100 解码 | 顶层73帧各约2.46…2.52M拍，24fps上限4.166667M；最终逐帧值见原始日志 |
| sys50 SD | 12.5MHz、旧两拍排空，源模型含每扇区间隔，服务限制约1.30MB/s |
| pix73.33 | 13.636ns，未测TD slack；禁止将旧+0.66ns当作新版本保证 |
| SYS/PIX/MEM CDC | FIFO Gray+2FF、邮箱held-bus+toggle；共同复位/在途排空；真实布线待TD |

## 验收及复现

实际板级top运行，SD侧将整个厂商sd_card_control按受限速的扇区服务建模，未仿真SPI命令/电气；另建模SDRAM介质、PLL/FIFO和加密HDMI/PHY。真实SD探针/两拍reader/RAM读延迟、真实自研四口控制器及厂商command/control_interface/data_path、真实JPEG与WAV均参与。不是SPI电气或SDRAM引脚时序仿真；TD及板测由用户完成。SIM_FAST_BOOT只缩短上电/刷时钟等待；播放50/100/73.33MHz及48k不加速。noinit用15ms参数测试获取超时分支，板上默认5秒。

```text
PLAYCHK: PASS samples=144001/144001 duration_ns=3000000066 frames=73 swaps=73 drops=0/72 ratio_x1M=0
AVCHK: PASS max_abs_samples=1849/2000 ratio_x10000=9245 checks=220002046
TOP_PIXCHK: PASS words=11212800 decoded zero-diff scanout pixels=55053610 RGB565-high-half-first
TOP_PCMCHK: PASS samples=144001 L/R zero-diff including EOF loop 48k actual-clock
RATECHK: PASS 48k error_ppm=0 limit=100 HDMI_samples=144000 zero-diff
SDBUDGETCHK: PASS bytes=3364352 measured_Bps=1121450 limit_Bps=1300000 PCM-from-SDRAM
MODECHK: PASS switch-out quiescent photo-reload=1
TELEMCHK: PASS wire UART D-lines=14 decoded/display/drop/SD fields visible
```

73张包含提前准备的下一帧；分母72是3秒播放期望帧数。全部已写帧与独立Python整数金标逐word比较，扫描窗逐像素检查，并检查真实player/背景复用和HDMI音频输入。0/72严格小于1%，1849/2000严格小于一帧；逐tick检查无WAV欠载、无前台覆盖。坏头和卡初始化不结束均有限退出并触发一次照片重载；回退测试只证明模式释放/重载请求，完整照片数据正确性由独立BMP回归覆盖。

分路结果：照片921600/921600像素零diff；WAV48k RATECHK=9991/10000、CHUNKCHK九次精确；WAV44.1k RATECHK=9180、期望9187、CHUNKCHK九次精确；卡带从mirror头读取604词，BADC0UNT=0 of 604、WC=0x25C。完整原始输出分别保存，未把已知CPU cosim基线问题计为通过。供给单测另覆盖512帧/4096000B PCM、全部压缩表项及跨末帧回绕。

```bash
python tools/mjpeg_d2_verify.py --prepare-only
python tools/yxv_d3_units.py
python tools/yxv_d3_verify.py
python tools/yxv_d3_verify.py --no-build --bad 1
python tools/yxv_d3_verify.py --noinit
python tools/yxv_d3_synth.py
python tools/yxv_d3_physical_synth.py
PATH=/path/to/iverilog/bin:$PATH python tb/run_sd_drain.py
```

Python需numpy，顶层仿真需Verilator5及C++编译器。全部原始输出、实际UART、资源JSON和源码SHA256见 [evidence/D3](evidence/D3)。D2 JPEG四个主体文件与a35f9ef逐字相同；ffmpeg参考PSNR沿用D2已验39.38dB（budget帧0，位复制扩展），本次新增物理/显示路径逐点零diff。未重报未运行的TD或板测结论。

## D帧解释

串行字段标签沿用旧格式，RTL的P0/P18在UART实际标签为I0/I1。请求、owned或failed期间使用下表；原音乐/卡带其他模式保持原解释。

| 字段 | 视频含义 |
|---|---|
| MISE | 无错解码完成计数，低16位 |
| PC / RC | 最近呈现tag低10位 / 呈现次数低16位；RC=0时PC=3FF，尚未呈现 |
| DW | 丢帧/解码失败计数低16位，目标0 |
| I1 | 实际音频pop低24位，48k推进 |
| SCE | bit15=SD busy，bit6…0=跨域FIFO占用字节；中间保留0。是即时占用，不是百分比读率 |
| SP | 固定BB80=48000 |
| I0 | bit23 owned，22音频使能，21失败，20 PCM预载完成，19解码busy，18模式请求；17…16与7…0拼成10bit帧数；15…8错误码 |

错误91内存写、92头、93帧表/边界、95音频读、9E视频超期、9F进展/获取超时；JPEG错误沿用D2。UART原格式逐字符读取live字段，不是原子AV快照，临界跨帧可能相差1；严格AV结论来自顶层逐pix判据。板上建议检查I0进入播放、PC/RC/MISE增长、DW=0、I1约每秒48000，并测完整工程LUT/BRAM/DSP和各域slack后再烧录。
