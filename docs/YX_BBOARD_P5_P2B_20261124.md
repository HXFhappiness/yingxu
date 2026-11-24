# YX_BBOARD_P5_P2B_20261124 — P2b：位图走查进 32Kb 原语，LUT 20.4%、WNS −215ps

> 承接 `YX_BBOARD_P5_P0P1_20261124.md`（P0/P1 修完后 LUT 61.9%、WNS −1031 ps，
> 剩余 1,033 条违例全部来自 `u_ixdec/map_ram`）。本轮清掉该模块族，
> 并顺带把以太网 FIFO 的几处组合长路径按"格雷码可直接判定"重构。
> 未生成 bit、未烧录（初赛已结束，只做仿真 + 综合）。

## 1. 结果

| 指标 | 首次综合 | P0/P1 后 | **P2b 后** |
|---|---:|---:|---:|
| `#lut` | 48,777 (248.86%) | 12,127 (61.87%) | **3,999 (20.40%)** |
| slices | 18,158 (185.29%) | 3,734 (38.10%) | **644 (6.57%)** |
| `#bram` | 45/64 | 53/64 | 53/64 |
| `#bram32k` | 0/16 | 8/16 | **10/16** |
| Setup WNS | −2,652 ps | −1,031 ps | **−215 ps** |
| 违例端点 | 3,095 | 1,033 | **4** |
| Setup TNS | −7,797,502 ps | −1,056,521 ps | **−386 ps** |

| 实例 | 模块 | 首次 | P0/P1 后 | **P2b 后** | BRAM |
|---|---|---:|---:|---:|---:|
| `u_band` | `yx_vp_band` | 20,474 | 194 | **193** | 38 |
| `u_bfifo` | `yx_b_afifo` | 15,710 | 102 | **102** | 8 |
| `u_ixdec` | `yx_vp_ixdec` | 8,249 | 8,249 | **157** | 2 |
| `u_sdram` | `Sdram_Control_4Port_B` | 627 | 618 | 660 | 7 |
| `u_hdmi_core` | 加密核 | 849 | 849 | 849 | 8 |

## 2. `map_ram`：57,600×1bit 位图 → 8bit/字 32Kb 原语

原实现是"已变更块位图" `reg map_ram [0:NB-1]`（NB=57,600），
**组合读**（`if (map_ram[blk])` 同拍决策）→ TD 只能建在 LUT 里，
`u_ixdec` 8,249 LUT，并成为全设计唯一时序违例族：
`u_ethrx/rem_reg → u_ixdec/map_ram_syn_*.e[0]`，slack −1,031 ps，1,024 条端点。

改造（三条一起做，缺一不可）：

1. **位打包**：1 bit/块 → 8 bit/字（每字 8 个块，块 `8m+i` ↔ 字节 `m` 的 `bit(7-i)`）；
   7200 字 → 8192 深度 → 2 块 32Kb（`bram32k` 余量充足）。
   写入从"8 次单 bit 写"变成"1 次整字节写"，`S_MAP` 直接
   `u_map.dia = stream_data`、`wea = (state==S_MAP) && get`。
2. **原语化**：显式例化 `EG_LOGIC_BRAM(IMPLEMENT="32K")`（与 `ln32` 同一手法）。
   推断路径拿不到 32Kb 池，必须显式例化。
3. **两拍走查**：BRAM 读必然 1 拍延迟，于是把走查拆成
   `S_WALKR`（呈现地址、等数据）→ `S_WALK`（用数据决策）：

```verilog
S_WALKR: state <= S_WALK;                 // 读拍：blk 不动，dob 在下一拍对应 blk
S_WALK: begin
    if (map_bite) begin
        if (q_room) begin bcnt <= 0; state <= S_DIDX; end   // 命中 → 取索引
        // 无空位原地等：blk 不变 → dob 不变 → 决策不变（无需额外锁存）
    end else begin
        if (blk == NB-1) state <= S_FD;
        else begin blk <= blk + 1; state <= S_WALKR; end
    end
end
```

> 为什么"两拍"是最省事的正确解：`blk` 在两拍内保持不变，`dob` 天然对应 `blk`；
> 且 `q_room` 不足停顿拍地址也不变、数据保持，不需要额外的命中锁存。
> 代价只是走查 2 拍/块 —— 57,600 块 ≈ 115,200 拍 ≈ **1.15 ms/帧**（仅 DELTA 帧），
> 720p 帧预算 33 ms 下可忽略。

## 3. 以太网 FIFO：三处组合长路径按"格雷码可直接判定"重构

`yx_b_afifo` 的占用判定原来全部走 `g2b`（格雷→二进制，PT−1 级串行 XOR）
+ 减法 + 比较。**格雷码是双射**，占用的三个用法都能直接判定：

| 原式 | 等价格雷判定 | 说明 |
|---|---|---|
| `occ == 0` | `wgray_r2 == rgray` | 空 ⟺ 两指针格雷相等 |
| `occ != 0` | `wgray_r2 != rgray` | |
| `occ > 1` | `wgray_r2 != rgray_nxt` | 弹出一个后仍非空 |
| `occ == DEPTH`（full） | `wgray == {~rgray_w2[PT-1:PT-2], rgray_w2[PT-3:0]}` | 经典 Cummings 判定 |

