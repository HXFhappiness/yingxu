# S1-B 排空实现与校正后回归：软件仿真通过，板上门禁待测

本轮依据负责人校正 `main@f6b9a22`，原样同步HANDOFF_FULL、TASK_S1S2_SRAM、FREEZE_20261031三份文档。仅更新新增TB中的期望值来源与本报告；**生产core、所有消费者/厂商模块、SPI频率、工程/约束、卡带镜像与汇编源均未改**，main未写入。前次`2c9293a`按旧606词要求停止的记录保留在该历史提交；负责人确认604正确后，本轮重新跑全部要求的回归，不把旧失败悄悄改成旧通过。

## 1. 实现与背压行为（本轮未变）

新增参数`DRAIN_1CYC`默认1，0保留原SET/GET两拍路径。原厂`ram_dual_port_simple`为同一clk的一拍同步读；SET预取第0字节。在GET且`stream_ready=1`、当前地址不是511时，将`drain_addr+1`送入RAM输入，在接受当前输出的同一时钟边沿预读下一字节，同时递增输出游标并继续GET。最后一字节不预读地址0；done/sector_count/offset仍只按成功握手更新。

**ready=0时输出游标不递增，物理RAM地址选回当前字节并在停顿期间保持，RAM重读同址，stream_data/valid/offset/first/last保持。** ready的撤销可以撤回尚未被时钟采样的组合预读地址，这不是游标已经前进；没有已发出但无法保存的额外返回，因此不新增skid或修改RAM。恢复ready时，当前字节先被接受，同边沿才读下一地址。新增ready→9位RAM地址选择是sys域路径，TD时序/LUT实测尚未执行，不以仿真冒充硬件时序通过。


**513 = 512 数据拍 + 1 拍排空**（首字节预取开销）；≤520目标保持不变。统计起点为扇区read_complete被core接受，终点为最后字节成功握手，不混入扇区装载/初始化时间。

## 2. 期望值改为镜像头驱动

TB先验证YXCA魔数与至少32B头，从偏移8/9小端读取`file_words`，再验证1..768词及文件长度与头部code/data长度一致。实际WC及`words_r`用四态严格比较`!== file_words`，逐词循环上限同样取`file_words`，扇区数取`ceil(file_bytes/512)`，不再固定4。**测试源没有硬编码604或606**，也不从DUT的实际输出反推期望。

本次真实镜像1844B=32+604×3，头words=604，仿真WC=604（十六进制25C）。现有yxa重新汇编仍输出604词，生成文件与跟踪镜像逐字节相同，SHA见下。本invaders加载测试明确只支持无DATA段fixture：若将来DATA非0则显式失败并要求对应数据金标，不把它默认为零通过。

为验证不是把606换成另一硬编码值，另在忽略的out目录生成**701词/2135B/5扇区**的合成加载向量（原镜像尾加97条零NOP并改头，非发布卡带）。同一TB不改代码即得到WC=701、BADC0UNT=0 of701；未修改仓库镜像，未以该合成向量代替真实604词回归。

## 3. 本轮逐项结果

| 仿真项 | 结果 | 本轮证据 |
|---|---|---|
| DRAINCHK | 通过，exit=0 | 513拍 vs 原1024拍；A/B512B逐字节一致，三扇区1536B、背压、末字节暂停、复位重放通过 |
| 照片BMP | 通过，exit=0 | 完整1280×720、5401扇区；460800个32位RGB565字/921600像素零diff，到WR2口 |
| WAV48k | 通过，exit=0 | pops16001、非零15997、过零195；RATECHK9991/10000，CHUNKCHK9次精确匹配 |
| WAV44.1k | 通过，exit=0 | pops16000、非零15975、过零196；RATECHK9180/9187，CHUNKCHK9次精确匹配 |
| 卡带真实镜像 | **通过，exit=0** | 头部期望604、WC604/25C；BADC0UNT=0 of604，填零/metadata正确 |
| 卡带头部漂移向量 | 通过，exit=0 | 动态期望701、WC701/2BD；BADC0UNT=0 of701，自动读取5扇区 |
| CPU cosim | 未运行，未标通过 | 已知基线问题不纳入本任务 |
| TD/sys时序、板上EFFCHK、UART遥测WC | **待用户测** | 本轮未改SPI频率，仿真字段不冒充板上UART；12.5MHz有效读率≥1.50MB/s仍需用户实测 |

WAV仍沿用原bench每64个pix周期一次tick的加速测试方式，CHUNK_BYTES=8192覆盖短素材的块推进。RATECHK沿用原±300/10000容差，CHUNKCHK严格比较请求偏移与已接受扇区数；原型读卡替身只把字节填入实际同步RAM，不模拟SPI协议。BMP未声称物理SDRAM/HDMI通过。

## 4. 复现

在仓库根目录，先创建`out/s1b_corrected`，确保iverilog/vvp在PATH。以下编译无诊断输出，执行均为exit=0：

