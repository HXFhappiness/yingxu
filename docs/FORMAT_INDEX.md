# FORMAT_INDEX — 映序的两种视频容器格式（别读错文档）

> 建立原因：仓库里同时存在 `YXV v1`（MJPEG）与 `YXV2`（VQ）两套规范，
> 而**当前架构只用后者**。2026-11 有会话因为先读到 MJPEG 文档，把"目标帧率"
> 和"视频实现路径"都判断错了（详情见 §3）。本文是唯一入口，先看这张表再翻细节。

## 1. 一句话区分

| | **YXV v1** | **YXV2** |
|---|---|---|
| 编码 | MJPEG（ffmpeg）+ PCM 48 kHz | **VQ**（码本 1024×4×4 块 + KEY/DELTA 帧） |
| 生成工具 | `tools/video2yxv.py` | `tools/vq_encode_stream.py`（+ `vq_encode_delta.py`） |
| 参考解码 | `tools/vq_decode*.py`（仅 YXV2 有） | 同左 |
| 消费方 | 板 A RTL 解码器 —— **从未实现** | 板 B `yx_vp_ixdec`/`yx_vp_ixbuf`/`yx_vp_band` + HDMI |
| 运行架构 | 单板（板 A 自己解码 + 自己显示） | **双板（算画分开）**：板 A 推流 → 板 B 解码出图 |
| 状态 | **已废弃**（当前架构不用） | **在用**，720p60 实时，五入口门禁全绿 |
| 规范文档 | `docs/YXV_FORMAT.md` | `docs/YXVP_VQ_DESIGN.md` |

**结论：要做视频，一律看 YXV2。`docs/YXV_FORMAT.md` 只作历史参考。**

## 2. 当前视频链路（唯一在跑的那条）

```
片源.mp4
  └─ tools/vq_encode_stream.py          （PC 端，VQ 编码；DELTA 用 vq_encode_delta.py）
       └─ out/vp_720_5f.yxv2            （YXV2：20B 头 + cb×32B 码本 + 每帧 5B 头 + 负载）
            ├─ 仿真：tools/sim/run_sim.ps1 各入口直接喂给 TB
            │        （bboard_sys / bboard_sys_eth 用 vp_720_5f.yxv2；
            │          bboard_key 用 tb/tb_gen_key_stream.v 生成的合成 KEY 流）
            └─ 实机：板 A 读 SD 上的 .yxv2 → 以太网 UDP → 板 B 解码 → HDMI 720p
```

> VQ 工具链是 2026-11-26 才入库的（commit `77fa38a`）。在此之前仓库**无法生成**
> `.yxv2`，而门禁又依赖这些文件 —— 换机/评审时链路是断的。

## 3. 历史上被格式混淆耽误过什么（如实记录）

| 现象 | 真实原因 | 是否格式混淆 |
|---|---|---|
| 把 720p60 误判为"提高目标 / scope change" | `yx_vp_vq.v:14`、`yx_vp_ixdec.v:58` 里的帧预算注释是 **1080p@24~30 时代遗留** | **否**——是"时代混淆"（1080p→720p），不是 MJPEG↔VQ |
| 新会话/评审以为视频格式是 MJPEG | 仓库唯一的视频工具是 `video2yxv.py`（MJPEG），VQ 工具链当时未入库 | **是**（已在 `77fa38a` 修复） |
| 怀疑 `BOOK[0..7]=65535` 是码本装载缺陷 | 实测码流 entry 0 本来就是全 `FFFF`，是合法内容 | 否——是"内容 vs 缺陷"混淆，属 VQ 内部 |

而 P5 阶段真正耗时的那些坑（TD 层次引用 `HDL-8007`、BRAM 池 590 Kbit 装不下
740 Kbit、WR1 推数相位、AXIS `user/last` 深度差、`sk_wp/sk_rp` 帧边界不复位、
`S_WALK` 卡 `q_room`）**全部与格式无关**，属时序/资源/状态机问题。

## 4. 另一类"同物双份"风险（当前状态：已消除）

曾有一处更危险的隐患：**仿真用的 SDRAM 控制器与要综合的不是同一份代码**
（`tb/bshims/Sdram_Control_4Port.v` 带 P3 修补，而 `src/5640/sdram_ctrl_4p/` 原件没有），
差一步就综合出"没有 P3 修补的旧行为"。

**现状（已核实）**：所有门禁入口在仿真与综合两侧都使用
`src/5640/sdram_ctrl_4p/b_board/Sdram_Control_4Port_b.v`（模块名 `Sdram_Control_4Port_B`），
`tb/bshims/Sdram_Control_4Port.v`（模块名 `Sdram_Control_4Port`）**已无任何入口引用**，
仅作历史对照保留（文件头已标注 legacy）。**不要再把它加回源单。**

同理 `tb/bshims/Sdram_RD_FIFO.v` 亦为历史件，门禁用 `b_board/Sdram_RD_FIFO_b.v`。

## 5. 相关文档索引

| 想了解 | 看 |
|---|---|
| YXV2 帧格式、码本、流水 | `docs/YXVP_VQ_DESIGN.md` |
| 各阶段结果（S1/S2/S3/DELTA/CPU/SD） | `docs/YXVP_*_RESULT_*.md`、`docs/YXVQ2_DELTA_RESULT_20261109.md` |
| 板 B 显示通路 | `docs/YX_BBOARD_P3_DISPLAY_20261121.md` |
| 板 B 以太网入口 | `docs/YX_BBOARD_P4_ETH_20261123.md` |
| 板 B 资源/时序收敛全过程 | `docs/YX_BBOARD_P5_*.md`（SYN → P0P1 → P2B → PHY1 → THROUGHPUT） |
| YXV v1（MJPEG，废弃） | `docs/YXV_FORMAT.md`（仅供历史参考） |
