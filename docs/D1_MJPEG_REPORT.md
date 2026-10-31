# D1 MJPEG 参考模型与转换器验证报告

日期：2026-10-31。分支：`feat/mjpeg`。被测代码提交：`9a220c009de5b135fdd5112e4d708dc8d63be763`；精确源文件SHA256、每个测试帧周期及输入SHA256保存在 [MJPEG_D1_MEASUREMENTS.json](MJPEG_D1_MEASUREMENTS.json)。

D1完成的是Python标准库模型和PC转换器，**没有新增RTL，也没有修改SPI、TD工程、约束或厂商IP**。下面的“周期实测”指对实际JPEG逐帧完整熵解码后，执行有限缓存调度模型所得；不是RTL/TD/板卡实测。IDCT每块176拍、RGB每MCU784拍仍是设计假设，后续必须逐拍对齐RTL。

## 1. 四条批注的落实

- PCM reservoir改为4096×8，4块BRAM，目标增量19、总数58。满缓存21.33ms加WAV约16ms共37.33ms；低水位改2KiB、高水位4KiB，PCM单次补给最多4扇区且不超过剩余容量。低水位本身仅10.67ms，不能把满缓存的4倍余量套到每个时刻。
- D2–D6每阶段都注册实际模块进TD工程并综合；记录当阶段和累计增量，与估算比较，任一资源累计绝对偏差>30%或突破硬预算就停。没有本地TD报告就不推进下一RTL阶段。当前没有填造任何综合数值，记录表见 [MJPEG_RESOURCE_LOG.md](MJPEG_RESOURCE_LOG.md)。
- 独立S1放在D1后、D2前：25MHz改动必须照片/音乐/卡带三路仿真和构建全过，且用户板上实测持续读率≥1.50MB/s、audio gap≤8ms；否则D2不开始。
- 降级优先级为压缩比→640×480@15→480×360；各档SD需求、RGB565写带宽、触发门槛及需用户确认新目标的规则已写入设计§8.2.1。D1默认仍只生成640×480@24，不暗中启用fallback。

素材限制：硬件索引容量512帧，默认转换器演示限制为**≤504帧/21秒**，每个视频帧对应2000个立体声采样帧（L/R对）。48k双声道PCM尾部的小于0.1秒端点差异会补/裁到精确N×2000对，超过则拒绝。

## 2. 40KiB帧的最坏周期结果

| 样本 | JPEG总B | 熵区B | 完整流水周期 | 50MHz耗时ms | 35ms门槛 |
|---|---:|---:|---:|---:|---|
| dc_only | 2,859 | 2,700 | 1,268,776 | 25.37552 | 通过 |
| custom_rst40 | 4,723 | 4,558 | 1,268,794 | 25.37588 | 通过 |
| 40k_short_balanced | 40,960 | 40,797 | 1,592,794 | 31.85588 | 通过 |
| 40k_short_frontloaded | 40,960 | 40,797 | 1,976,724 | 39.53448 | 拒绝 CORE_CYCLES |
| 40k_short_backloaded | 40,960 | 40,797 | 1,976,642 | 39.53284 | 拒绝 CORE_CYCLES |
| 40k_16bit_codes | 40,960 | 40,796 | 1,355,232 | 27.10464 | 通过 |

四个边界帧均为**精确40960 B**，熵区约40796–40797 B，只有约161–162 B头部；不是靠塞入数万字节APP/COM来凑40KiB。短Huffman码+幅值1构造较高的每字节符号数；分别将非零系数均匀分布、集中在前部/后部，另有16位码长压力样本。FFmpeg独立成功解码了前部集中、16位码和DRI=40/RST样本。

本语料最坏是前部集中帧：**1,976,724拍 / 39.53448ms**，超过1,750,000拍，按CORE_CYCLES拒绝；后部集中也拒绝。均匀帧只有31.85588ms，说明大小相同、平均吞吐足够仍可能因为局部高熵与有限bank而不达标。**40KiB尺寸检查不能代替每帧周期检查。**

这是列明输入集合的实跑最大值，不冒充所有40KiB合法JPEG的形式化上界。转换器对每一帧都运行模型，超限就提高压缩比重试，直到通过或达到q=31拒绝；绝不放宽35ms门槛。

调度模型真实使用两块系数bank、两块MCU样本bank、两块双MCU条带bank，保留所有权到消费者完成；Huffman按实际码长/符号数/FF00/RST计费。外部输入被假设随时可用，输出sink无阻塞，故SD等待及SDRAM落盘commit不在这个35ms指标内，仍须S1/D2/整机各自验证。

## 3. 实际FFmpeg转换

普通合成素材：640×480 testsrc2+440Hz正弦，0.5秒/12帧；q=4、gain=0.5。最大JPEG **26,657 B**，最坏帧#11为 **1,486,652拍 / 29.73304ms**，全部帧通过。

