# S1-B板测回归处理：P0旁路、P1独立实验、P2扩展验证

日期：2026-10-31。原失败版本`feat/mjpeg@27e6d08`；负责人原始报告来自`main@ea07382`，已fetch并将 [S1B_HW_FAILURE.md](S1B_HW_FAILURE.md) 原样取入。**单拍实现的板测回归已确认，本轮没有宣称定位或修复根因。** 用户已回滚冻结bit；本轮不改main、冻结固件、厂商命令层/厂商RAM/IP、工程或约束，不生成TD bitstream。

## 1. P0：优先交付可本地构建的25MHz+旧两拍配置

两项独立提交，均已推送`feat/mjpeg`：

| 提交 | 唯一生产变更 | 回退方式 |
|---|---|---|
| `ca3201e` | 核心默认`DRAIN_1CYC=1→0`，原SET/GET逻辑保留 | 恢复默认1只用于经批准的单拍诊断；当前不要恢复 |
| `9fe4055` | probe的`SPI_HIGHFREQ:6_250_000→25_000_000`，注释标明P0验收配置 | 只revert此提交即可退回6.25MHz，默认仍保持旧两拍 |

P0可直接构建`9fe4055`；本报告所在`feat/mjpeg`后续提交只补TB/文档，生产配置仍是上述两项。未改`sd_card_control.v`、`spi_driver.v`、`sd_read_sector.v`，不把提频与单拍修复混成一次改动。

理论旧两拍吞吐上界：`512/(512*8/25e6+1024/50e6)=2.7778MB/s`（不含CMD、卡忙、事务切换），不能冒充板测。640×480@24最坏40KiB帧加PCM需1.175040MB/s。请用户本地用仓库根目录`AC201_AL_board_test.al`构建，记录TD时序/资源/提交与`best_result/AC201_AL_board_test.bit`时间戳后烧写；用SCE有效字节差/实际墙钟测量，记录频率、卡、窗口、回绕、重试与任何扣除项。P0正常服务窗口按本次要求验≥1.50MB/s，含全部等待的系统平均≥1.20MB/s口径另记，不能互相代替。

**P0本地TD、照片/音乐/卡带板测、SCE实测仍待用户完成。** 软件源fixture没有SPI命令/物理引脚模型，下面的通过证明排空与消费者RTL回归，不证明25MHz的电气/时序/板上速率。P0独立通过后视频可绕过S1-B继续，S1-B保持未验收；当前不启动视频实现。

## 2. P1：三个独立、最小的实验源码版本

三者从`27e6d08`独立派生，每个分支只改核心指定逻辑与实验注释；不含P0默认回退或25MHz配置，SPI仍原6.25MHz。三个分支已推送，可分别切换构建，不要把A/B/C叠加cherry-pick。

| 实验 | Git分支/提交 | 地址(a) | 状态(b) | 本轮软件结果 | 板测 |
|---|---|---|---|---|---|
| A | `exp/s1b-a@abbb173` | `ctrl_rd_ram_addr=drain_addr` | 非末字节保持GET | 512B捕获，511B与金标不同，符合有意错位 | 待测 |
| B | `exp/s1b-b@4da1a9c` | 保留预取 | 非末字节回SET | 512B零diff；卡带WC604、BADC0UNT=0 of604 | 待测 |
| C | `exp/s1b-c@1bcee71` | 回退 | 回退 | 512B零diff；卡带WC604、BADC0UNT=0 of604 | 待测，必须作为对照 |

本地先`git fetch origin`，按需`git switch --detach <上表提交>`后打开同一路径的TD工程分别构建/烧写；每次重跑构建、另存bit和完整遥测，防止拿到上一实验的best_result。完成后`git switch feat/mjpeg`返回P0默认配置。云端没有TD，因此交付的是四套可构建源码配置，不虚构四个.bit。

