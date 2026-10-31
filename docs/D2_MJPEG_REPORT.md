# D2 MJPEG RTL交付与验证报告

2026-10-31（Asia/Shanghai）；工作分支feat/mjpeg。**交付完整Baseline420解码模块、从SDRAM读/向SDRAM突发写的master、仲裁器和跨域邮箱；模块级数据通路已验证。现有四口SDRAM控制器的随机侧口尚未接入，未激活板上视频模式；不是已完成板卡集成的播放器。** 无TD/板卡，不伪造本地面积、slack或新bit。

## 1. 先行修订与范围

已从`video-testvectors@f7b73e3`原样取入测试向量/提取工具，main保持不变。先提交`d56d02a`板测工作点12.5MHz＋原两拍及向量，再提交`754200c`时钟/SDRAM仲裁/资源设计，随后`f4b5516`明确物理BRAM端口宽度打包，再实现RTL。唯一既有生产RTL变化是probe的25_000_000→12_500_000；sd_stream_reader_core默认0保留，厂商IP、旧四口控制器、冻结bit/顶层和约束不改。

按本次新范围，D2包含字节→SOI/DQT/SOF0/DHT/DRI/SOS解析→动态canonical Huffman→反量化→两遍IDCT→MCU双bank→420近邻RGB565→8word地址突发写。支持自定义8bit DQT/DC-AC Huffman表0/1、DRI/RST0…7回绕；单帧4…65535B，640×480三组件420单交织扫描。逐帧重置表valid与预测器，拒绝非Baseline/非420/坏表/越界run/缺EOI等。宽系数s24、转置s27，未把旧D1±2048限制强加给本轮RTL。

