# D2 MJPEG RTL：时钟域、SDRAM仲裁与资源约束

2026-10-31。本文先于本轮任何MJPEG RTL提交。用户本次D2范围覆盖完整解码链，取代旧阶段表中仅“SDRAM burst侧口”的D2定义；旧文档保留历史依据，本轮以本文为准。工作分支feat/mjpeg；main、冻结bit、厂商SD/SDRAM/HDMI IP不改。S1-B默认0旧两拍，SPI按用户板测结论改回12.5MHz；S1-B修复不阻塞本轮。

## 1. 12.5MHz带宽与向量账

板上有效SD服务率约1.30MB/s（十进制）；PCM=48000×2×2=192000B/s，余JPEG约1108000B/s。24fps可持续JPEG有效上限约46166B/帧=45.08KiB；还要扣512B扇区尾填充、头/表读取、重试及服务率波动，保守按每帧90扇区=46080B，不能把1.30MB/s贴线当作有安全余量。RGB565写入614400B/帧，24fps为14.7456MB/s，仍受显示约110MB/s、额外约40MB/s预算约束。

从f7b73e3原样取入向量，实际计算如下。KB/KiB严格区分；以下总SD含PCM与每帧扇区填充，未另计容器头表启动开销：

| 档位 | JPEG min…max B | 均值 B | JPEG MB/s | 含填充+PCM MB/s |
|---|---:|---:|---:|---:|
| budget | 45990…46912 | 46361.36 | 1.112673 | 1.310549 |
| stress | 60539…61481 | 61005.25 | 1.464126 | 1.662805 |

budget是贴线甚至略超1.30的压力输入；stress仅用于解码正确性/算力压力，不能声称可按该SD速率实时供给。RTL输入已在SDRAM的单帧JPEG，语法上限65535B，以容纳两种向量；“可解码”与“通过SD播放预算”分别判定。禁止静默修改fps/质量/分辨率。输入YXV表项offset/len提供精确边界，填充不进入JPEG解析器。

## 2. 时钟域与接法（实现前约定）

整个新数据通路运行在现有SDRAM控制器CLK的100MHz域`mem_clk`：读命令→32位读响应拆字节→JPEG解析/熵解码→IDCT→MCU/RGB→8字突发写。像素域不增加组合逻辑，不在pix侧放JPEG状态、乘法或仲裁。sys50的帧表读取/音频采样调度通过单在途held-bus+toggle邮箱送帧命令；邮箱目的域两级同步toggle、稳定多位载荷再捕获，响应返回前源载荷不变。复位要求两个域同时复位并放弃在途帧，禁止只复位一端继续旧事务。

本轮顶层`media/mjpeg/yingxu_mjpeg_decoder.v`接收已从YXV表读取的`src_addr`（21位32bit word地址）、`jpeg_bytes`（16位精确长度）、`dst_addr`（21位RGB565帧首word地址）；帧表offset为512B对齐，调用者按`SDRAM_container_base + offset/4`换算。目的640×480帧固定153600个32bit word，命令检查源/目的8MB边界且禁止区间重叠。支持背靠背独立帧，表/DHT/DQT/预测器逐帧重新初始化，错误帧不发布commit。音轨不经过解码器，仍由现有WAV通路消费、采样计数决定何时发帧命令。

输入最多64KiB、输出614400B，不在BRAM存整帧。例：两个JPEG staging槽各64KiB（合计128KiB）和两个640×480 RGB565缓冲合计1.2288MB，加原720p两帧3.6864MB仍小于8MB；实际分区由调用者配置并做防重叠检查，不在本轮改现有照片显示分区/扫描器。

## 3. SDRAM事务及优先级

新模块输出控制器域标准R/V burst接口：命令`valid/ready, write, addr[20:0], words[3:0]`（1…8）；读响应`rvalid/rready/rdata[31:0]/rlast`，写数据`wvalid/wready/wdata[31:0]/wlast`，事务完成`done/error`。读命令接受不代表数据到达，写数据接受不代表物理SDRAM提交；只有对应done才释放事务。每次只允许一个在途burst，先收齐本次8字写载荷再请求，之后冻结owner到真实完成，禁止半突发抢占。

