# S1-B 排空实现与回归结果：整体门禁未通过

基线：`feat/mjpeg@063fb61`。只修改生产模块 `src/user_source/hdl_source/media/sd/sd_stream_reader_core.v`，新增 `tb/tb_sd_drain.v` 和本报告。厂商命令层、RAM、BMP/WAV/cart/CPU模块、SPI频率、main、冻结固件、工程及约束均未改。**卡带WC=606硬判据失败后已停止实现，不以诊断结果替代通过。**

## 1. 实现与背压行为

新增参数`DRAIN_1CYC`默认1，0保留原SET/GET两拍路径。原厂`ram_dual_port_simple`为同一clk的一拍同步读；SET预取第0字节。在GET且`stream_ready=1`、当前地址不是511时，将`drain_addr+1`送入RAM输入，在接受当前输出的同一时钟边沿预读下一字节，同时递增输出游标并继续GET。最后一字节不预读地址0；done/sector_count/offset仍只按成功握手更新。

**ready=0时输出游标不递增，物理RAM地址选回当前字节并在停顿期间保持，RAM重读同址，stream_data/valid/offset/first/last保持。** ready的撤销可以撤回尚未被时钟采样的组合预读地址，这不是游标已经前进；没有已发出但无法保存的额外返回，因此不新增skid或修改RAM。恢复ready时，当前字节先被接受，同边沿才读下一地址。新增ready→9位RAM地址选择是sys域路径，TD时序/LUT实测尚未执行，不以仿真冒充硬件时序通过。

## 2. 逐项结果

| 项 | 结果 | 证据/限制 |
|---|---|---|
| DRAINCHK两模式逐字节 | **通过** | 512B无背压513拍 vs 1024拍；快路径≤520、旧路径约1030范围；首字节预取计入，RAM装载时间不混入 |
| 背压/多扇区/复位 | **通过** | 三扇区1536字节A/B与独立序号oracle零diff；随机ready、末字节7拍暂停、零扇区请求、在途复位后重放；stall逐拍断言data/元数据与RAM地址稳定 |
| 照片BMP加载 | **通过** | 实际1280×720、54B头、5401扇区，经新core喂未改loader；460800个32位RGB565字/921600像素逐点零diff。验证至WR2数据口，未宣称物理SDRAM/HDMI板验收 |
| 音乐48k | **通过** | 经新core和实际同步RAM喂未改WAV；16001 pops、15997非零、195次过零；RATECHK=9991/10000，9次CHUNKCHK精确相等 |
| 音乐44.1k | **通过** | 16000 pops、15975非零、196次过零；RATECHK=9180/9187，9次CHUNKCHK精确相等 |
| 卡带逐词诊断 | **当前604词镜像零diff** | 新core→未改cart loader→真实u_prog RAM；BADC0UNT=0 of604，代码尾填0与meta均正确；这不等于要求的606词回归通过 |
| 卡带WC=606门 | **失败，退出码1** | 实际cart_wcnt=604，words_r=604；严格606断言保留；不改镜像/源码/CPU，不填两条NOP凑606 |
| 已知CPU cosim | **未运行，未标通过** | 本任务只验证卡带加载，不包含已知取指延迟基线问题 |
| TD综合/布局布线、EFFCHK、板上UART WC | **未执行** | 板/TD在用户本地；仿真WC字段不冒充实测UART遥测，SPI频率保持原值 |

WAV仿真沿用原测试的每64个pix时钟一次tick加速方式；SD测试替身只填充真实同步RAM，不模拟物理SPI卡协议，也不声称实测速率。CHUNK_BYTES=8192用于让短向量跨越多个块，RATECHK容差与现有tb_wav_mon的±300/10000一致，CHUNKCHK要求请求LBA偏移与累计已接受扇区完全相等。

## 3. WC差异定位与停止点

仓库`cartridges/invaders.yxc`为1844B，YXCA头code_words=604。运行现有汇编器：

```text
python tools/yxa.py cartridges/invaders.asm out/s1b/invaders_rebuilt.yxc
yxa: out/s1b/invaders_rebuilt.yxc — 604 words (1812 B code), 0 B data @0x00, entry=0, title="INVADERS"
```

