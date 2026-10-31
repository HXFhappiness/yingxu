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

宽IDCT避免旧稿±2048系数裁限：DC predictor检查有符号16bit溢出，DQT8bit相乘存s24；第一遍存s27，lane乘法16bit Q16常数、48bit累加，末级clip8bit。真实TD可能拆为不同DSP数量，≤29仍是硬限。表RAM/系数/temp/MCU均同步读、避免组合多口导致寄存器展开；不要对存储阵列全体复位，仅清valid或逐项写零。输出8word FIFO采用显式小寄存器，计入LUT。

所有资源及100MHz slack在云端仅估算；提供可综合层次和仿真周期实测。用户本地必须将完整D2顶层作为综合根（不能未实例化而报0增量），核对实际映射和所有时钟slack。累计资源相对估算偏差>30%、LUT>8K、BRAM>6、DSP>29或新真实时序违例立即停机重设计，不能将旧39块预算余量当本轮豁免。pix不增加逻辑但布线影响仍需本地对照。

## 6. 验证与停止线

逐点比较DHT/DQT、每块64反量化系数、IDCT第一遍及64样本、MCU坐标/RGB565，最后将突发写入SDRAM模型的完整帧与Python整数金标逐字节比对；对三个已提交ffmpeg RGB24参考帧分别计算PSNR≥35dB（RGB565扩展回8bit再比较）。先完整跑全部72帧的结构/熵模型，再跑代表帧与整个36帧RTL序列；计数正确之外必须检查地址覆盖每点一次、bit-exact图像及PSNR，不只数像素。

周期以真实100MHz计：无背压与显示110MB/s压力下分别报告frame cycles/(100e6/24)、突发写提交字节/614400、最后物理done时刻；不能引用旧176拍IDCT估算冒充实测。截断帧、坏DHT、非420、缺表、非法码、随机R/V停顿、同/异时钟邮箱、仲裁显示抢占与已接受写排空全部需自动失败/成功判定。任何错误不得提交前台帧；一帧失效不污染下一帧表/预测器。PSNR、资源、周期任一未过必须报告，不能推进板上视频可用结论。