于是**读侧彻底不需要 g2b**（−198 ps 那条消失），写侧只剩 `wr_occ`（软节流用）
一处需要数值占用，改成**两级流水**：

```verilog
rbin_whi <= g2b_hi(rgray_w2);                                   // 高半段（7 位）
g_lo_q   <= rgray_w2[PH-1:0];                                   // 同拍低半快照
rbin_w_q <= {rbin_whi, g2b_lo(g_lo_q, rbin_whi[PH])};           // 低半段配种
```

低半段用"上一拍高半结果 + 同一拍的格雷低半快照"配种，拼接自洽；
占用估算多滞后 1 拍 → 更保守（full 更早），方向安全。

另外去掉了 `stream_valid`/`byte_pop` 里的 `rem != 15'd0` —— 它在
`S_SEND`/`S_DROP` 状态里**恒为真**（进态 rem ≥ 1，递减到 1 的那一拍同时转回
`S_IDLE`），保留只会把 15 位计数器串进
`rem → stream_valid → u_ixdec/state` 这条跨模块长路径（−463 ps）。

## 4. TD 的两个坑（都会直接让综合崩）

1. **函数内局部 `reg` 的位宽推断有 bug**：把 `g2b` 写成平衡前缀树后，
   TD 报 `HDL-8007 index 4 is out of range [3:0] for 'b'`
   + `part-select direction is opposite from prefix index direction`，
   并把整模块判成黑盒 → `PRJ-8806 Run syn_1 has exited unexpectedly`。
   **结论：g2b 保持串行 `for` 循环写法**（TD 稳定），用流水而不是改结构来提速。
2. **隐式声明会先建 1 位网线**：`u_ln32` 例化里用了 `ln_we_r/ln_wa_r/ln_wd_r`，
   而 `reg` 声明在其后 → TD 报 `HDL-7225 'ln_xxx' is already implicitly declared`。
   TD 继续跑但网线位宽可能被按 1 位处理，**reg/wire 必须先声明再在例化里引用**。

## 5. 剩余 4 条违例（−215 ps）

| slack | 路径 | 性质 |
|---:|---|---|
| −215 ps | `u_ethrx/st_reg[1] → u_ixdec/state_reg[0]` | 跨模块组合路径，**net 占 65%**（gate 阶段布线估算）；已试过在边界加寄存器，会破坏 FWFT 对齐（需 skid 缓冲），留待 P&R 评估 |
| −116 ps | `u_mac/ip_header_check_ok` | 厂商 `eth_udp_rx_gmii`/`ip_checksum`，**A 板共用代码**，不动 |
| −28 ps | `u_mac/ip_checksum/suma_reg[18]` | 同上 |
| −27 ps | `u_mac/ip_checksum/suma_reg[...]` | 同上 |

判断：−215 ps 是 gate 阶段（placement 前）的线载估算，net 占 65% 属典型悲观值；
P&R 后大概率收敛。若仍需强制清零，正解是在 `hdr_parse → ixdec` 边界插一级
register slice（skid），但那会把 `ready` 反向路径加一级，存在"打地鼠"风险，
故本轮不做。

## 6. 验证

见 `YX_BBOARD_P5_P0P1_20261124.md` §6 的门禁口径（两入口判据独立）。
本轮改动涉及 DELTA 走查、以太网字节 FIFO 占用判定、流握手，**必须两入口都过**：
- `bboard_key`（合成 KEY-only 码流）：走不到 `S_MAP`/`S_WALK`，主要覆盖 FIFO 与扫描路径；
- `bboard_sys`（真实 720p×5 帧，含 DELTA）：**唯一覆盖新走查逻辑的入口**。

> 注意：`tb_yxvp_ixpipe.v`（P1/P2 时期的独立回归）也例化了 `yx_vp_ixdec`，
> 现在编译它**必须带上** `tb/bshims/EG_LOGIC_BRAM.v`（以及 `EG_LOGIC_FIFO.v`），
> 否则 `u_map`/`u_ln32` 例化无定义。

## 7. 复现

```powershell
cd C:\Users\HXF\Desktop\YX
powershell -NoProfile -ExecutionPolicy Bypass -File tools\sim\run_sim.ps1 -Entry bboard_key
powershell -NoProfile -ExecutionPolicy Bypass -File tools\sim\run_sim.ps1 -Entry bboard_sys

cd D:\yingxu-repo
"D:\Anlogic\TD_Release_2026.2.210.850\bin\td_commands_prompt.exe" "C:/…/run_b_syn.tcl"
```

## 8. 说明与局限

- gate（综合后）数字，非 place/route；未跑 `phy_1`、未 `save_best_bits`，
  **未产生 bit、未烧录**。
- `bram32k` 已用 10/16（`ln32` 8 + `map` 2），后续加窗口/更多缓冲仍有 6 块余量。
- LUT 余量 79.6%，为后续功能（超分、更多窗口、DELTA 增强）留足空间。