`yingxu_mjpeg_arbiter.v`在同一mem_clk域按 **SDRAM物理刷新（控制器内部最高）>显示读>解码写>JPEG预取/其他** 选择新事务。显示请求在burst边界抢占，不能打断已接受burst；最长低优先事务8字，结合物理控制器单burst延迟给出显示额外等待界。JPEG预取属于其他请求，因只有单在途而可能回压熵流；输出/MCU缓冲满时逐级背压，不丢数据。无显示空档时低优先可能饥饿，这是严格优先策略的显式条件；不以强插读写破坏显示优先级，报告deadline超时并停帧。

现有`yingxu_sdram_control_4port`只有自动增长FIFO口，不能直接把“带随机地址命令”伪接到WR2_LOAD；其LOAD会清FIFO，也没有逐burst commit回执。因此本轮交付独立解码master+仲裁器及可执行SDRAM事务模型，**不把现有自动FIFO接口假称为已接通的随机侧口**。接入板上控制器时需在自研派生控制器服务边界实现上述adapter（厂商src/5640不动），并验证真实done/刷新/显示延迟；本轮不激活冻结顶层的视频模式或替换显示器。模块级RTL验收和板上集成状态分开报告。

## 4. 模块层次与接口

| 文件（media/mjpeg/） | 接口/职责 |
|---|---|
| `yingxu_mjpeg_decoder.v` | 帧cmd R/V→读写burst master；字节拆包、输入长度与输出最终commit；mem_clk100 |
| `yingxu_jpeg_core.v` | byte R/V→pixel R/V；解析SOI/DQT/SOF0/DHT/DRI/SOS/EOI，动态表、canonical Huffman、反量化、双系数bank；mem_clk100 |
| `yingxu_jpeg_idct.v` | block start/busy/done，系数同步读地址/返回，sample写地址/数据；8 lane MAC两遍Q16；mem_clk100 |
| `yingxu_jpeg_rgb.v` | MCU双bank，IDCT样本写入；同步读Y/Cb/Cr、4:2:0近邻、Q14颜色、pixel R/V及地址；mem_clk100 |
| `yingxu_mjpeg_arbiter.v` | 三客户显示读/解码写/其他→单物理事务，命令稳定及owner保持；mem_clk100 |
| `yingxu_mjpeg_mailbox.v` | sys50↔mem100单在途帧命令与状态；held bus+toggle |

byte为8位，pixel为RGB565 16位，坐标x10/y9；所有R/V仅valid&&ready时前进，背压期间载荷/首尾保持。IDCT每块64样本，按自然序索引，块序Y0/Y1/Y2/Y3/Cb/Cr；MCU40×30，每MCU256像素。渲染器仅在完整MCU可用时启动，上一MCU未释放不得覆盖bank。

支持8bit Baseline SOF0、固定640×480、3组件1/2/3、采样22/11/11、单交织SOS。DHT解析自定义DC/AC表0/1，canonical描述符查表而非65536项大LUT；DQT支持自定义8bit表0/1（非零），Cb/Cr共用选择；DRI/RST按MCU间隔和RST0…7顺序校验并清DC预测器，EOI要求精确帧尾。APPn/COM按长度跳过。拒绝progressive/算术/12bit/非420/多扫描/16bit DQT/缺表/非法码/重复符号/越界run/截断；错误锁存code，停止新写，已接受burst必须排空，不发布帧完成。看门狗覆盖输入永不返回和恶意熵流，超时也是失败，不允许$finish(0)假通过。

## 5. 增量资源预算（估算，非TD实测）

新约束替代历史15 BRAM整机方案：本轮解码器+邮箱+仲裁目标 **≤8000 LUT、≤6块BRAM9K**，不包含既有39块，也不把已有FIFO改成零成本新存储。帧表与PCM仍属外部既有/后续模块，D2不分配4块帧表RAM或PCM reservoir。

| 模块 | LUT目标 | BRAM9K | DSP18×18估算 |
|---|---:|---:|---:|
| byte/marker/表装载/边界检查 | 1400 | 0 | 0 |
| Huffman描述符64×32＋symbols/DQT共1024×8 | 1400 | 2 | 0 |
| 熵流/双系数128×24/反量化 | 1100 | 1 | 1 |
| 8 lane两遍IDCT，temp64×27、乘积寄存与48bit累加 | 1500 | 1 | 16（宽输入拆分） |
| 双MCU1024×8/取样/颜色 | 750 | 1 | 4 |
| burst打包/字节拆包/地址/commit | 800 | 0（8字寄存器） | 0 |
| 仲裁/邮箱/看门狗 | 450 | 0 | 0 |
| 合计与预留 | **7400＋600预留=8000** | **5＋1预留=6** | **21≤29** |