重建镜像与仓库文件逐字节相同，SHA256均为`da121599d1e8c754bd9fff4d7663a8fa43710c7bdf812ea4f24c66bd5c83e696`。用修改前core做对照，实际同样WC=604、words_r=604、loaded=1；不是把旧CPU cosim问题当作本任务的豁免。对照仅在忽略的`out/s1b`保存原core，并从测试源副本删除旧core不支持的DRAIN_1CYC参数绑定，606断言未改；正式DUT始终只有本次core文件改动。

首次卡带测试在WC检查处失败后，未再修改任何实现逻辑。随后只增加诊断输出和文件头长度的逐词检查，**仍保留WC=606为整体测试的失败出口**，以确认具体差异。此状态不接纳为S1-B整体通过；后续需要负责人明确606词验收镜像的版本或基线口径，本任务没有自行降为604。

## 4. 复现命令（仓库根目录）

Python3/iverilog/vvp在PATH；先创建out/s1b。只运行新增TB，不修改现有测试或断言。

```text
iverilog -g2012 -s tb_sd_drain -o out/s1b/drain.vvp tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v
vvp out/s1b/drain.vvp
iverilog -g2012 -s tb_sd_bmp -o out/s1b/bmp.vvp tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yingxu_bmp_loader.v
vvp out/s1b/bmp.vvp
iverilog -g2012 -s tb_sd_wav -o out/s1b/wav.vvp tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yingxu_wav_player.v
vvp out/s1b/wav.vvp +file=tb/assets/tb_tune.yxm
vvp out/s1b/wav.vvp +file=tb/assets/tb_tune44.yxm
iverilog -g2012 -s tb_sd_cart -o out/s1b/cart.vvp tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yx8_cart_soc.v src/user_source/hdl_source/yx8_cpu.v
vvp out/s1b/cart.vvp +file=cartridges/invaders.yxc
```

最后一条当前必须以exit=1停止，不能以输出逐词零diff掩盖WC门失败。卡带TB明确将未复位POR计数器设为器件上电初值0，随后完整运行原1000000个sys周期（约20ms），没有跳过POR、强制loaded或更改CPU执行逻辑。BMP/WAV消费者源码均为原版本；后续仅加卡带诊断时，其他top的逻辑未改，不重复未受影响的回归。

生产core SHA256：`08134549713574e03f8de3b33b3b9d6e3d0738ce168516d462b12016d81c4ba8`；交付TB SHA256：`c41b905a859de63fbcd7de3c761e942ea32a9b4c9f6e131ca2fedc5c526f5f96`。下列日志对应本次运行；含退出码1的卡带结果不会被归为通过。

## 5. 原始日志

### drain

```text
DRAINCHK: PASS sectors=1 stall=0 compare=512 fast_last_sector=513 old_last_sector=1024
DRAINCHK: PASS sectors=1 stall=0 compare=512 fast_last_sector=513 old_last_sector=1024
DRAINCHK: PASS sectors=3 stall=1 compare=1536 fast_last_sector=656 old_last_sector=1291
DRAINCHK: PASS sectors=1 stall=1 compare=512 fast_last_sector=701 old_last_sector=1275
DRAIN_SUITE: PASS zero request, A/B, random+tail stalls, reset/replay
tb/tb_sd_drain.v:198: $finish called at 153980000 (1ps)
```

### bmp

```text
BMPCHK: PASS 1280x720 words=460800/460800 pixels=921600/921600 zero-diff
tb/tb_sd_drain.v:235: $finish called at 111044880000 (1ps)
```

### wav48

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
tb/tb_sd_drain.v:332: $finish called at 13975793238 (1ps)
```

### wav44

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
tb/tb_sd_drain.v:332: $finish called at 15209796694 (1ps)
```

### cart

```text
CART_DIAG wc=604 words_r=604 requested=1 file_bytes=1844 loaded=1 state=4
CART_WORDCHK: BADC0UNT=0 of 604; WC=604 required=606
FATAL: tb/tb_sd_drain.v:280: cart WC mismatch: strict 606 gate retained
       Time: 20084041684  Scope: tb_sd_cart
```

### cart_before

```text
CART_DIAG wc=604 words_r=604 requested=1 file_bytes=1844 loaded=1 state=4
FATAL: out/s1b/baseline_tb.v:267: cart WC mismatch
       Time: 20123231548  Scope: tb_sd_cart
```