```text
iverilog -g2012 -s tb_sd_drain -o out/s1b_corrected/drain.vvp tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v
vvp out/s1b_corrected/drain.vvp
iverilog -g2012 -s tb_sd_bmp -o out/s1b_corrected/bmp.vvp tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yingxu_bmp_loader.v
vvp out/s1b_corrected/bmp.vvp
iverilog -g2012 -s tb_sd_wav -o out/s1b_corrected/wav.vvp tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yingxu_wav_player.v
vvp out/s1b_corrected/wav.vvp +file=tb/assets/tb_tune.yxm
vvp out/s1b_corrected/wav.vvp +file=tb/assets/tb_tune44.yxm
iverilog -g2012 -s tb_sd_cart -o out/s1b_corrected/cart.vvp tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yx8_cart_soc.v src/user_source/hdl_source/yx8_cpu.v
vvp out/s1b_corrected/cart.vvp +file=cartridges/invaders.yxc
```

真实卡带重建校验：

```text
python tools/yxa.py cartridges/invaders.asm out/s1b_corrected/invaders_rebuilt.yxc
yxa: out/s1b_corrected/invaders_rebuilt.yxc — 604 words (1812 B code), 0 B data @0x00, entry=0, title="INVADERS"
```

头部漂移向量生成器（保存为`.py`执行；生成物仅放out），再用相同cart.vvp测试：

```python
from pathlib import Path
original = Path('cartridges/invaders.yxc').read_bytes()
words = int.from_bytes(original[8:10], 'little')
assert len(original) == 32 + words * 3
target = words + 97
assert target <= 768
fixture = bytearray(original + bytes((target - words) * 3))
fixture[8:10] = target.to_bytes(2, 'little')
Path('out/s1b_corrected/header_drift.yxc').write_bytes(fixture)
```

```text
vvp out/s1b_corrected/cart.vvp +file=out/s1b_corrected/header_drift.yxc
```

卡带仍完整运行原1,000,000个sys周期POR，只有TB将未复位POR寄存器设为器件上电值0，没有强制loaded或跳过CPU/加载逻辑。

源与输入SHA256：

- `src/user_source/hdl_source/media/sd/sd_stream_reader_core.v`: `08134549713574e03f8de3b33b3b9d6e3d0738ce168516d462b12016d81c4ba8`
- `tb/tb_sd_drain.v`: `f35dcb14be023441d5052eb10305fda57e820a5a460b315422ef9368b1aa2ef3`
- `cartridges/invaders.yxc`: `da121599d1e8c754bd9fff4d7663a8fa43710c7bdf812ea4f24c66bd5c83e696`

## 5. 本轮完整原始stdout

下列为每次vvp的全部输出，未删CHUNKCHK或`$finish`行；各命令stderr为空、退出码0。

### drain（exit=0）

```text
DRAINCHK: PASS sectors=1 stall=0 compare=512 fast_last_sector=513 old_last_sector=1024
DRAINCHK: PASS sectors=1 stall=0 compare=512 fast_last_sector=513 old_last_sector=1024
DRAINCHK: PASS sectors=3 stall=1 compare=1536 fast_last_sector=656 old_last_sector=1291
DRAINCHK: PASS sectors=1 stall=1 compare=512 fast_last_sector=701 old_last_sector=1275
DRAIN_SUITE: PASS zero request, A/B, random+tail stalls, reset/replay
tb/tb_sd_drain.v:198: $finish called at 153980000 (1ps)
```

### bmp（exit=0）

```text
BMPCHK: PASS 1280x720 words=460800/460800 pixels=921600/921600 zero-diff
tb/tb_sd_drain.v:235: $finish called at 111044880000 (1ps)
```

### wav48（exit=0）

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
tb/tb_sd_drain.v:354: $finish called at 13975793238 (1ps)
```

### wav44（exit=0）

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
tb/tb_sd_drain.v:354: $finish called at 15209796694 (1ps)
```

### cart（exit=0）

```text
CART_HEADER expected_words=604 expected_WC_hex=0000025c file_bytes=1844 sectors=4
CART_DIAG wc=604 words_r=604 requested=1 file_bytes=1844 loaded=1 state=4
CART_WORDCHK: BADC0UNT=0 of 604; WC=604 expected=604
CARTCHK: PASS BADC0UNT=0 of 604; cart_wcnt(WC)=604 (hex=25c); padding/meta zero-diff
tb/tb_sd_drain.v:297: $finish called at 20084041684 (1ps)
```

### cart_drift（exit=0）

```text
CART_HEADER expected_words=701 expected_WC_hex=000002bd file_bytes=2135 sectors=5
CART_DIAG wc=701 words_r=701 requested=1 file_bytes=2135 loaded=1 state=4
CART_WORDCHK: BADC0UNT=0 of 701; WC=701 expected=701
CARTCHK: PASS BADC0UNT=0 of 701; cart_wcnt(WC)=701 (hex=2bd); padding/meta zero-diff
tb/tb_sd_drain.v:297: $finish called at 20102913908 (1ps)
```

## 6. 当前停止点

此前WC旧数字阻塞已解除，S1-B代码与三路软件仿真已具备交付证据。**完整S1-B板上门禁仍待用户：本地TD/sys≥+1.5ns及pix裕量核验，12.5MHz有效读率≥1.50MB/s与三路板上回归**。此处不宣称硬件已验收，不启动D2，不修改SPI频率。