**A预期修正及定位限制**：同步读一拍且无背压时，A输出地址序列`0,0,1,2,…,510`；首字节重复一次，随后滞后一字节，不是所有字节各重复两次。本轮前缀实测为`a7 a7 82 ed c8 33 1e 79`，金标为`a7 82 ed c8 33 1e 79 a4`。所以A板测WC=0可能只是这个有意错位，不能仅凭A失败断言原(a)有bug。若B失败而C通过，才进一步聚焦(a)相关硬件路径；若B/C都过，原(a)+(b)组合仍是定位对象；若C也失败先停并核验构建/对照，不扩改其他模块。任何定位结论均需保留原失败版本和板上A/B/C结果。

实验源码SHA：

| 实验 | 完整提交 | 核心SHA256 |
|---|---|---|
| A | `abbb173101ed0aef3fb1985a8ab80e7e47173fc6` | `e22eed97d1188324bb9949acd91763829362aa5ab9f4dbb953b89c79e2bec613` |
| B | `4da1a9ced993a4dd27c7fe3876fe76adce2bb517` | `9ea1087578661da0f80cf0f786d0f6a6c265b9db1de2f3a6067002ef37d28278` |
| C | `1bcee717c61d6d078ea494e0b0ee2a023383f3a5` | `0eb8424a537dbfd533e77d289092c3e7fada009d570975b8602583cd27ebeeaa` |

## 3. P2：CTRLPHASE与同址同拍竞争

`sd_drain_source`新增`CTRLPHASE=0/1/2/4`和`COLLIDE_FINAL`，仅在TB；真实vendor `ram_dual_port_simple`原样实例化。定义最后a写边沿W，done在W+N边沿NBA拉高，核心在W+N+1采样，激励自身有断言，避免把“拉高时刻”与“采样时刻”错算一拍。

同址竞争刺激先给地址0写`expected^FF`毒值，随后写地址1…511，最后写0；最终512B与普通扇区完全相同。b口等待时读0，最后a写也为0，从而确实发生同拍竞争。沿后明确断言：`douta/doutb==沿前旧值`且`ram[0]==新值`，随后stream有效字节全部与最终新扇区一致。此为压力用例，不声称真实控制器采用该写入顺序，也不修改RAM为旁路新值模型。原RTL非阻塞赋值的读口结果是旧值，不能将“写最终生效”误称为读口写穿透。

`tb_sd_ctrlphase`交叉4相位×2copy模式×2背压模式×2DRAIN模式=32个DUT组合；每组3扇区、零请求、途中复位和1扇区重放，逐字节和元数据全比较；随机/尾字节停顿同时检查保持。无背压单拍513、旧两拍1024。

**513 = 512数据拍 + 1拍排空。** 计时从TB采样read_complete到第512B接受，包含首字节准备开销。带背压时报告实际等待，不能删等待后冒充读卡速率。

本轮32组合均零diff，包括实际旧值读竞争，但原单拍板上失败依然有效：**要求的这组相位/碰撞刺激没有复现WC=0，故尚不能确定根因。** 用户已排除的done稳定、a口停写、wrapper直通及注册读延迟不再作为“已发现问题”重报。本轮只增加定位证据，不顺手改消费者/CDC/厂商层，也不凭时序或推断RAM映射猜测提交修复。

## 4. 三路软件回归逐项结果

| 路径 | 照片BMP | 音乐48k | 音乐44.1k | 卡带 |
|---|---|---|---|---|
| P0旧两拍MODE0 | PASS：460800/460800字，921600/921600像素逐点零diff | RATECHK9991/10000、CHUNKCHK9次精确匹配 | RATECHK9180/9187、CHUNKCHK9次精确匹配 | WC604(25C)，BADC0UNT=0 of604，padding/meta零diff |
| 原单拍MODE1 | 同一图像全字零diff | RATECHK9991/10000、CHUNKCHK9次 | RATECHK9180/9187、CHUNKCHK9次 | WC604(25C)，BADC0UNT=0 of604；**不推翻已知板测失败** |

WC期望始终动态读镜像头部words字段，不由DUT回读值或604常量反推。WAV沿用加速tick/CHUNK_BYTES8192，RATECHK容差±300/10000，CHUNKCHK逐次严格一致。卡带保留1M sys周期POR及真实程序RAM逐词比较。**CPU cosim已知基线问题未运行、未标通过；PC/SP板上运行证据待测**。本轮并未补写或宣称CPU功能回归通过。