噪声素材：固定seed=20261031，2帧。q=2首帧98,748B被FRAME_SIZE拒绝，实际重新调用FFmpeg到q=4；最大帧 **40,897B**，最慢 **1,500,406拍 / 30.00812ms**，通过。完整attempt记录在JSON，测试另覆盖“尺寸≤40KiB但周期超限”的重试。

转换器显式设置`yuvj420p`、BT.601/full range、SOF0 MJPEG和default Huffman；验证器仍解析动态DHT/DQT，不依赖硬编码标准表。转换后完整检查SOF/SOS采样与表选择、所有DC/AC、ZRL/EOB、幅度、RST序列、EOI、容器边界/音轨和每帧周期；失败时不覆盖已有输出。写卡模式在打开原始卷之前先执行完整验证，本次没有运行物理写卡。

## 4. 参考与测试

`python -m unittest discover -s tests -v`：**51通过、0失败**。

- `mjpeg_ref/jpeg.py`：marker/段、DQT、canonical DHT、去填充/取位、熵/DC预测/RST、反zigzag/反量化；覆盖非默认表ID1、最长16位码、负值、非法树/缺表/跨块ZRL/截断/错误RST。
- `mjpeg_ref/image.py`：两遍Q16整数IDCT和独立二维双精度IDCT、full-range YCbCr→RGB565、MCU与4:2:0地址映射。20组固定seed的满范围随机块及DC/单AC/极值样本通过maxabs≤3。
- `mjpeg_ref/cycles.py`：完整帧、有限bank依赖和局部高熵分布检查；不能只取各级总时间的max。
- `mjpeg_ref/container.py`：YXV端序/表/不重叠/first offset/槽越界、空音轨/音画时长；第513帧和未批准profile明确拒绝。
- `mjpeg_ref/vectors.py`：合成向量生成，不提交实际图片/音乐素材；`mjpeg_d1_benchmark.py`导出六组逐帧测量。
- 逐点导出已验证：7200块的DC/AC/EOB token、每块64个反量化值/第一遍值/输出样本；307200个RGB565像素共614400B全部与flat金标一致。DHT码字/描述符及DQT也导出，可供D3–D6的RTL TB逐点比较。
- CLI对周期超限帧实际返回exit=1，合法帧/转换返回0；没有用“打印FAIL仍退出0”代替拒绝。

播放器/SD仲裁/CDC/SDRAM等控制模型与RTL TB要到各自阶段补齐，本次不宣称这些尚不存在的模块已经验证。D1通过也不等于19块BRAM/7.6K LUT已经实测。

## 5. 在仓库根目录复现（Python 3.10+，无pip）

```text
python -m unittest discover -s tests -v
python tools/mjpeg_d1_benchmark.py --out out/mjpeg_d1
python tools/mjpeg_d1_inspect.py out/mjpeg_d1/dc_only.jpg --trace-prefix out/mjpeg_d1/gold --report out/mjpeg_d1/gold.json
```

检查被拒帧（默认命令应非零退出；加诊断开关只为导出报告，accepted仍为false）：

```text
python tools/mjpeg_d1_inspect.py out/mjpeg_d1/40k_short_frontloaded.jpg
python tools/mjpeg_d1_inspect.py out/mjpeg_d1/40k_short_frontloaded.jpg --allow-cycle-failure --report out/mjpeg_d1/rejected.json
```

端到端素材全部由FFmpeg合成；以下命令在Windows和Linux仓库根目录都可使用，`out/mjpeg_d1`由前述benchmark创建：

```text
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x480:rate=24:duration=0.5 -f lavfi -i sine=frequency=440:sample_rate=48000:duration=0.5 -c:v ffv1 -c:a pcm_s16le -shortest out/mjpeg_d1/source.mkv
python tools/video2yxv.py --in out/mjpeg_d1/source.mkv --out out/mjpeg_d1/clip.yxv --report out/mjpeg_d1/clip.json --gain 0.5
python tools/video2yxv.py --verify out/mjpeg_d1/clip.yxv --report out/mjpeg_d1/verified.json
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x480:rate=24:duration=0.083333,noise=alls=12:allf=t+u:all_seed=20261031 -f lavfi -i sine=frequency=440:sample_rate=48000:duration=0.083333 -c:v ffv1 -c:a pcm_s16le -shortest out/mjpeg_d1/noisy_source.mkv
python tools/video2yxv.py --in out/mjpeg_d1/noisy_source.mkv --out out/mjpeg_d1/noisy.yxv --report out/mjpeg_d1/noisy.json --quality 2
```

FFmpeg版本差异可能改变字节数/源素材质量结果，实际容器/每帧SHA和版本必须随报告保存。Python合成边界JPEG生成器不调用FFmpeg，其输入字节和模型结果可按记录SHA复现。

## 6. 当前停止点

D1代码与报告交付后停在这里。**S1尚未实施/验收；SPI仍为冻结路径原值，TD综合和板上≥1.50MB/s均未执行；D2没有开始。** 不能用本次Python测试代替S1的照片/音乐/卡带三路回归或用户实测。