**实现前资源修订：BRAM端口宽度必须入账。** 器件单读单写BRAM端口最多18位，不能把24/27/32位数组各算一块。保持上述5块目标，将系数打包为256×16（每个s24占两word），转置为128×16（s27占两word），描述符为128×16（32bit分两word）；符号/DQT和MCU仍各1024×8。每个RAM只有一个同步读和一个写口，均在9K容量内。清块128写拍，Huffman每码位3拍，IDCT两拍组装一个输入、16拍串行存一个向量；RTL实测**293拍/块**；100MHz下7200块约21.6ms，必须重测整帧，不能再引用旧176拍。增加的时序成本用100MHz域预算承担，不裁剪系数或借第7块BRAM。

宽IDCT避免旧稿±2048系数裁限：DC predictor检查有符号16bit溢出，DQT8bit相乘存s24；第一遍存s27，lane乘法16bit Q16常数、48bit累加，末级clip8bit。真实TD可能拆为不同DSP数量，≤29仍是硬限。表RAM/系数/temp/MCU均同步读、避免组合多口导致寄存器展开；不要对存储阵列全体复位，仅清valid或逐项写零。输出8word FIFO采用显式小寄存器，计入LUT。

所有资源及100MHz slack在云端仅估算；提供可综合层次和仿真周期实测。用户本地必须将完整D2顶层作为综合根（不能未实例化而报0增量），核对实际映射和所有时钟slack。累计资源相对估算偏差>30%、LUT>8K、BRAM>6、DSP>29或新真实时序违例立即停机重设计，不能将旧39块预算余量当本轮豁免。pix不增加逻辑但布线影响仍需本地对照。

## 6. 验证与停止线

逐点比较DHT/DQT、每块64反量化系数、IDCT第一遍及64样本、MCU坐标/RGB565，最后将突发写入SDRAM模型的完整帧与Python整数金标逐字节比对；对三个已提交ffmpeg RGB24参考帧分别计算PSNR≥35dB（RGB565扩展回8bit再比较）。先完整跑全部72帧的结构/熵模型，再跑代表帧与整个36帧RTL序列；计数正确之外必须检查地址覆盖每点一次、bit-exact图像及PSNR，不只数像素。

周期以真实100MHz计：无背压与显示110MB/s压力下分别报告frame cycles/(100e6/24)、突发写提交字节/614400、最后物理done时刻；不能引用旧176拍IDCT估算冒充实测。截断帧、坏DHT、非420、缺表、非法码、随机R/V停顿、同/异时钟邮箱、仲裁显示抢占与已接受写排空全部需自动失败/成功判定。任何错误不得提交前台帧；一帧失效不污染下一帧表/预测器。PSNR、资源、周期任一未过必须报告，不能推进板上视频可用结论。

## 7. 实现后的精确端口约定

下表组合成每个模块的完整外部端口。除邮箱外均在100MHz `clk`；`rst`为同步高有效。R/V未握手时保持载荷；`done`是单拍终态通知，成功发布帧必须同时`done && !error`，不能照搬此前“LS完成就认为成功”的做法。`committed_words`是已收到成功mem_done回执的后台字数；报错burst可能已部分落RAM但不计入该数，错误帧后台一律无效，不能据此交换前后台。

### 7.1 `yingxu_mjpeg_decoder`

| 信号 | 位宽、方向 | 握手/单位 |
|---|---|---|
| clk/rst | 1/1入 | 必须100MHz；接sys50将无法沿用24fps周期结论 |
| frame_valid/frame_ready | 1入/1出 | 单在途帧，idle接受命令 |
| src_addr/dst_addr/jpeg_bytes | 21/21/16入 | SDRAM **32bit word地址** / JPEG精确字节数4…65535；输出固定153600word，检查8MB边界及源/目的不重叠 |
| busy/done/error/error_code | 1/1/1/8出 | error保持到下一帧，done成功/失败均可拉高；只有无error才可前台commit |
| frame_cycles/committed_words | 32/18出 | 100MHz周期/已完成后台32bit字数，含真实mem_done等待 |
| cmd_valid/cmd_ready/cmd_write | 1出/1入/1出 | 请求R/V；write1写、0读 |
| cmd_addr/cmd_words | 21/4出 | 首word地址，1…8个32bit word；接受后owner保留到mem_done/error |
| rvalid/rready/rdata/rlast | 1入/1出/32入/1入 | 读数据R/V，last必须精确落在cmd_words尾；内部8word容量在发读前预留 |
| wvalid/wready/wdata/wlast | 1出/1入/32出/1出 | 写数据R/V；先组满8word再发cmd，第一像素在word高16位；不因core报错撤销已接受写 |
| mem_done/mem_error | 1/1入 | 底层事务物理终态，可与最后数据握手同拍；mem_done不是cmd_ready或wlast的别名 |