文件及完整端口/接线见 [D2_MJPEG_ARCH.md](D2_MJPEG_ARCH.md#7-实现后的精确端口约定)。六个RTL文件位于`src/user_source/hdl_source/media/mjpeg/`；`yingxu_mjpeg_decoder`为模块综合根。YXV表与PCM由外部调度器提供，不额外申请4块帧表或PCM缓存BRAM；源地址按容器SDRAM基址+表项offset/4换算。

## 2. SD预算与解码预算分别验收

12.5MHz有效约1.30MB/s，扣PCM192000B/s后JPEG约1.108MB/s，24fps为46166B/帧≈45.08KiB；保守每帧90扇区46080B。实际budget含填充+PCM为**1.310549MB/s**，略高于1.30（约0.81%）；stress为**1.662805MB/s**，只作解码压力输入。不能把已在SDRAM的解码性能冒充SD卡足以持续供给此素材；未降fps/质量或改变YXV头。

RGB565写每帧614400B，24fps有效14.7456MB/s；JPEG由SDRAM读取约1.1MB/s，若前级又写SDRAM staging还需另计约1.1MB/s，不漏双向交通。原显示110MB/s、其他40MB/s账保留。

## 3. 时钟、仲裁与周期实测

所有新像素运算在现有SDRAM控制器100MHz域；pix域新增组合逻辑0。sys50帧命令通过held-bus+toggle邮箱；邮箱/内存控制器/decoder需共同复位取消在途帧。仲裁物理刷新先于显示读，之后解码写，再JPEG预取/其他；已暴露或已接受突发不抢占，8word上限；必须有物理ready/完成延迟上界才可证明显示等待界。

下表实测使用事务SDRAM模型：为显示及原系统保留110MB/s，并将新master数据服务机会限制为100MHz中每40拍4个word（40MB/s），命令ready、数据ready及真实完成回执加入停顿；读取与写入共用此限额。模型不是完整SDRAM pin/刷新/PHY模型，物理可达性仍待接入后TD/板测。

| 向量 | 连续帧 | 周期范围（100MHz） | 最慢ms | 最慢/24fps帧周期 | 最慢帧号 |
|---|---|---:|---:|---:|---:|
| budget | 36/36 | 3139977…3156609 | 31.56609 | 0.75759 | 24 |
| stress | 36/36 | 3198793…3217913 | 32.17913 | 0.77230 | 12 |

每帧153600/153600字、307200/307200像素，所有地址恰一次，逐点对Python整数金标零diff，最后真实mem_done后才成功done。两组72帧共11,059,200个输出word全部验证，不能只比公共前缀。72帧由真实完整输入解码，未给核预先喂系数或硬编码DHT。

IDCT实测每块**293拍**，7200块理论串行21.096ms；与熵/颜色通过双系数/双MCU bank重叠。核心对budget0/stress0/stress1/宽系数4帧比较全部DHT/DQT RAM有效点、每块64反量化系数、第一遍64点及最终64样本；这4帧IDCT中间点共1,843,200点全部零diff。压力帧仅60KiB左右，不将本次最慢值宣称为任意合法JPEG的绝对最坏上界；看门狗错误码30与播放deadline需由外部时基检查。

## 4. PSNR：用RTL实际SDRAM写回图像测量

从RTL写回完整内存图导出RGB565，再按现有显示风格bit复制扩展为RGB24，与用户提交ffmpeg参考计算全图RGB MSE；另给更保守的低位补零扩展结果：

| 参考帧 | bit复制扩展PSNR dB | 补零扩展PSNR dB |
|---|---:|---:|
| budget frame0 | 39.37547 | 37.05388 |
| stress frame0 | 39.42124 | 37.00881 |
| stress frame1 | 39.38841 | 37.00699 |

三帧两种口径均≥35dB。以RTL dump计算，不用Python金标图像自身代替硬件输出。

## 5. 错误与恢复

16个错误用例均精确匹配错误码，有限周期终止、无越界写、不发成功frame commit；已接受的burst保持载荷直至物理终态，部分后台字可已写入但不能切前台。每个错误随后在同一实例解码正常帧，所有word零diff，验证表/预测器/输出队列和核取消恢复。错误的`done=1`不能当作成功。

| 用例 | 错误码hex | 报错结束周期 | 成功完成回执word（不含报错突发） | 恢复 |
|---|---:|---:|---:|---|
| truncated | 20 | 3145907 | 153376 | 次帧零diff、无OOB |
| baddht | 0c | 467 | 0 | 次帧零diff、无OOB |
| read_error | 82 | 90 | 0 | 次帧零diff、无OOB |
| write_error | 82 | 6163 | 0 | 次帧零diff、无OOB |
| bad_rlast | 81 | 90 | 0 | 次帧零diff、无OOB |
| zero_quant | 0a | 99 | 0 | 次帧零diff、无OOB |
| bad_rst | 25 | 2326 | 0 | 次帧零diff、无OOB |
| progressive | 04 | 340 | 0 | 次帧零diff、无OOB |
| missing_dht | 12 | 452 | 0 | 次帧零diff、无OOB |
| non420 | 10 | 350 | 0 | 次帧零diff、无OOB |
| bad_run | 23 | 816 | 0 | 次帧零diff、无OOB |
| invalid_code | 21 | 806 | 0 | 次帧零diff、无OOB |
| trailing | 26 | 3072779 | 153416 | 次帧零diff、无OOB |
| segment_extent | 05 | 33 | 0 | 次帧零diff、无OOB |
| duplicate_symbol | 0e | 483 | 0 | 次帧零diff、无OOB |
| quant_precision | 09 | 98 | 0 | 次帧零diff、无OOB |

另6个合成完整帧覆盖RST间隔1/3/40（含7→0回绕）、16bit Huffman码、自定义DQT/表ID1、DC负差分和最大255000宽系数。四种CTRLPHASE及真实RAM同址竞争继续通过，但不将这些软件结果解释为S1-B原板测故障已修复；本轮仍走旧两拍。

## 6. 增量资源与时序估算

| 项 | 本轮证据/估算 | 红线与状态 |
|---|---|---|
| LUT | 分模块目标7400、预留600；Anlogic通用逻辑映射风险估计**7028** | ≤8000；**不是TD实测** |
| BRAM9K | Anlogic结构映射5个`EG_PHY_BRAM`，系数/转置/描述符全打包16bit端口，另有16个小分布式RAM宏计入LUT | ≤6；目标板TD仍需确认映射一致 |
| DSP18×18 | 8路27×16预计各2个，反量化1、颜色4，**预计21** | 总器件29；未用DSP剥离代理结果冒充TD映射 |
| REG | 通用代理2251顺序单元，仅decoder；mailbox/arbiter另计 | 不是TD实测，寄存器/DSP寄存器打包可能不同 |
| 总预算参考 | 冻结10519+目标7400=17919 LUT；39+5=44 BRAM；DSP21 | 器件19600/64/29；不扣失败S1-B的−56 LUT作为预算优惠 |

估计方法可复现：`tools/mjpeg_d2_synth.py`先真实执行proc/opt/memory_dff/check和Anlogic RAM映射，然后**仅在面积代理网表中**将13个逻辑乘法替换成黑盒，再跑LUT映射。原RTL、仿真网表没有黑盒替代。LUT1…4各计1，LUT5计2、LUT6计4、carry每bit计1、16×4分布式RAM每宏计4，得到6234；再预留8×43=344给宽乘积合并加法、450给邮箱/仲裁，总7028。该换算为保守风险估计，仍不是TD工艺计数或保证；不能用此代理网表烧录。

| 时序域/路径 | 周期/设计估算 | 实际slack |
|---|---|---|
| sys50邮箱 | 20ns；held bus与两级toggle同步，非JPEG数据运算 | 待TD；跨域稳定性仿真不能替代CDC约束审阅 |
| mem100 IDCT读→乘积 | 10ns；双16bit读组装，27×16乘积寄存，宽乘预计拆2DSP | 待TD，不能给无工艺库的假ns值 |
| mem100 MAC→舍入 | 10ns；48bit累加与末向量Q16舍入后寄存 | 待TD，宽carry为重点风险路径 |
| mem100 色彩/地址/握手 | 10ns；独立读/乘/输出状态，帧写接口寄存/背压 | 待TD，验证cmd_ready和真实burst延迟 |
| pix显示域 | 新增组合逻辑0；不在pix解码 | 原+0.66ns不能自动视为新布局裕量，整工程仍需复核 |

本地TD实际任一增量LUT>8K、BRAM>6、DSP>29、累计相对估算偏差>30%或真实时序违例即停。现有控制器侧口适配尚待集成，其新增逻辑必须计入预留与硬限，不另藏预算。

## 7. 原有三路回归逐项结果

- 照片BMP：460800/460800字、921600/921600像素零diff。
- 音乐48k：RATECHK9991/10000，CHUNKCHK9次精确匹配。
- 音乐44.1k：RATECHK9180/9187，CHUNKCHK9次精确匹配。
- 卡带：期望动态读取镜像头部604；WC604(25C)，BADC0UNT=0 of604，padding/meta零diff。
- CTRLPHASE四相位/竞争/背压/两DRAIN共32组合通过；单拍513、旧两拍1024。513=512数据拍+1拍排空。
- Python unittest 55项通过；包括原D1/转换器默认profile回归与4项新D2参考测试。CPU cosim已知基线失败不运行、不标通过。

旧三路仿真本身不验证SPI引脚频率，12.5MHz板测定案来自用户与向量README。

## 8. 复现、源与交付边界

Python3+NumPy，Verilator5+C++/make，Yosys+ABC用于结构估算；云端工具装在/workspace/.yingxu-env，均未改环境发布配置。也可`--sim iverilog`跑同一TB（较慢）。以下命令在仓库根目录，完整生成输入/参考并检查退出码，`--quick`只测首帧，不能算36帧验收：

```text
python3 tools/mjpeg_d2_verify.py --jobs 4
python3 tools/mjpeg_d2_synth.py
python3 -m unittest discover -s tests
python3 tb/run_sd_drain.py
```

源码/命令/每帧周期/所有错误码/PSNR/资源代理详见 [D2_MJPEG_MEASUREMENTS.json](D2_MJPEG_MEASUREMENTS.json)。生成gold与dump放out，完整执行stdout作为本文附件提交进GitHub，不以/tmp或忽略目录代替交付。Verilator目前有显式上下文位宽扩展/截断提示（system TB构建54条，含TB自身索引）；Icarus编译成功，Yosys check未发现结构错误。未将它描述为lint零警告；TD位宽/乘法推断仍须审阅。

接口交付边界：可以以新decoder为根做模块综合，不能因原顶层没有实例化新模块而报0增量；已有四口FIFO口尚不满足随机burst+真实commit接口。需在自研SDRAM控制器burst服务边界接入master，并接上显示请求优先级、YXV音频采样调度与前后台消隐交换后，才可在完整工程验板。此处不声称硬件24fps播放器已可用。main、冻结固件、厂商IP均未修改。

## 9. 全部D2 RTL运行原始stdout（exit=0）

### stress_1_core

```text
TABLECHK: PASS all loaded DHT/DQT words zero-diff; IDCT_TEMPCHK 460800/460800; IDCT max_cycles=293 blocks=7200/7200
MJPEG_CORE: PASS bytes=60848/60848 blocks=7200/7200 samples=460800/460800 pixels=307200/307200 cycles=2854617 ratio_frame_x10000=6851
- tb/tb_mjpeg_core.v:80: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 29ms; walltime 2.151 s; speed 13.297 ms/s
- Verilator: cpu 2.147 s on 1 threads; alloced 37 MB
```

### stress_0_core

```text
TABLECHK: PASS all loaded DHT/DQT words zero-diff; IDCT_TEMPCHK 460800/460800; IDCT max_cycles=293 blocks=7200/7200
MJPEG_CORE: PASS bytes=61000/61000 blocks=7200/7200 samples=460800/460800 pixels=307200/307200 cycles=2862609 ratio_frame_x10000=6870
- tb/tb_mjpeg_core.v:80: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 29ms; walltime 5.108 s; speed 5.823 ms/s
- Verilator: cpu 4.916 s on 1 threads; alloced 37 MB
```

### budget_0_core

```text
TABLECHK: PASS all loaded DHT/DQT words zero-diff; IDCT_TEMPCHK 460800/460800; IDCT max_cycles=293 blocks=7200/7200
MJPEG_CORE: PASS bytes=46373/46373 blocks=7200/7200 samples=460800/460800 pixels=307200/307200 cycles=2456689 ratio_frame_x10000=5896
- tb/tb_mjpeg_core.v:80: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 25ms; walltime 5.124 s; speed 5.010 ms/s
- Verilator: cpu 4.903 s on 1 threads; alloced 37 MB
```

### wide_core

```text
TABLECHK: PASS all loaded DHT/DQT words zero-diff; IDCT_TEMPCHK 460800/460800; IDCT max_cycles=293 blocks=7200/7200
MJPEG_CORE: PASS bytes=4665/4665 blocks=7200/7200 samples=460800/460800 pixels=307200/307200 cycles=2111277 ratio_frame_x10000=5067
- tb/tb_mjpeg_core.v:80: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 21ms; walltime 5.537 s; speed 3.997 ms/s
- Verilator: cpu 5.283 s on 1 threads; alloced 37 MB
```

### stress1

```text
SDRAM_FRAMECHK: PASS frame=1 bytes=60848 words=153600/153600 pixels=307200/307200 zero-diff cycles=3206579 ratio_frame_x10000=7695 pressure=1
SDRAM_SUITE: PASS frames=1 pressure=1 fault=0 commands=21102 read_words=15212 write_words=153600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 32ms; walltime 2.397 s; speed 13.438 ms/s
- Verilator: cpu 2.386 s on 1 threads; alloced 37 MB
```

### truncated

```text
ERRORCHK: PASS frame=0 fault=1 code=20 cycles=3145907 committed_partial=153376 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=46104 words=153600/153600 pixels=307200/307200 zero-diff cycles=3144753 ratio_frame_x10000=7547 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=1 commands=41262 read_words=23116 write_words=306976
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 63ms; walltime 4.624 s; speed 13.786 ms/s
- Verilator: cpu 4.563 s on 1 threads; alloced 37 MB
```

### baddht

```text
ERRORCHK: PASS frame=0 fault=2 code=0c cycles=467 committed_partial=0 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=46104 words=153600/153600 pixels=307200/307200 zero-diff cycles=3144833 ratio_frame_x10000=7547 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=2 commands=20645 read_words=11558 write_words=153600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 31ms; walltime 2.382 s; speed 13.216 ms/s
- Verilator: cpu 2.380 s on 1 threads; alloced 37 MB
```

### read_error

```text
ERRORCHK: PASS frame=0 fault=4 code=82 cycles=90 committed_partial=0 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=46104 words=153600/153600 pixels=307200/307200 zero-diff cycles=3144650 ratio_frame_x10000=7547 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=4 commands=20642 read_words=11534 write_words=153600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 31ms; walltime 8.420 s; speed 3.779 ms/s
- Verilator: cpu 8.321 s on 1 threads; alloced 37 MB
```

### write_error

```text
ERRORCHK: PASS frame=0 fault=5 code=82 cycles=6163 committed_partial=0 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=46104 words=153600/153600 pixels=307200/307200 zero-diff cycles=3144737 ratio_frame_x10000=7547 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=5 commands=20657 read_words=11646 write_words=153608
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 32ms; walltime 6.266 s; speed 5.044 ms/s
- Verilator: cpu 6.247 s on 1 threads; alloced 37 MB
```

### bad_rlast

```text
ERRORCHK: PASS frame=0 fault=6 code=81 cycles=90 committed_partial=0 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=46104 words=153600/153600 pixels=307200/307200 zero-diff cycles=3144650 ratio_frame_x10000=7547 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=6 commands=20642 read_words=11534 write_words=153600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 31ms; walltime 5.066 s; speed 6.265 ms/s
- Verilator: cpu 5.020 s on 1 threads; alloced 37 MB
```

### synthetic

```text
SDRAM_FRAMECHK: PASS frame=0 bytes=10963 words=153600/153600 pixels=307200/307200 zero-diff cycles=3079107 ratio_frame_x10000=7389 pressure=1
SDRAM_FRAMECHK: PASS frame=1 bytes=6563 words=153600/153600 pixels=307200/307200 zero-diff cycles=3074673 ratio_frame_x10000=7379 pressure=1
SDRAM_FRAMECHK: PASS frame=2 bytes=4813 words=153600/153600 pixels=307200/307200 zero-diff cycles=3078873 ratio_frame_x10000=7389 pressure=1
SDRAM_FRAMECHK: PASS frame=3 bytes=30762 words=153600/153600 pixels=307200/307200 zero-diff cycles=3097833 ratio_frame_x10000=7434 pressure=1
SDRAM_FRAMECHK: PASS frame=4 bytes=4662 words=153600/153600 pixels=307200/307200 zero-diff cycles=3078593 ratio_frame_x10000=7388 pressure=1
SDRAM_FRAMECHK: PASS frame=5 bytes=4665 words=153600/153600 pixels=307200/307200 zero-diff cycles=3078673 ratio_frame_x10000=7388 pressure=1
SDRAM_SUITE: PASS frames=6 pressure=1 fault=0 commands=117154 read_words=15610 write_words=921600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 185ms; walltime 32.780 s; speed 5.700 ms/s
- Verilator: cpu 32.435 s on 1 threads; alloced 37 MB
```

### zero_quant

```text
ERRORCHK: PASS frame=0 fault=3 code=0a cycles=99 committed_partial=0 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=2859 words=153600/153600 pixels=307200/307200 zero-diff cycles=3076433 ratio_frame_x10000=7383 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=3 commands=19291 read_words=723 write_words=153600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 31ms; walltime 2.267 s; speed 13.617 ms/s
- Verilator: cpu 2.259 s on 1 threads; alloced 37 MB
```

### bad_rst

```text
ERRORCHK: PASS frame=0 fault=3 code=25 cycles=2326 committed_partial=0 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=2859 words=153600/153600 pixels=307200/307200 zero-diff cycles=3076446 ratio_frame_x10000=7383 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=3 commands=19296 read_words=763 write_words=153600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 31ms; walltime 6.200 s; speed 5.020 ms/s
- Verilator: cpu 6.133 s on 1 threads; alloced 37 MB
```

### progressive

```text
ERRORCHK: PASS frame=0 fault=3 code=04 cycles=340 committed_partial=0 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=2859 words=153600/153600 pixels=307200/307200 zero-diff cycles=3076432 ratio_frame_x10000=7383 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=3 commands=19293 read_words=739 write_words=153600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 31ms; walltime 5.070 s; speed 6.264 ms/s
- Verilator: cpu 4.912 s on 1 threads; alloced 37 MB
```

### missing_dht

```text
ERRORCHK: PASS frame=0 fault=3 code=12 cycles=452 committed_partial=0 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=2859 words=153600/153600 pixels=307200/307200 zero-diff cycles=3076440 ratio_frame_x10000=7383 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=3 commands=19294 read_words=747 write_words=153600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 31ms; walltime 2.098 s; speed 14.889 ms/s
- Verilator: cpu 2.067 s on 1 threads; alloced 37 MB
```

### non420

```text
ERRORCHK: PASS frame=0 fault=3 code=10 cycles=350 committed_partial=0 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=2859 words=153600/153600 pixels=307200/307200 zero-diff cycles=3076462 ratio_frame_x10000=7383 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=3 commands=19293 read_words=739 write_words=153600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 31ms; walltime 7.511 s; speed 4.213 ms/s
- Verilator: cpu 7.303 s on 1 threads; alloced 37 MB
```

### bad_run

```text
ERRORCHK: PASS frame=0 fault=3 code=23 cycles=816 committed_partial=0 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=2859 words=153600/153600 pixels=307200/307200 zero-diff cycles=3076436 ratio_frame_x10000=7383 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=3 commands=19296 read_words=756 write_words=153600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 31ms; walltime 3.860 s; speed 8.026 ms/s
- Verilator: cpu 3.834 s on 1 threads; alloced 37 MB
```

### invalid_code

```text
ERRORCHK: PASS frame=0 fault=3 code=21 cycles=806 committed_partial=0 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=2859 words=153600/153600 pixels=307200/307200 zero-diff cycles=3076446 ratio_frame_x10000=7383 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=3 commands=19296 read_words=756 write_words=153600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 31ms; walltime 6.138 s; speed 5.046 ms/s
- Verilator: cpu 6.099 s on 1 threads; alloced 37 MB
```

### trailing

```text
ERRORCHK: PASS frame=0 fault=3 code=26 cycles=3072779 committed_partial=153416 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=2859 words=153600/153600 pixels=307200/307200 zero-diff cycles=3076433 ratio_frame_x10000=7383 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=3 commands=38557 read_words=1430 write_words=307016
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 61ms; walltime 6.055 s; speed 10.187 ms/s
- Verilator: cpu 6.037 s on 1 threads; alloced 37 MB
```

### segment_extent

```text
ERRORCHK: PASS frame=0 fault=3 code=05 cycles=33 committed_partial=0 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=2859 words=153600/153600 pixels=307200/307200 zero-diff cycles=3076459 ratio_frame_x10000=7383 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=3 commands=19291 read_words=717 write_words=153600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 31ms; walltime 5.729 s; speed 5.422 ms/s
- Verilator: cpu 5.674 s on 1 threads; alloced 37 MB
```

### duplicate_symbol

```text
ERRORCHK: PASS frame=0 fault=3 code=0e cycles=483 committed_partial=0 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=2859 words=153600/153600 pixels=307200/307200 zero-diff cycles=3076449 ratio_frame_x10000=7383 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=3 commands=19294 read_words=747 write_words=153600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 31ms; walltime 6.863 s; speed 4.546 ms/s
- Verilator: cpu 6.769 s on 1 threads; alloced 37 MB
```

### arbiter

```text
GRANT_TRACE: owner=0 failure=0
GRANT_TRACE: owner=1 failure=0
GRANT_TRACE: owner=2 failure=1
GRANT_TRACE: owner=2 failure=0
GRANT_TRACE: owner=0 failure=0
ARBCHK: PASS grants=5 priority=display>decode>other owner-until-done stalled-command-stable error-routed
- tb/tb_mjpeg_bus.v:42: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 405ns; walltime 0.001 s; speed 603.798 us/s
- Verilator: cpu 0.001 s on 1 threads; alloced 33 MB
```

### mailbox

```text
MAILBOX_TRACE: payload=012345678000000 status=155
MAILBOX_TRACE: payload=012345678000001 status=154
MAILBOX_TRACE: payload=012345678000002 status=157
MAILBOX_TRACE: payload=012345678000003 status=156
MAILBOX_TRACE: payload=012345678000004 status=151
MAILBOX_TRACE: payload=012345678000005 status=150
MAILBOX_TRACE: payload=012345678000006 status=153
MAILBOX_TRACE: payload=012345678000007 status=152
MAILBOX_TRACE: payload=012345678000014 status=141
MAILBOX_TRACE: payload=012345678000015 status=140
MAILBOX_TRACE: payload=012345678000016 status=143
MAILBOX_TRACE: payload=012345678000017 status=142
MAILBOX_TRACE: payload=012345678000018 status=14d
MAILBOX_TRACE: payload=012345678000019 status=14c
MAILBOX_TRACE: payload=01234567800001a status=14f
MAILBOX_TRACE: payload=01234567800001b status=14e
MAILBOXCHK: PASS requests/responses=8/8 x2 unrelated-clocks held-bus backpressure reset-replay
- tb/tb_mjpeg_bus.v:85: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 4us; walltime 0.002 s; speed 2.323 ms/s
- Verilator: cpu 0.002 s on 1 threads; alloced 33 MB
```

### quant_precision

```text
ERRORCHK: PASS frame=0 fault=3 code=09 cycles=98 committed_partial=0 no-commit no-OOB
SDRAM_FRAMECHK: PASS frame=1 bytes=2859 words=153600/153600 pixels=307200/307200 zero-diff cycles=3076434 ratio_frame_x10000=7383 pressure=1
SDRAM_SUITE: PASS frames=2 pressure=1 fault=3 commands=19291 read_words=723 write_words=153600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 31ms; walltime 5.712 s; speed 5.398 ms/s
- Verilator: cpu 5.699 s on 1 threads; alloced 37 MB
```

### budget36

```text
SDRAM_FRAMECHK: PASS frame=0 bytes=46373 words=153600/153600 pixels=307200/307200 zero-diff cycles=3150387 ratio_frame_x10000=7560 pressure=1
SDRAM_FRAMECHK: PASS frame=1 bytes=46104 words=153600/153600 pixels=307200/307200 zero-diff cycles=3144753 ratio_frame_x10000=7547 pressure=1
SDRAM_FRAMECHK: PASS frame=2 bytes=46027 words=153600/153600 pixels=307200/307200 zero-diff cycles=3142593 ratio_frame_x10000=7542 pressure=1
SDRAM_FRAMECHK: PASS frame=3 bytes=46036 words=153600/153600 pixels=307200/307200 zero-diff cycles=3140593 ratio_frame_x10000=7537 pressure=1
SDRAM_FRAMECHK: PASS frame=4 bytes=46084 words=153600/153600 pixels=307200/307200 zero-diff cycles=3140873 ratio_frame_x10000=7538 pressure=1
SDRAM_FRAMECHK: PASS frame=5 bytes=46193 words=153600/153600 pixels=307200/307200 zero-diff cycles=3141993 ratio_frame_x10000=7540 pressure=1
SDRAM_FRAMECHK: PASS frame=6 bytes=46218 words=153600/153600 pixels=307200/307200 zero-diff cycles=3145713 ratio_frame_x10000=7549 pressure=1
SDRAM_FRAMECHK: PASS frame=7 bytes=46277 words=153600/153600 pixels=307200/307200 zero-diff cycles=3141073 ratio_frame_x10000=7538 pressure=1
SDRAM_FRAMECHK: PASS frame=8 bytes=46380 words=153600/153600 pixels=307200/307200 zero-diff cycles=3142953 ratio_frame_x10000=7543 pressure=1
SDRAM_FRAMECHK: PASS frame=9 bytes=46164 words=153600/153600 pixels=307200/307200 zero-diff cycles=3139977 ratio_frame_x10000=7535 pressure=1
SDRAM_FRAMECHK: PASS frame=10 bytes=46391 words=153600/153600 pixels=307200/307200 zero-diff cycles=3143689 ratio_frame_x10000=7544 pressure=1
SDRAM_FRAMECHK: PASS frame=11 bytes=46391 words=153600/153600 pixels=307200/307200 zero-diff cycles=3145433 ratio_frame_x10000=7549 pressure=1
SDRAM_FRAMECHK: PASS frame=12 bytes=46912 words=153600/153600 pixels=307200/307200 zero-diff cycles=3151793 ratio_frame_x10000=7564 pressure=1
SDRAM_FRAMECHK: PASS frame=13 bytes=46336 words=153600/153600 pixels=307200/307200 zero-diff cycles=3145473 ratio_frame_x10000=7549 pressure=1
SDRAM_FRAMECHK: PASS frame=14 bytes=45990 words=153600/153600 pixels=307200/307200 zero-diff cycles=3146033 ratio_frame_x10000=7550 pressure=1
SDRAM_FRAMECHK: PASS frame=15 bytes=46062 words=153600/153600 pixels=307200/307200 zero-diff cycles=3145633 ratio_frame_x10000=7549 pressure=1
SDRAM_FRAMECHK: PASS frame=16 bytes=46065 words=153600/153600 pixels=307200/307200 zero-diff cycles=3144873 ratio_frame_x10000=7547 pressure=1
SDRAM_FRAMECHK: PASS frame=17 bytes=46320 words=153600/153600 pixels=307200/307200 zero-diff cycles=3149993 ratio_frame_x10000=7559 pressure=1
SDRAM_FRAMECHK: PASS frame=18 bytes=46143 words=153600/153600 pixels=307200/307200 zero-diff cycles=3148273 ratio_frame_x10000=7555 pressure=1
SDRAM_FRAMECHK: PASS frame=19 bytes=46328 words=153600/153600 pixels=307200/307200 zero-diff cycles=3150593 ratio_frame_x10000=7561 pressure=1
SDRAM_FRAMECHK: PASS frame=20 bytes=46190 words=153600/153600 pixels=307200/307200 zero-diff cycles=3150257 ratio_frame_x10000=7560 pressure=1
SDRAM_FRAMECHK: PASS frame=21 bytes=46327 words=153600/153600 pixels=307200/307200 zero-diff cycles=3145081 ratio_frame_x10000=7548 pressure=1
SDRAM_FRAMECHK: PASS frame=22 bytes=46031 words=153600/153600 pixels=307200/307200 zero-diff cycles=3147113 ratio_frame_x10000=7553 pressure=1
SDRAM_FRAMECHK: PASS frame=23 bytes=46561 words=153600/153600 pixels=307200/307200 zero-diff cycles=3149041 ratio_frame_x10000=7557 pressure=1
SDRAM_FRAMECHK: PASS frame=24 bytes=46871 words=153600/153600 pixels=307200/307200 zero-diff cycles=3156609 ratio_frame_x10000=7575 pressure=1
SDRAM_FRAMECHK: PASS frame=25 bytes=46670 words=153600/153600 pixels=307200/307200 zero-diff cycles=3146577 ratio_frame_x10000=7551 pressure=1
SDRAM_FRAMECHK: PASS frame=26 bytes=46378 words=153600/153600 pixels=307200/307200 zero-diff cycles=3145137 ratio_frame_x10000=7548 pressure=1
SDRAM_FRAMECHK: PASS frame=27 bytes=46377 words=153600/153600 pixels=307200/307200 zero-diff cycles=3144929 ratio_frame_x10000=7547 pressure=1
SDRAM_FRAMECHK: PASS frame=28 bytes=46523 words=153600/153600 pixels=307200/307200 zero-diff cycles=3149553 ratio_frame_x10000=7558 pressure=1
SDRAM_FRAMECHK: PASS frame=29 bytes=46810 words=153600/153600 pixels=307200/307200 zero-diff cycles=3149073 ratio_frame_x10000=7557 pressure=1
SDRAM_FRAMECHK: PASS frame=30 bytes=46490 words=153600/153600 pixels=307200/307200 zero-diff cycles=3145633 ratio_frame_x10000=7549 pressure=1
SDRAM_FRAMECHK: PASS frame=31 bytes=46403 words=153600/153600 pixels=307200/307200 zero-diff cycles=3144433 ratio_frame_x10000=7546 pressure=1
SDRAM_FRAMECHK: PASS frame=32 bytes=46654 words=153600/153600 pixels=307200/307200 zero-diff cycles=3149233 ratio_frame_x10000=7558 pressure=1
SDRAM_FRAMECHK: PASS frame=33 bytes=46644 words=153600/153600 pixels=307200/307200 zero-diff cycles=3147217 ratio_frame_x10000=7553 pressure=1
SDRAM_FRAMECHK: PASS frame=34 bytes=46525 words=153600/153600 pixels=307200/307200 zero-diff cycles=3149009 ratio_frame_x10000=7557 pressure=1
SDRAM_FRAMECHK: PASS frame=35 bytes=46761 words=153600/153600 pixels=307200/307200 zero-diff cycles=3150313 ratio_frame_x10000=7560 pressure=1
SDRAM_SUITE: PASS frames=36 pressure=1 fault=0 commands=743373 read_words=417265 write_words=5529600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 1s; walltime 135.044 s; speed 8.448 ms/s
- Verilator: cpu 134.082 s on 1 threads; alloced 37 MB
```

### stress36

```text
SDRAM_FRAMECHK: PASS frame=0 bytes=61000 words=153600/153600 pixels=307200/307200 zero-diff cycles=3215707 ratio_frame_x10000=7717 pressure=1
SDRAM_FRAMECHK: PASS frame=1 bytes=60848 words=153600/153600 pixels=307200/307200 zero-diff cycles=3206665 ratio_frame_x10000=7695 pressure=1
SDRAM_FRAMECHK: PASS frame=2 bytes=60713 words=153600/153600 pixels=307200/307200 zero-diff cycles=3206161 ratio_frame_x10000=7694 pressure=1
SDRAM_FRAMECHK: PASS frame=3 bytes=60677 words=153600/153600 pixels=307200/307200 zero-diff cycles=3198833 ratio_frame_x10000=7677 pressure=1
SDRAM_FRAMECHK: PASS frame=4 bytes=60772 words=153600/153600 pixels=307200/307200 zero-diff cycles=3198793 ratio_frame_x10000=7677 pressure=1
SDRAM_FRAMECHK: PASS frame=5 bytes=60858 words=153600/153600 pixels=307200/307200 zero-diff cycles=3203433 ratio_frame_x10000=7688 pressure=1
SDRAM_FRAMECHK: PASS frame=6 bytes=60930 words=153600/153600 pixels=307200/307200 zero-diff cycles=3204993 ratio_frame_x10000=7691 pressure=1
SDRAM_FRAMECHK: PASS frame=7 bytes=60997 words=153600/153600 pixels=307200/307200 zero-diff cycles=3206833 ratio_frame_x10000=7696 pressure=1
SDRAM_FRAMECHK: PASS frame=8 bytes=61043 words=153600/153600 pixels=307200/307200 zero-diff cycles=3203713 ratio_frame_x10000=7688 pressure=1
SDRAM_FRAMECHK: PASS frame=9 bytes=60727 words=153600/153600 pixels=307200/307200 zero-diff cycles=3199217 ratio_frame_x10000=7678 pressure=1
SDRAM_FRAMECHK: PASS frame=10 bytes=61024 words=153600/153600 pixels=307200/307200 zero-diff cycles=3202689 ratio_frame_x10000=7686 pressure=1
SDRAM_FRAMECHK: PASS frame=11 bytes=60978 words=153600/153600 pixels=307200/307200 zero-diff cycles=3207033 ratio_frame_x10000=7696 pressure=1
SDRAM_FRAMECHK: PASS frame=12 bytes=61481 words=153600/153600 pixels=307200/307200 zero-diff cycles=3217913 ratio_frame_x10000=7722 pressure=1
SDRAM_FRAMECHK: PASS frame=13 bytes=61051 words=153600/153600 pixels=307200/307200 zero-diff cycles=3205353 ratio_frame_x10000=7692 pressure=1
SDRAM_FRAMECHK: PASS frame=14 bytes=60661 words=153600/153600 pixels=307200/307200 zero-diff cycles=3204905 ratio_frame_x10000=7691 pressure=1
SDRAM_FRAMECHK: PASS frame=15 bytes=60789 words=153600/153600 pixels=307200/307200 zero-diff cycles=3207601 ratio_frame_x10000=7698 pressure=1
SDRAM_FRAMECHK: PASS frame=16 bytes=60539 words=153600/153600 pixels=307200/307200 zero-diff cycles=3205113 ratio_frame_x10000=7692 pressure=1
SDRAM_FRAMECHK: PASS frame=17 bytes=60948 words=153600/153600 pixels=307200/307200 zero-diff cycles=3210265 ratio_frame_x10000=7704 pressure=1
SDRAM_FRAMECHK: PASS frame=18 bytes=60859 words=153600/153600 pixels=307200/307200 zero-diff cycles=3209721 ratio_frame_x10000=7703 pressure=1
SDRAM_FRAMECHK: PASS frame=19 bytes=61002 words=153600/153600 pixels=307200/307200 zero-diff cycles=3209113 ratio_frame_x10000=7701 pressure=1
SDRAM_FRAMECHK: PASS frame=20 bytes=60740 words=153600/153600 pixels=307200/307200 zero-diff cycles=3209513 ratio_frame_x10000=7702 pressure=1
SDRAM_FRAMECHK: PASS frame=21 bytes=60882 words=153600/153600 pixels=307200/307200 zero-diff cycles=3207033 ratio_frame_x10000=7696 pressure=1
SDRAM_FRAMECHK: PASS frame=22 bytes=60727 words=153600/153600 pixels=307200/307200 zero-diff cycles=3207457 ratio_frame_x10000=7697 pressure=1
SDRAM_FRAMECHK: PASS frame=23 bytes=61034 words=153600/153600 pixels=307200/307200 zero-diff cycles=3211001 ratio_frame_x10000=7706 pressure=1
SDRAM_FRAMECHK: PASS frame=24 bytes=61475 words=153600/153600 pixels=307200/307200 zero-diff cycles=3217177 ratio_frame_x10000=7721 pressure=1
SDRAM_FRAMECHK: PASS frame=25 bytes=61317 words=153600/153600 pixels=307200/307200 zero-diff cycles=3210209 ratio_frame_x10000=7704 pressure=1
SDRAM_FRAMECHK: PASS frame=26 bytes=61014 words=153600/153600 pixels=307200/307200 zero-diff cycles=3204025 ratio_frame_x10000=7689 pressure=1
SDRAM_FRAMECHK: PASS frame=27 bytes=61010 words=153600/153600 pixels=307200/307200 zero-diff cycles=3206081 ratio_frame_x10000=7694 pressure=1
SDRAM_FRAMECHK: PASS frame=28 bytes=61160 words=153600/153600 pixels=307200/307200 zero-diff cycles=3210073 ratio_frame_x10000=7704 pressure=1
SDRAM_FRAMECHK: PASS frame=29 bytes=61260 words=153600/153600 pixels=307200/307200 zero-diff cycles=3208153 ratio_frame_x10000=7699 pressure=1
SDRAM_FRAMECHK: PASS frame=30 bytes=61228 words=153600/153600 pixels=307200/307200 zero-diff cycles=3205761 ratio_frame_x10000=7693 pressure=1
SDRAM_FRAMECHK: PASS frame=31 bytes=61098 words=153600/153600 pixels=307200/307200 zero-diff cycles=3204057 ratio_frame_x10000=7689 pressure=1
SDRAM_FRAMECHK: PASS frame=32 bytes=61274 words=153600/153600 pixels=307200/307200 zero-diff cycles=3206289 ratio_frame_x10000=7695 pressure=1
SDRAM_FRAMECHK: PASS frame=33 bytes=61422 words=153600/153600 pixels=307200/307200 zero-diff cycles=3210713 ratio_frame_x10000=7705 pressure=1
SDRAM_FRAMECHK: PASS frame=34 bytes=61283 words=153600/153600 pixels=307200/307200 zero-diff cycles=3211785 ratio_frame_x10000=7708 pressure=1
SDRAM_FRAMECHK: PASS frame=35 bytes=61368 words=153600/153600 pixels=307200/307200 zero-diff cycles=3210313 ratio_frame_x10000=7704 pressure=1
SDRAM_SUITE: PASS frames=36 pressure=1 fault=0 commands=759850 read_words=549060 write_words=5529600
- tb/tb_mjpeg_sdram.v:127: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.032 2025-01-01
- Verilator: $finish at 1s; walltime 134.545 s; speed 8.630 ms/s
- Verilator: cpu 133.787 s on 1 threads; alloced 37 MB
```

## 10. 既有三路及相位回归原始stdout（exit=0）

### 既有回归 drain

```text
DRAINCHK: PASS sectors=1 stall=0 phase=0 collision=0 compare=512 fast_last_sector=513 old_last_sector=1024
DRAINCHK: PASS sectors=1 stall=0 phase=0 collision=0 compare=512 fast_last_sector=513 old_last_sector=1024
CTRLPHASE: PASS phase=0 collision=0 stall=0 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=3 stall=1 phase=0 collision=0 compare=1536 fast_last_sector=656 old_last_sector=1291
DRAINCHK: PASS sectors=1 stall=1 phase=0 collision=0 compare=512 fast_last_sector=701 old_last_sector=1275
CTRLPHASE: PASS phase=0 collision=0 stall=1 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAIN_SUITE: PASS zero request, A/B, random+tail stalls, reset/replay
tb/tb_sd_drain.v:254: $finish called at 153980000 (1ps)
```

### 既有回归 ctrlphase

```text
DRAINCHK: PASS sectors=3 stall=0 phase=0 collision=0 compare=1536 fast_last_sector=513 old_last_sector=1024
DRAINCHK: PASS sectors=3 stall=0 phase=0 collision=1 compare=1536 fast_last_sector=513 old_last_sector=1024
DRAINCHK: PASS sectors=3 stall=0 phase=1 collision=0 compare=1536 fast_last_sector=513 old_last_sector=1024
DRAINCHK: PASS sectors=3 stall=0 phase=1 collision=1 compare=1536 fast_last_sector=513 old_last_sector=1024
DRAINCHK: PASS sectors=3 stall=0 phase=2 collision=0 compare=1536 fast_last_sector=513 old_last_sector=1024
DRAINCHK: PASS sectors=3 stall=0 phase=2 collision=1 compare=1536 fast_last_sector=513 old_last_sector=1024
DRAINCHK: PASS sectors=3 stall=0 phase=4 collision=0 compare=1536 fast_last_sector=513 old_last_sector=1024
DRAINCHK: PASS sectors=3 stall=0 phase=4 collision=1 compare=1536 fast_last_sector=513 old_last_sector=1024
DRAINCHK: PASS sectors=3 stall=1 phase=0 collision=0 compare=1536 fast_last_sector=656 old_last_sector=1291
DRAINCHK: PASS sectors=3 stall=1 phase=0 collision=1 compare=1536 fast_last_sector=656 old_last_sector=1292
DRAINCHK: PASS sectors=3 stall=1 phase=1 collision=0 compare=1536 fast_last_sector=656 old_last_sector=1292
DRAINCHK: PASS sectors=3 stall=1 phase=1 collision=1 compare=1536 fast_last_sector=657 old_last_sector=1291
DRAINCHK: PASS sectors=3 stall=1 phase=2 collision=0 compare=1536 fast_last_sector=657 old_last_sector=1291
DRAINCHK: PASS sectors=3 stall=1 phase=2 collision=1 compare=1536 fast_last_sector=655 old_last_sector=1290
DRAINCHK: PASS sectors=3 stall=1 phase=4 collision=0 compare=1536 fast_last_sector=656 old_last_sector=1291
DRAINCHK: PASS sectors=3 stall=1 phase=4 collision=1 compare=1536 fast_last_sector=657 old_last_sector=1290
DRAINCHK: PASS sectors=1 stall=0 phase=0 collision=0 compare=512 fast_last_sector=513 old_last_sector=1024
CTRLPHASE: PASS phase=0 collision=0 stall=0 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=0 phase=0 collision=1 compare=512 fast_last_sector=513 old_last_sector=1024
CTRLPHASE: PASS phase=0 collision=1 stall=0 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=0 phase=1 collision=0 compare=512 fast_last_sector=513 old_last_sector=1024
CTRLPHASE: PASS phase=1 collision=0 stall=0 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=0 phase=1 collision=1 compare=512 fast_last_sector=513 old_last_sector=1024
CTRLPHASE: PASS phase=1 collision=1 stall=0 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=0 phase=2 collision=0 compare=512 fast_last_sector=513 old_last_sector=1024
CTRLPHASE: PASS phase=2 collision=0 stall=0 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=0 phase=2 collision=1 compare=512 fast_last_sector=513 old_last_sector=1024
CTRLPHASE: PASS phase=2 collision=1 stall=0 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=0 phase=4 collision=0 compare=512 fast_last_sector=513 old_last_sector=1024
CTRLPHASE: PASS phase=4 collision=0 stall=0 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=0 phase=4 collision=1 compare=512 fast_last_sector=513 old_last_sector=1024
CTRLPHASE: PASS phase=4 collision=1 stall=0 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=1 phase=0 collision=0 compare=512 fast_last_sector=701 old_last_sector=1275
CTRLPHASE: PASS phase=0 collision=0 stall=1 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=1 phase=0 collision=1 compare=512 fast_last_sector=700 old_last_sector=1276
CTRLPHASE: PASS phase=0 collision=1 stall=1 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=1 phase=1 collision=0 compare=512 fast_last_sector=700 old_last_sector=1276
CTRLPHASE: PASS phase=1 collision=0 stall=1 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=1 phase=1 collision=1 compare=512 fast_last_sector=699 old_last_sector=1275
CTRLPHASE: PASS phase=1 collision=1 stall=1 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=1 phase=2 collision=0 compare=512 fast_last_sector=699 old_last_sector=1275
CTRLPHASE: PASS phase=2 collision=0 stall=1 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=1 phase=2 collision=1 compare=512 fast_last_sector=699 old_last_sector=1274
CTRLPHASE: PASS phase=2 collision=1 stall=1 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=1 phase=4 collision=0 compare=512 fast_last_sector=699 old_last_sector=1275
CTRLPHASE: PASS phase=4 collision=0 stall=1 modes=0,1 full-stream zero-diff replay_checks=1,1
DRAINCHK: PASS sectors=1 stall=1 phase=4 collision=1 compare=512 fast_last_sector=699 old_last_sector=1274
CTRLPHASE: PASS phase=4 collision=1 stall=1 modes=0,1 full-stream zero-diff replay_checks=1,1
CTRLPHASE_SUITE: PASS phases=0,1,2,4 collision=0,1 stall=0,1 modes=0,1 cases=32; old-read collision asserted; all bytes compared
tb/tb_sd_drain.v:272: $finish called at 154440000 (1ps)
```

### 既有回归 p0_bmp

```text
BMPCHK: PASS 1280x720 words=460800/460800 pixels=921600/921600 zero-diff
tb/tb_sd_drain.v:336: $finish called at 166243100000 (1ps)
```

### 既有回归 p0_wav48

```text
CHUNKCHK: OK base_off=0 fed=0
CHUNKCHK: OK base_off=16 fed=16
CHUNKCHK: OK base_off=32 fed=32
CHUNKCHK: OK base_off=48 fed=48
CHUNKCHK: OK base_off=64 fed=64
CHUNKCHK: OK base_off=80 fed=80
CHUNKCHK: OK base_off=96 fed=96
CHUNKCHK: OK base_off=112 fed=112
CHUNKCHK: OK base_off=128 fed=128
WAVCHK: PASS rate=48000 pops=16001 nonzero=15997 crossings=195
RATECHK: PASS ratio_x10000=9991 expected=10000; CHUNKCHK count=9 exact-match
tb/tb_sd_drain.v:455: $finish called at 13975793238 (1ps)
```

### 既有回归 p0_wav44

```text
CHUNKCHK: OK base_off=0 fed=0
CHUNKCHK: OK base_off=16 fed=16
CHUNKCHK: OK base_off=32 fed=32
CHUNKCHK: OK base_off=48 fed=48
CHUNKCHK: OK base_off=64 fed=64
CHUNKCHK: OK base_off=80 fed=80
CHUNKCHK: OK base_off=96 fed=96
CHUNKCHK: OK base_off=112 fed=112
CHUNKCHK: OK base_off=128 fed=128
WAVCHK: PASS rate=44100 pops=16000 nonzero=15975 crossings=196
RATECHK: PASS ratio_x10000=9180 expected=9187; CHUNKCHK count=9 exact-match
tb/tb_sd_drain.v:455: $finish called at 15210669398 (1ps)
```

### 既有回归 p0_cart

```text
CART_HEADER expected_words=604 expected_WC_hex=0000025c file_bytes=1844 sectors=4
CART_DIAG wc=604 words_r=604 requested=1 file_bytes=1844 loaded=1 state=4
CART_WORDCHK: BADC0UNT=0 of 604; WC=604 expected=604
CARTCHK: PASS BADC0UNT=0 of 604; cart_wcnt(WC)=604 (hex=25c); padding/meta zero-diff
tb/tb_sd_drain.v:398: $finish called at 20123231548 (1ps)
```

### Python测试原始输出

```text
......................................................q=4 rejected: CORE_CYCLES: frame 0: 1954576; trying higher compression
.
----------------------------------------------------------------------
Ran 55 tests in 13.626s

OK
```