## 5. P3：板测验收已写入设计文档

[DESIGN_MJPG.md §9.2/§10.1](DESIGN_MJPG.md#92-集成后仍需跑的基线与本地验收)现要求WC匹配本次镜像头部（当前invaders604=25C）、PC非零且变化、SP/spr_cnt在连续运行窗口中增长，三项同时满足；LS=4、ACC512、OFF整块字节数均不能替代它们。按计数器位宽处理SP回绕，复位/重载分段，保留至少启动及10个连续1秒窗口的遥测。SST突增与看门狗重读单列，不能算有效首遍读率。

负责人实测原失败bit LUT10463相对冻结10519净−56、BRAM39/DSP0不变已记录；pix+0.185ns、SDRAM+0.624ns为该bit实测，非P0或本轮新综合结果。资源优点保留研究价值，不能抵销功能失败或直接抵扣后续预算。

## 6. 复现与输入

仓库内Python3、iverilog/vvp可用时运行`python3 tb/run_sd_drain.py`（此云环境先将`/workspace/.yingxu-env/bin`加PATH）；脚本导出三实验的已提交核心到忽略目录out，用4线程执行独立测试，任何非零退出/超时均失败。`results.json`保存原始命令、退出码、输入SHA和日志；以下将全部stdout提交进本报告，out不是唯一交付物。全部15组compile均无诊断输出、vvp退出码0。A的exit0表示“有意错位的捕获符合预期”，**不是A功能通过**。原始stdout中的`$finish`行为与源行号完整保留。

当前核心及测试输入SHA256：

- `src/user_source/hdl_source/media/sd/sd_stream_reader_core.v`: `612156fe66cf539fc0cfe64c87cd4bc2edb582e484b075cd70ce79d463c0b0ea`
- `tb/tb_sd_drain.v`: `bfee75793974b756b85671c7ae55b6bb95c3795d26460760043c890822dd1040`
- `src/user_source/hdl_source/media/sd/ram_dual_port_simple.v`: `141a83fc26849fdb6859fd0bfd52b23b274770dd07a99bd0784deeb2aa4f49b6`
- `cartridges/invaders.yxc`: `da121599d1e8c754bd9fff4d7663a8fa43710c7bdf812ea4f24c66bd5c83e696`

完整展开命令（脚本已执行，目录out/s1b_hw由脚本创建，实验源码由上表git对象导出）：

```text
iverilog -g2012 -s tb_sd_drain -o out/s1b_hw/drain.vvp tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v
vvp out/s1b_hw/drain.vvp
iverilog -g2012 -s tb_sd_ctrlphase -o out/s1b_hw/ctrlphase.vvp tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v
vvp out/s1b_hw/ctrlphase.vvp
iverilog -g2012 -s tb_sd_bmp -o out/s1b_hw/p0_bmp.vvp -Ptb_sd_bmp.MODE=0 tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yingxu_bmp_loader.v
vvp out/s1b_hw/p0_bmp.vvp
iverilog -g2012 -s tb_sd_wav -o out/s1b_hw/p0_wav48.vvp -Ptb_sd_wav.MODE=0 tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yingxu_wav_player.v
vvp out/s1b_hw/p0_wav48.vvp +file=tb/assets/tb_tune.yxm
iverilog -g2012 -s tb_sd_wav -o out/s1b_hw/p0_wav44.vvp -Ptb_sd_wav.MODE=0 tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yingxu_wav_player.v
vvp out/s1b_hw/p0_wav44.vvp +file=tb/assets/tb_tune44.yxm
iverilog -g2012 -s tb_sd_cart -o out/s1b_hw/p0_cart.vvp -Ptb_sd_cart.MODE=0 tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yx8_cart_soc.v src/user_source/hdl_source/yx8_cpu.v
vvp out/s1b_hw/p0_cart.vvp +file=cartridges/invaders.yxc
iverilog -g2012 -s tb_sd_bmp -o out/s1b_hw/single_bmp.vvp -Ptb_sd_bmp.MODE=1 tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yingxu_bmp_loader.v
vvp out/s1b_hw/single_bmp.vvp
iverilog -g2012 -s tb_sd_wav -o out/s1b_hw/single_wav48.vvp -Ptb_sd_wav.MODE=1 tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yingxu_wav_player.v
vvp out/s1b_hw/single_wav48.vvp +file=tb/assets/tb_tune.yxm
iverilog -g2012 -s tb_sd_wav -o out/s1b_hw/single_wav44.vvp -Ptb_sd_wav.MODE=1 tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yingxu_wav_player.v
vvp out/s1b_hw/single_wav44.vvp +file=tb/assets/tb_tune44.yxm
iverilog -g2012 -s tb_sd_cart -o out/s1b_hw/single_cart.vvp -Ptb_sd_cart.MODE=1 tb/tb_sd_drain.v src/user_source/hdl_source/media/sd/sd_stream_reader_core.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yx8_cart_soc.v src/user_source/hdl_source/yx8_cpu.v
vvp out/s1b_hw/single_cart.vvp +file=cartridges/invaders.yxc
iverilog -g2012 -s tb_sd_variant -o out/s1b_hw/experiment_A.vvp -Ptb_sd_variant.EXPECT_BAD=1 tb/tb_sd_drain.v out/s1b_hw/core_A.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v
vvp out/s1b_hw/experiment_A.vvp
iverilog -g2012 -s tb_sd_variant -o out/s1b_hw/experiment_B.vvp tb/tb_sd_drain.v out/s1b_hw/core_B.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v
vvp out/s1b_hw/experiment_B.vvp
iverilog -g2012 -s tb_sd_variant -o out/s1b_hw/experiment_C.vvp tb/tb_sd_drain.v out/s1b_hw/core_C.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v
vvp out/s1b_hw/experiment_C.vvp
iverilog -g2012 -s tb_sd_cart -o out/s1b_hw/experiment_B_cart.vvp -Ptb_sd_cart.MODE=1 tb/tb_sd_drain.v out/s1b_hw/core_B.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yx8_cart_soc.v src/user_source/hdl_source/yx8_cpu.v
vvp out/s1b_hw/experiment_B_cart.vvp +file=cartridges/invaders.yxc
iverilog -g2012 -s tb_sd_cart -o out/s1b_hw/experiment_C_cart.vvp -Ptb_sd_cart.MODE=1 tb/tb_sd_drain.v out/s1b_hw/core_C.v src/user_source/hdl_source/media/sd/ram_dual_port_simple.v src/user_source/hdl_source/yx8_cart_soc.v src/user_source/hdl_source/yx8_cpu.v
vvp out/s1b_hw/experiment_C_cart.vvp +file=cartridges/invaders.yxc
```

## 7. 完整原始stdout

### drain（exit=0）

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

### ctrlphase（exit=0）

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

### p0_bmp（exit=0）

```text
BMPCHK: PASS 1280x720 words=460800/460800 pixels=921600/921600 zero-diff
tb/tb_sd_drain.v:336: $finish called at 166243100000 (1ps)
```

### p0_wav48（exit=0）

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

### p0_wav44（exit=0）

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

### p0_cart（exit=0）

```text
CART_HEADER expected_words=604 expected_WC_hex=0000025c file_bytes=1844 sectors=4
CART_DIAG wc=604 words_r=604 requested=1 file_bytes=1844 loaded=1 state=4
CART_WORDCHK: BADC0UNT=0 of 604; WC=604 expected=604
CARTCHK: PASS BADC0UNT=0 of 604; cart_wcnt(WC)=604 (hex=25c); padding/meta zero-diff
tb/tb_sd_drain.v:398: $finish called at 20123231548 (1ps)
```

### single_bmp（exit=0）

```text
BMPCHK: PASS 1280x720 words=460800/460800 pixels=921600/921600 zero-diff
tb/tb_sd_drain.v:336: $finish called at 111044880000 (1ps)
```

### single_wav48（exit=0）

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

### single_wav44（exit=0）

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
tb/tb_sd_drain.v:455: $finish called at 15209796694 (1ps)
```

### single_cart（exit=0）

```text
CART_HEADER expected_words=604 expected_WC_hex=0000025c file_bytes=1844 sectors=4
CART_DIAG wc=604 words_r=604 requested=1 file_bytes=1844 loaded=1 state=4
CART_WORDCHK: BADC0UNT=0 of 604; WC=604 expected=604
CARTCHK: PASS BADC0UNT=0 of 604; cart_wcnt(WC)=604 (hex=25c); padding/meta zero-diff
tb/tb_sd_drain.v:398: $finish called at 20084041684 (1ps)
```

### experiment_A（exit=0）

```text
VARIANT_BYTE index=0 actual=a7 expected=a7
VARIANT_BYTE index=1 actual=a7 expected=82
VARIANT_BYTE index=2 actual=82 expected=ed
VARIANT_BYTE index=3 actual=ed expected=c8
VARIANT_BYTE index=4 actual=c8 expected=33
VARIANT_BYTE index=5 actual=33 expected=1e
VARIANT_BYTE index=6 actual=1e expected=79
VARIANT_BYTE index=7 actual=79 expected=a4
VARIANT_CAPTURE: count=512 mismatch=511 expected_corruption=1 (diagnostic, not board acceptance)
tb/tb_sd_drain.v:297: $finish called at 20820000 (1ps)
```

### experiment_B（exit=0）

```text
VARIANT_BYTE index=0 actual=a7 expected=a7
VARIANT_BYTE index=1 actual=82 expected=82
VARIANT_BYTE index=2 actual=ed expected=ed
VARIANT_BYTE index=3 actual=c8 expected=c8
VARIANT_BYTE index=4 actual=33 expected=33
VARIANT_BYTE index=5 actual=1e expected=1e
VARIANT_BYTE index=6 actual=79 expected=79
VARIANT_BYTE index=7 actual=a4 expected=a4
VARIANT_CAPTURE: count=512 mismatch=0 expected_corruption=0 (diagnostic, not board acceptance)
tb/tb_sd_drain.v:297: $finish called at 31040000 (1ps)
```

### experiment_C（exit=0）

```text
VARIANT_BYTE index=0 actual=a7 expected=a7
VARIANT_BYTE index=1 actual=82 expected=82
VARIANT_BYTE index=2 actual=ed expected=ed
VARIANT_BYTE index=3 actual=c8 expected=c8
VARIANT_BYTE index=4 actual=33 expected=33
VARIANT_BYTE index=5 actual=1e expected=1e
VARIANT_BYTE index=6 actual=79 expected=79
VARIANT_BYTE index=7 actual=a4 expected=a4
VARIANT_CAPTURE: count=512 mismatch=0 expected_corruption=0 (diagnostic, not board acceptance)
tb/tb_sd_drain.v:297: $finish called at 31040000 (1ps)
```

### experiment_B_cart（exit=0）

```text
CART_HEADER expected_words=604 expected_WC_hex=0000025c file_bytes=1844 sectors=4
CART_DIAG wc=604 words_r=604 requested=1 file_bytes=1844 loaded=1 state=4
CART_WORDCHK: BADC0UNT=0 of 604; WC=604 expected=604
CARTCHK: PASS BADC0UNT=0 of 604; cart_wcnt(WC)=604 (hex=25c); padding/meta zero-diff
tb/tb_sd_drain.v:398: $finish called at 20123231548 (1ps)
```

### experiment_C_cart（exit=0）

```text
CART_HEADER expected_words=604 expected_WC_hex=0000025c file_bytes=1844 sectors=4
CART_DIAG wc=604 words_r=604 requested=1 file_bytes=1844 loaded=1 state=4
CART_WORDCHK: BADC0UNT=0 of 604; WC=604 expected=604
CARTCHK: PASS BADC0UNT=0 of 604; cart_wcnt(WC)=604 (hex=25c); padding/meta zero-diff
tb/tb_sd_drain.v:398: $finish called at 20123231548 (1ps)
```

## 8. 停止点

P0/A/B/C源码、扩展TB、可复现runner和本文交付后等待板测。P0先测，允许视频摆脱单拍修复的前置依赖，但**当前没有板测通过证据，不启动D2**。A/B/C仍各自待板测；CTRLPHASE全部通过不叫根因已修复。不改任何其他生产模块，不发布或替换冻结bit。
