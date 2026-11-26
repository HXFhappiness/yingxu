# 2026-10-29 下午：WAV 音乐播放器打通（六个真 bug）

> 接 `HANDOFF_20261029.md`（早晨）与 `HANDOFF_20261029_NOON.md`（中午，当时音频无声）。
> 本文记录下午把"音乐播放"从"完全无声"做到"能听出旋律 + 自动循环"的全过程。

---

## 结果

- **固件 build_g16**（`out/bitstream_backup/build_g16_hs.bit`），已烧板
- 音乐模式：**SW7 ON + SW4 ON + SW5 OFF + SW6 OFF**（纯音乐，不与游戏抢 SD）
- 实测：8 音一循环的 C 大调琶音，音量稳定，10 秒一轮自动重播（用户确认"8 个声调一周期"）
- 游戏音效代码已改（breakout 撞砖有声、invaders 开火不响/击中有声），卡带已重写

---

## 六个真 bug（按发现顺序，全部有实锤）

| # | bug | 证据 | 修法 |
|---|-----|------|------|
| 1 | FIFO 写数据线 `wdata` 从未赋值（浮空 z） | 仿真 `wav_l = z`，24000 次弹出全未驱动 | `assign wdata = fifo_wr_d` |
| 2 | PSG 空闲输出恒定 `0xE00000`（-0.25 FS 直流） | 录音零交叉=0、均值 -8234 | 加 `psg_on` 门控，空闲真静音 |
| 3 | **格雷码解码混用新旧位**（同一 always 里 `rdec[k+1]` 是上一拍值） | `occ` 算错 → 背压永不触发 → FIFO 被覆盖 | 改为组合式前缀异或链 |
| 4 | **字节按拍计数，未用握手**（探针 `stream_valid` 在等 ready 时保持高电平） | 同一字节被计几十次 → 重复数据（杂音）+ `pcm_left` 飞速归零 | 只消费 `valid && ready` 的拍 |
| 5 | 头部要求"第一字节就是 YXMA" | 循环重启/残留字节 → 误判非法头 → S_DONE 静音 | 4 字节滑动窗口同步 |
| 6 | `start_sector` mux 用 `music_sw4 & game_mode`，而使能还要求 SW5/SW6 OFF | 可能"探针读音乐数据但播放器不工作" | 统一成 `music_on_w` |

### 附带修的测试台 bug
TB 的字节源在 `ready` 为低时仍然前进指针 → 丢 19% 字节，导致仿真假失败。
改为持有当前字节、只在握手成功时前进。**测试台也必须遵守握手语义**。

---

## 设计要点（已实现）

```
SD 探针 (5401 扇区/次 restart)
   │ byte stream (sys_clk)，valid 在等 ready 时保持高
   ▼
[yingxu_wav_player]
   ├─ 4 字节滑窗同步 'YXMA' → 解析 ch/rate/frames/pcm_bytes
   ├─ 16bit L/R 打包 → 32bit {L,R} 写入异步 FIFO
   ├─ FIFO: ram_dual_port_simple 32×1024，格雷码指针双向同步
   ├─ 背压: occ = wptr - rdec ≥ 768 → sd_ready=0（探针暂停）
   ├─ 消费: PSG 的 48kHz valid 为节拍，按文件 rate 分数消费
   ├─ 16→24bit ×128（-6dB，给混音留余量）
   └─ 播完自动从头循环（S_DONE 只留给非法头）
```

- 顶层：`O_bmp_sd_ready = music_on_w ? wav_sd_ready : bmp_sd_ready`
- 混音：`A_left = sat(psg + wav)`（24bit 饱和），photo 模式仍走 I2S 直通
- 诊断设施（可保留）：无弹出连续 5 拍时输出状态直流
  （0x080000=S_HDR / 0x180000=PLAY无样本 / 0x280000=<256 / 0x380000=>=256 / 0x480000=S_DONE）

---

## 已知瑕疵

**循环接缝有 ~1.5 秒静音**：歌曲播完 → 重新触发探针从文件头读 → FIFO 排空。
演示用长曲（3 分钟）时只出现一次，影响小。彻底消除需预取/双缓冲，成本高，暂不做。

---

## 追加（当晚，g17–g19）：音效映射 + 两个 bug + 一次自造回归

### 最终固件：build_g19（`out/bitstream_backup/build_g19_declfix.bit`）
**板上验收：音乐、卡带打砖块、卡带流浪者、硬件流浪者全部正常**（用户确认）。

### 音效映射（PSG 码 → 事件）

| 码 | 事件 | 音高 | 用时 |
|---|---|---|---|
| 1 | 撞挡板 | 440 Hz | breakout 挡板 |
| 2 | 失球 / 失命 | 220 Hz | |
| 3 | 通关 / game over | 1320 Hz | |
| **4** | **击打（新增）** | **880 Hz** | 撞砖、击落敌机 |

- SOC 原来只按 `cpu_dwdata[1:0]` 译码（只有 0–3），码 0 被忽略 → 撞砖/击落原本写 0 因此无声
- 改为整字节译码并新增码 4；卡带 asm 相应改为码 4；invaders 开火去掉 PSG 写入（按要求静音）

### 硬件流浪者"虚空子弹"（已修）

```verilog
if (emask[{2'b00, fc0}] && ...)   // fc 是 2 位(0..3)，但每排只有 2 架
```
`emask` 初始 `0x03F`（bit0–5 有效）→ **bit2/bit3 也是 1**，轮到列 2/3 时条件成立，
而开火坐标用 `fc[0]`(=0) → 子弹出现在已空的第 0 列。
修法：索引改 `{row, fc[0]}`（6 处）。

### 自造回归（g17 引入，g19 修复）——教训

我把音乐使能提成一根 wire `music_on_w`，却放在 `sw6_sync` 声明之前：
Verilog 将其视为 **1 位隐式线网**，`sw6_sync[1]` 越界取 0 → **music_en 恒 0**
→ 音乐、start_sector mux 全失效（表现为"什么声音都没了"）。

**规则**：在 `hardware_test` 里，任何引用 `sw5_s/sw6_sync/sw4_s` 的新 wire
都必须写在那些 reg 声明**之后**；或者干脆把声明提前到文件顶部。
本文件已把 `sw6_sync` 提前到第 113 行。

### 可听诊断（保留，很实用）

music 模式下若**完全没有数据**，播放器输出 **1kHz 方波**（"嘀——"）；有数据则正常播放。
用它一刀切开"音频通路坏"还是"SD 数据没来"。

---

---

## 验证手段（可复用）

```powershell
# 录 HDMI 音频（Python 调用，避免中文设备名引号问题）
python tools\rec_audio.py out\rec.wav 20

# 时间线分析：每 0.5s 的 rms + 零交叉 + 主频 → 一眼看出"放没放/什么音"
python tools\analyze_timeline.py out\rec.wav 0.5

# 段内细看（0.1s 窗）
python tools\analyze_seg.py out\rec.wav 12.3 14.2
```

**采集卡铁律**：`ffmpeg` 录音**绝不可中途强杀**——UVC 设备会卡死、Windows 会禁用该 USB 口
（症状：`无法识别的 USB 设备(配置描述符请求失败)`，需换口或重启电脑）。
一律用 `-t <秒数>` 让它自然结束。

---

## 下一步

1. **回归**：卡带两游戏 + 硬件流浪者的画面与音效（PSG 行为改过）
2. 菜单 UI（方案见 `AUDIO_PLAN_20261028.md` §5）
3. 11.1 录演示 / 11.2 冻结
