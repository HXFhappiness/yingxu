# 映序 B 板 — YX2 会话交接（2026-11-11）

> 用途：替代原 YX2 会话（上下文已达 28 万 token，每轮请求 1.1MB，网关频繁超时/断流）。
> 新会话从这里开始，上下文约 5k，请求体积降到 ~50KB。

---

## 1. 项目与约束

- 工程根：`C:\Users\HXF\Desktop\YX`
- 本阶段只做仿真，**不烧录、不生成 bit 流**
- VQ / B 板功能不能混入 A 板顶层；本地修改不推送 GitHub
- 仿真退出码 0 ≠ 通过，必须以 GATE 行为准
- 中文回答

---

## 2. 当前状态（一句话）

**管线已全线流通**（dec=5、frames=5、bands=900、stall2=0），**但数据全链为 X**：WR2 从未推入 → 索引区从未写入 → 下游全部 X → golden 全错。

```
GATE dec_frames=5(OK) frames_done=5(OK) bands=900(OK)
     golden=2304000(BAD) scan=0 disp=0(OK) xz=0(OK) mem=0/0(want >0:BAD)
```

---

## 3. 已完成的修复（有日志证据）

| 轮 | 文件 | 改动 | 效果 |
|---|---|---|---|
| R2 | `yingxu_vq_board_top.v:302,305` | `2'd4` → `3'd4` | 状态机越界回绕修复；bands 0→900、frames 0→5 |
| R3 | `Sdram_Control_4Port.v`（仲裁）/ `top:219` / `yx_b_ix_seq_wr.v:52` | rd1_turn 轮换 + wr2_full 接线 + 背压 | dec 3→5，WR2 卡死解除 |
| R4 | `tools/sim/run_sim.ps1` | 增加 `bboard_key` 入口 | 金标与码流正确配对 |
| R5-R6 | `tb/tb_yxvp_bboard.v` | MEMCHK / GSAMPLE / SDCMD 探针 | 定位 X 注入段 |

**stall2：97% → 0%**。原"最后一个吞吐 bug"已解决。

---

## 4. 当前唯一卡点

### 事实（原始数据）

| 推入源 | 推入次数 | 其中 X | 真值 |
|---|---|---|---|
| WR1 ← 扫描器 `sc_wdata` | 2,304,000 | 2,304,000（100%） | 0 |
| **WR2 ← `u_ixwr`** | **0** | 0 | 0 |

| 区域 | 写命令 | mem 非 X 字 |
|---|---|---|
| 索引区 | **0** | **0 / 115,200** |
| 帧区 | 9000 | 0 / 460,800 |

- `SDCMD act=27748 wr=9000 rd=18748 pre=1 ref=7348` —— 写命令节奏正确（9000 = 900 带 × 10 突发 × 256 字 = 2,304,000）
- `MEMCHK idx_nonX=0/115200 fb_nonX=0/460800` —— SDRAM 里没有一个真实字
- `BOOK[0..7]=0..7`、`PATCH blk=0..7 idx=0,11,...,77` —— 解码/码本/补丁路径**是真值**，前端无罪

### 因果链

```
WR2 从未推入  →  索引区空  →  fetch 读出 X  →  band 行缓冲 X
                                              ↓
                          golden 全错  ←  fb 全 X  ←  扫描器推入 100% X
```

### 已排除

- **H2（FIFO shim 弹出 X）**：write_fifo1 pops 2,304,000 全 X，但**推入侧同样 100% X**，FIFO 无罪
- **H1 的简化版**：不是"取带读到 X 后污染"，因为索引区压根没写过

### 为什么原来的 X/Z 检查抓不到

`xz` 只查 8 个**控制面寄存器**（恒为非 X）；X 在**数据存储面**（SDRAM mem、band 行缓冲）传播；且 golden 用 `!==` 比较，`X === X` 被判"相等"。现有 GATE 已加 `mem` 项（idx/fb 非 X 字数）。

---

## 5. 下一步（按顺序）

1. **查 `u_ixwr` 为什么 0 推入**
   - 采样入口：valid/ready/full、empty、state、load
   - 重点验证：**首窗初始化 LOAD 到底有没有发过**（load 脉冲计数 + 置位条件）
   - 若 full 常高，追 `wr2_full` 来源与是否常高
2. **修 WRWIN 探针缺陷**：命令拍锁存窗口、数据拍不清零（现在被 else 分支清零，beats=0）
3. **golden 改成 X 敏感比较**：先判 `^val === 1'bx` 计入 `x_compare_errs`，再比数值，并纳入 GATE

---

## 6. 工具与命令

```powershell
# 统一仿真入口（含编译门禁，编译失败不跑 vvp）
powershell -ExecutionPolicy Bypass -File tools\sim\run_sim.ps1 bboard_key
powershell -ExecutionPolicy Bypass -File tools\sim\run_sim.ps1 sdctrl_sanity
```

- 输出：`out\sim\<entry>_<时间戳>.vvp / _compile.log / _sim.log`
- 日志末尾有 `[时间] VERDICT: ...` 可追溯
- **不要再用**历史上的 `iverilog ... | findstr ... & echo OK & vvp ...` 一笔式命令（编译失败仍会跑旧 vvp）

---

## 7. 工作纪律（沿用）

1. 每轮回复以 **GATE 行原文** 开头，不许只写 PASS/FAIL
2. 禁止修改 PASS 判据/阈值/宏来让测试变绿；判据只能收紧
3. 禁止删除/覆盖历史日志；每次运行必须产生新时间戳文件
4. 连续 2 次编译失败或同一指标 3 轮无变化 → 停车报告，不许乱改
5. 改完必须贴编译退出码 + 仿真关键计数
6. 不要复述身份/日期/系统提醒
