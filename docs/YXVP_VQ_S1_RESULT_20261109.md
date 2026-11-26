# YX-VP-VQ 解码核 S1 仿真验收（2026-11-09）

> 约束：初赛已结束，全部工作只做仿真验证，不烧录。仿真通过即验收。
> 板 B（GS）专用模块：独立文件，未进 A 板顶层与构建列表。

## 1. 交付物

| 文件 | 内容 |
|---|---|
| `src/user_source/hdl_source/media/vp/yx_vp_vq.v` | YX-VP-VQ v1 解码核：YXV2 格式（KEY/DELTA 差分帧），字节流入口 + 光栅像素写口 |
| `tb/tb_yxvp_vq.v` | 对拍测试台：喂真实 .yxv2 帧载荷，逐帧与 Python 参考解码比对 |
| `tools/vq_decode_delta.py --dump` | 码本 hex + 大端 RGB565 参考帧导出（对拍基准） |
| `tools/vq_encode_delta.py` | 编码器补 nframe 头部回写 |

## 2. 验收结果（与 vq_decode_delta.py 逐位对拍）

| 测试 | 几何 | 码本 | 结果 |
|---|---|---|---|
| 小几何回归 | 256×144（2304 块） | VQ-1024（IDXB=2） | **40/40 帧 ALL PASS**（3 KEY + 37 DELTA，397,159 clk，39,524B 流全消费） |
| 小几何回归 | 256×144 | VQ-256（IDXB=1） | **40/40 帧 ALL PASS**（350,545 clk，23,576B） |
| 720p 真实几何 | 1280×720（57,600 块） | VQ-1024 | **5/5 帧 ALL PASS**（2 KEY + 3 DELTA，每帧 921,600 像素逐位一致，2,751,979 clk） |
| 1080p 容量上限 | 1920×1080（129,600 块） | VQ-256 | **5/5 帧 ALL PASS**（每帧 2,073,600 像素逐位一致，5,862,031 clk，319,855B） |

判定标准：每帧 frame_done 后 TB 侧 fbuf 与 Python 参考（RGB565 光栅）逐像素 !== 比较，零 mismatch；流字节计数必须恰好等于载荷长度。
（以上结果均为 5B 帧头 u24 格式终版；格式变更后四组全部重跑。）

## 3. 时序数据（与设计预算对照）

- 实测 720p：2 KEY 帧 + 3 DELTA 帧 = 2.75M clk → KEY 帧实测 ≈ 1.04M clk（57,600 块 × 18 clk/块），与设计值一致。
- 实测 1080p：2 KEY + 3 DELTA = 5.86M clk → KEY 帧实测 ≈ 2.33M clk（129,600 块 × 18），与设计值一致。
- 帧预算 73.33 MHz @ 24 fps = 3.06M clk/帧 → 720p KEY 帧 1.04M（34% 占用）✓；1080p KEY 帧 2.33M（76%）✓ 仍在预算内。
- DELTA 帧开销：bitmap 288B/16.2KB 收图 + 走查 1 clk/未变块 + ~21 clk/变化块，典型内容余量更大。

## 4. 本轮修掉的 bug（自检自纠记录）

| # | bug | 修复 |
|---|---|---|
| 1 | 查表流水相位错：发射滞后发起 2 拍而非 1 拍（首像素双发、末像素丢失） | S_PRE 发首读 + p 计数重构，发射 qe = p-2 |
| 2 | S_PRE 初始化 p=1 → p==17 收块条件永不可达，FSM 卡死 S_RUN | S_PRE 置 p=0，S_RUN 增加 p==16 等待拍 |
| 3 | DELTA 帧最后一块恰为变化块时死循环（走查不推进块号） | 收块后统一推进块号/位置并查帧尾（与 KEY 一致） |
| 4 | S_HDR3 用 rsv 字节 bit0 分发 kind（rsv 恒 0 → 全部按 KEY 处理） | 改用 S_HDR0 锁存的 kind_r |
| 5 | 编码器 nframe 字段硬编码 0（流式编码先写头） | 编码完成后 seek 回写；存量文件就地补丁 |
| 6 | TB 比较竞态：frame_done 同边沿的末像素 NBA 写未落地即阻塞读 | 比较延后 1 拍 |
| 7 | 帧头 changed 为 u16：1080p 单帧 129,600 块溢出（编码器 struct.error 暴露） | **格式升级为 5B 帧头（kind u8 + changed u24 LE + rsv u8）**，编码器/解码器/RTL 同步修改后四组几何全部重跑 |
| 8 | 新增 S_HDR4 后 want_byte 漏加 → 第 5 个帧头字节永远等不到握手，FSM 停在 S_HDR4（TB 显示 sent=4/state=4） | want_byte 加入 S_HDR4；教训：**新增收流状态必须同步查 want_byte 清单** |

## 5. 工具链发现（非 RTL 问题，记录备查）

- **iverilog 编译器挂死 bug**：`always @(*)` 中对大数组做变量索引读（`sd = smem[soff+sent]`，4MB 数组）→ iverilog 编译阶段死循环（进程驻留、内存 ~3MB 不增长）。规避：字节流生产者改为纯寄存器逻辑（cur_valid/cur_byte 握手推进）。此后 TB 禁用 @* 数组读。
- `$fseek` 按任务调用返回值被忽略（无害告警，改为函数式调用消除）。

## 6. 与解码设计的对照确认

- bitmap 字节内 MSB-first → 块 8m+i：RTL `S_MAP` 直写 8 位与 Python `bits[i::8] = (mapb >> (7-i)) & 1` 一致（对拍证明）。
- 索引小端组装（IDXB=2：低字节在前）：RTL ilo 先收、高位字节后拼 ✓。
- 光栅块序推进 + 块内行主序像素地址（bybase + (qe>>2)*W + bx*4 + (qe&3)）：720p 逐位对拍证明正确。
- 帧间保持：DELTA 未变化块不写帧缓冲，TB fbuf 跨帧保留 ✓（对拍证明）。

## 7. 下一步（S2，后续轮次）

- 码本运行时装载（寄存器/SDRAM 路径）替代仿真 $readmemh；
- 帧缓冲接 SDRAM 三缓冲 + 帧提交协议；
- 与 SD 快速引擎（YXSD v2）对接：stream_valid/byte_pending 握手已在本次 RTL 中遵循；
- 板 B 顶层集成（不进 A 板）。
