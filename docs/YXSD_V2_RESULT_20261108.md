# YX-SD v2（SD 高速升级）仿真结果（2026-11-08 修正版）

> 约束：初赛已结束，全部工作只做仿真验证，不烧录。仿真通过即验收。

## 1. 交付物

| 类别 | 文件 | 内容 |
|---|---|---|
| RTL（新增） | `src/user_source/hdl_source/media/sd/sd_multi_reader.v` | 快速读取引擎：CMD16/17/18 + CRC16 硬件校验 + 两相位时钟（命令 6.25 MHz / 数据 25 MHz）+ 速度探测与回退 + 字节直推流输出（无 FIFO） |
| RTL（改写） | `media/sd/sd_stream_reader.v` | 双引擎仲裁：原厂控制器（零改动）+ 快速引擎，引脚/字节流 mux，FORCE_LEGACY 回归开关 |
| RTL（微改） | `media/sd/yingxu_sd_integration_probe.v` | 透传 dbg_fast_* 观测口（其余零改动） |
| 测试台（新增） | `tb/tb_sd_multi.v` | SPI 模式 SD 卡行为模型（init 400 kHz 纪律检测、N_CR/N_AC/N_EC 时序、实时 CRC16、CMD18 连发、CS 沿重同步、+crcerr/+throttle 故障注入）+ 逐字节校验器 |
| 工具 | `tools/_vcd_bits*.py`、`_probe_rx2.py` 等 | VCD 位级取证脚本（本次排障用，保留） |

## 2. 仿真结果

### 主验证（16 扇区 CMD18@25 MHz 多块连读）

```
RESULT-INIT:  PASS（init 全程 ≤400 kHz，零违规）
RESULT-FAST:  PASS（fast_ok=1, broken=0）
RESULT-DATA1: PASS（8192 字节，0 错误，16/16 CRC 逐块全对）
吞吐：纯数据相位 ≈ 3.05 MB/s（理论极限 3.125 @ 25 MHz SPI）
```

### 回退验证

```
RESULT-DATA3: PASS（8 扇区经 CORE 回退路径）
RESULT-DATA4: PASS（5 扇区经 CORE 回退路径）
TB-SUMMARY:   ALL PASS（bytes_checked=14848）
```

### 已知限制

req2（单扇区紧跟 req1 后）的 R1 扫描超时——请求间隔的 CS 时序间隙导致模型响应
未及时到达。安全降级：broken=1 粘滞 → 后续请求走原厂路径（已验证 PASS）。
不影响主用例（16 扇区连读是视频流的标准访问模式）。

## 3. 关键发现与修复

### RTL 侧根因（历史 25 MHz 失败）

厂商 `sd_card_control` 的 `clk_div_var` 以 `one_allow=0` 实例化——div=1 时 SCLK **恒为低**。
当年板上 25 MHz 失败极可能根本不是卡的问题，而是分频器把时钟冻死了。
快速引擎用独立分频器（one_allow=1）绕开。

### 本轮修掉的 bug（VCD 位级取证定位）

| # | bug | 修复 |
|---|---|---|
| 1 | spi_done 在 div>1 下被拉宽为多周期电平，FSM 未做边沿检测 → 同一字节计数 4 次 → 假 probe_fail | 加 spi_done_p 边沿检测脉冲 |
| 2 | 命令字节索引与驱动器重装沿相位差 → 首字节双发/末字节丢失 | 复刻厂商 ce 门控计数相位 |
| 3 | 三处 44 位拼接零填充吞掉命令首字节（0x52→0x05） | 加 4'b0000 填充到 48 位 |
| 4 | 探针流程漏发 CMD17（S_CS_UP 直接跳 CMD18） | S_CS_UP 按 next_cmd 分发 CMD17/CMD18 |
| 5 | FIFO 状态（wp/rp/level）复位丢失（删引擎块时误删） | 复位并入 FSM 块 |
| 6 | wire 前向引用绑到死隐式 wire（iverilog 特性） | fpush/fpop 声明移至 out_active 之后，后改内联 |
| 7 | out_active 在 CRC 通过时才设 1，但探测块 512 字节已在 S_DATA 排水 → out_cnt=512 但检查器看不到 | out_active 提前到 S_TOKEN 找到 FE 时设 1 |
| 8 | FIFO 跨块竞态（level/mem/引擎三块分写）→ we=1 而记账不动 → 流输出 0 字节 | **删除 FIFO，改为 byte_pending 单字节直推** |

### 测试台自身 bug（已修）

| bug | 修复 |
|---|---|
| 命令收集的移位丢首字节（cmd_acc[39:0] 拼接丢 [47:40]） | 改为按槽位直写 |
| 校验器 idx 未取扇区内模 | exp_idx % 512 |

## 4. 档位覆盖

| 档位 | 全帧码率 | 差分后 | 12.5 MHz（1.3 MB/s） | 25 MHz（2.8 MB/s） |
|---|---|---|---|---|
| 720p@24 VQ-1024（主档） | 2.76 | ~1.0 | ✓ | ✓ |
| 720p@30 VQ-256 | 1.73 | ~0.7 | ✓ | ✓ |
| 720p@60 VQ-256 | 3.46 | ~1.6 | ✗ | ✓ |
| 1080p@24 VQ-256 | 3.11 | ~1.1 | ✓ 边缘 | ✓ |
| 1080p@24 VQ-1024 | 6.22 | ~2.6 | ✗ | ✓ |

## 5. 排障过程记录

VCD 位级取证证明厂商 CMD 流在线上完美（排除滑移/双发初期误判）。
测试台自身两处 bug 已修（命令收集丢首字节、校验器 idx 未取模）。
FIFO 删除后改为字节直推 + 字节边界暂停，消除了整个 FIFO 记账竞态类。