读响应用小缓存拆成little-endian字节送核；末word未使用的0…3字节不进入解析。写地址`dst+(y<<8)+(y<<6)+(x>>1)`，每MCU每行16像素=8word，整帧19200个突发；每个后台word恰写一次。core出错后停止新事务，已经暴露且valid等待ready的命令仍保持，已接受事务排空。底层报错/rlast不符也会在排空后显式cancel复位核，下一帧可恢复，不依赖JPEG核自己先空闲。

物理内存永不响应时没有安全的“假装完成”：core有8,000,000拍（80ms）默认看门狗，但master仍必须等待已接受事务的真实终态或控制器共同复位。这与坏JPEG/坏表有明确错误退出不同；调用者不能只复位decoder后继续接收旧burst。

### 7.2 `yingxu_jpeg_core`

| 信号 | 位宽、方向 | 约定 |
|---|---|---|
| clk/rst/start/frame_bytes | 1/1/1/16入 | start仅空闲有效；逐帧清表valid、预测器与流水控制 |
| byte_data/byte_valid/byte_ready | 8入/1入/1出 | 顺序精确JPEG字节，握手字节数不得超frame_bytes；parser不接受扇区填充 |
| pixel/pixel_x/pixel_y | 16/10/9出 | RGB565，坐标0…639/0…479；输出为MCU内行序，跨MCU不是整帧光栅顺序 |
| pixel_valid/pixel_ready | 1出/1入 | 每次接受一个唯一像素；背压停止覆盖MCU bank |
| busy/done/error/error_code/cycles | 1/1/1/8/32出 | 有界语法/表/run/EOF错误、80ms看门狗；解析EOI及最后像素接受后才无错done |

主要错误码：01帧太短；02/03标记；04不支持process；05段长；09/0A DQT；0B…0E DHT；10 SOF/采样；11/12 SOS/缺表；20截断；21非法Huffman码；23越界run；24 DC预测器溢出；25 RST；26 EOI/填充/尾随；30看门狗。master额外80地址/长度，81 rlast，82内存终态错误，83提交守恒失败。错误码精确匹配也在TB断言，不只验证error曾拉高。

### 7.3 `yingxu_jpeg_idct`

| 信号 | 位宽、方向 | 约定 |
|---|---|---|
| clk/rst/start/bank | 1/1/1/1入 | start时锁定系数bank；仅busy0启动 |
| busy/done | 1/1出 | done单拍，每块实测293拍（含尾部）；不引用旧176拍 |
| coeff_addr/coeff_data | 8出/16入 | 同步读1拍；addr={bank,natural_index[5:0],half}；低word在偶地址，高word符号扩展在奇地址 |
| sample_valid/sample_addr/sample_data | 1/6/8出 | 自然序8×8坐标写脉冲，无反压；对下游完整bank空间在start之前预留 |

内部temp128×16、s27分两word，8 lane各27×16乘法加48bit累加；先行后列，两遍`floor((sum+32768)/65536)`。第一遍全部64中间点及最终64样本都有Python金标对照；带255000等宽反量化系数的向量验证未截到旧s12范围。

### 7.4 `yingxu_jpeg_rgb`

| 信号 | 位宽、方向 | 约定 |
|---|---|---|
| clk/rst | 1/1入 | 100MHz |
| sample_valid/sample_bank/sample_block/sample_index/sample_data | 1/1/3/6/8入 | 无反压IDCT写；block0…3为Y四块，4/5为Cb/Cr |
| mcu_done/mcu_x/mcu_y | 1/6/5入 | 最后块所有样本落RAM后发布完整MCU，元数据保持到下一完成脉冲 |
| bank_free | 2出 | 只有对应位1才允许该MCU的首块IDCT启动；full一直保留到最后像素握手 |
| pixel_valid/pixel_ready/pixel/pixel_x/pixel_y | 1出/1入/16出/10出/9出 | 同core像素接口；近邻420，full-range YCbCr，Q14舍入、clip后取565 |

