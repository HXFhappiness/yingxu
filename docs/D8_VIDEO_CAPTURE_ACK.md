# D8：DD3000 写命令失配与接收确认

板测来源：统一版 `d0d12ca`；`MISE=949F / ACC=020 / I1=DD3000`。

## 现场解码

| I1 位 | 值 | 含义 |
| --- | --- | --- |
| 23 | 1 | 扩展写事务快照 |
| 22:20 | 101 | 内层 active，owner=1，loader |
| 19:17 | 110 | 外层 active，owner=2，other/loader |
| 16 | 1 | 这一笔已重提交一次 |
| 15 | 0 | loader command ready=0 |
| 14 | 0 | 外部 command valid=0 |
| 13 | 1 | 外部 command ready=1 |
| 12 | 1 | 外部 write valid=1 |
| 11 | 0 | 外部 write ready=0 |
| 10:7 | 0 | loader.sent=0 |
| 6:4 | 0 | 物理口 IDLE |
| 3:0 | 0 | 物理 position=0 |

上游已把命令当成接收成功，物理口仍空闲，首字尚未送出；不是物理 WAIT
等授权，也不是 TRANSFER 等 done。bit16 表明一次重提交仍失败。
`ACC=020` 是 PCM 当前请求的 **32 字节**（首批 8 字），不是 512 字节。
OFF 是保留的首次 LBA；DNE 在 PCM 请求起始即清零，LS=6 则是超时后
abort 持续复位 SD 的结果。SD 初始化/读请求语义沿用原调查结论。

旧版 `python3 tools/yxv_preload_verify.py --fast-card --block 7` 可通过持续
屏蔽物理 command valid，完整复现现场 DD3000/949F/ACC020。
原始日志在 `evidence/D8_VIDEO/baseline_dd3000.log`；旧测试需在 `d0d12ca`
的独立检出执行。该注入证明失配机制，**不证明板上为何发生漏收**；板上
具体触发因素（包括实现时序）仍待新位流验证，不能把功能仿真当成板上根因证明。

## 修复

物理 burst adapter 增加 `ACCEPT=5`：

1. IDLE 时 valid 到达，先锁存原有 address/length/write/校验结果寄存器。
2. 下一完整 MEM 周期才拉高 command ready，确认命令已经在接收端保存。
3. 确认拍后用锁存字段进入 COLLECT（写）/WAIT（读），非法命令发 done/error。

IDLE 不再发布“可以接收”作为上游完成接收的依据；valid 没到物理口时，上游
继续持有命令，不能抢先进入送数。确认拍 valid 被屏蔽也不会丢弃已锁存的命令。
没有扩大重试次数、伪造 done、复位 SD 或修改菜单参与仲裁。

状态 0..4 和原 I1 低 11 位编码保持不变；新增 5 表示命令已锁存、正在确认。
MISE 仍是阶段+错误码。旧一次重提交保护参数保留兼容，但新握手正常运行及
各漏 valid 测试均为零重提交。每笔增加一个命令锁存周期，不增加数据缓冲。

## 验证

- `python3 tools/port_capture_ack_verify.py`：对生产 adapter 归纳证明，允许
  任意 valid 屏蔽、复位、enable、载荷与物理响应，证明确认前已保存命令，
  且确认后按锁存字段进入正确状态/错误路径。
- `python3 tools/yxv_d3_units.py`：物理口 1..8 字写读、末地址/非法命令、
  写尾掩码、背压、loader/512 帧、scanout、PCM 通过。
- `python3 tools/yxv_preload_verify.py --fast-card --block 8`：首笔命令屏蔽
  三周期，完整 486 帧/7594 扇区 PCM，121504 bursts / 972032 words 零差异。
- 同一程序 `--no-build --block 9`：确认拍屏蔽 valid，完整 PCM 零差异。
- 同一程序 `--no-build --block 10`：每笔 PCM 命令都屏蔽前三周期，完整
  PCM 零差异。以上三组无重提交、无 SD reset、初始化仅一次。
- block 1..6：送数/等授权/等 done 各类真阻塞仍有限超时并保存原诊断。
  block 7 永久无 valid 时停留在命令等待 `929F`，不再伪装成已接受的 `949F`。

快卡只加速事务模型；保留实际 reader、pipeline、双层仲裁和四口物理服务。
没有提供引脚/电气或 TD 时序结论。最终顶层播放和统一构建记录见 D8 总交付。