### 7.5 `yingxu_mjpeg_arbiter`

| 信号 | 位宽、方向 | 约定 |
|---|---|---|
| clk/rst | 1/1入 | 100MHz |
| cvalid/cready/cwrite | 3入/3出/3入 | bit i对应客户i：0显示读，1解码写，2JPEG预取/其他 |
| caddr/cwords | 63/12入 | `[21*i+:21]`首word，`[4*i+:4]`长度1…8 |
| cwvalid/cwready/cwdata/cwlast | 3入/3出/96入/3入 | wdata按32bit客户slice；仅owner获得ready |
| crvalid/crready/crdata/crlast | 3出/3入/32出/1出 | 共用返回数据，只向owner拉valid；其他客户端不得采样 |
| cdone/cerror | 3/3出 | 单owner终态；错误后也释放owner |
| mvalid/mready/mwrite/maddr/mwords | 1出/1入/1出/21出/4出 | 物理服务命令R/V |
| mwvalid/mwready/mwdata/mwlast | 1出/1入/32出/1出 | 物理写数据R/V |
| mrvalid/mrready/mrdata/mrlast | 1入/1出/32入/1入 | 物理读数据R/V |
| mdone/merror | 1/1入 | 真正事务终态，之前不切owner |

仲裁优先级只在新选择时生效。若已向物理接口暴露命令并被ready反压，锁住该选择以遵守R/V，后来的显示请求也不能改掉已暴露的地址；因此显示额外延迟界还须包含物理cmd_ready的最大等待，不能只报8word载荷时间。未给出ready上界时不能证明显示不欠载。

decoder是单物理master，接本仲裁器时按cmd_write把其cmd_valid分别路由到客户1（写）/2（读），cmd_addr/words复制到两个slice，ready按类型选回；读写data及终态按owner回连。显示控制器的请求接客户0。最后m*服务接口需在自研SDRAM控制器burst服务边界适配；不能接到会清FIFO的WR2_LOAD。此处明确接线与握手，**尚未修改冻结顶层或现有四口控制器来启用这个侧口**。

### 7.6 `yingxu_mjpeg_mailbox`

| 信号 | 位宽、方向 | 域与约定 |
|---|---|---|
| sclk/dclk/rst | 1/1/1入 | sys50 / mem100 /共同复位 |
| svalid/sready/spayload | 1入/1出/WIDTH入 | sys，默认58bit，建议{src_addr21,dst_addr21,jpeg_bytes16}；握手后内部hold |
| sdone/sstatus | 1/STATUS出 | sys，默认STATUS9={error,error_code}；一帧一个回执 |
| dvalid/dready/dpayload | 1出/1入/WIDTH出 | mem，先同步toggle，再额外一拍捕获稳定载荷，valid到握手保持 |
| ddone/dstatus | 1/STATUS入 | mem，接受命令后至少下一拍才给终态；状态hold至源域两级ack同步完成 |

## 8. 当前交付与本地门禁

完整软件证据见 [D2_MJPEG_REPORT.md](D2_MJPEG_REPORT.md)；`tools/mjpeg_d2_verify.py`生成独立参考并运行RTL，`tools/mjpeg_d2_synth.py`仅生成Anlogic RAM映射和DSP剥离的LUT风险估计。源码清单`tools/mjpeg_d2_sources.f`，独立100MHz时钟约束`tools/mjpeg_d2_timing.sdc`供模块综合使用，不能替换板上timing.sdc。新模块未接入冻结顶层，不能对原工程直接构建后声称测到了D2的面积。

本地TD须以完整decoder作模块综合根，并保留mailbox/arbiter增量；确认宽乘法确实按预计≤21 DSP实现（硬限29），5个打包RAM没有展开/复制到>6 BRAM，全部D2增量LUT≤8000，实际与估算累计偏差≤30%。解码器预留600 LUT亦须支付真实SDRAM侧口适配成本，不能在接入时算“免费”。接通自研控制器实际服务口后，在同一完整工程中复跑显示优先级/物理commit、时序和板上视频验收；云端没有TD工艺库/布线器与板卡，不给虚构的slack或实测LUT。
