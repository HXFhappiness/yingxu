# GitHub 发布指南（0.17.0 · B 板 VQ）

> 面向 https://github.com/HXFhappiness/yingxu
> 现状：仓库已公开，8 次提交，有 README/LICENSE/.gitignore；
> **但完全没有 B 板 VQ 协处理器**（`media/` 下只有 bmp、sd）。
> 本指南给出三件事：仓库元信息、待发布文件清单、推送步骤。

---

## 1. 仓库元信息（在 Settings 页填入）

**Description（建议）**
```
映序 YingXu · 基于国产安路 EG4S20 的 FPGA 多媒体游戏机 + 双板视频协处理器（自研 YX-8 CPU / YXV2 码流 / 720p HDMI 扫出）
```

**Topics（标签）**
```
fpga  anlogic  eg4s20  verilog  iverilog  hdmi  sdram  game-console
cpu-design  video-codec  yx8  yingxu
```

**Website**：如有演示视频/文档站，填链接；没有就留空。

---

## 2. 待发布文件清单（B 板 VQ，共 5 组）

### 2.1 新增 RTL（11 个）
```
src/user_source/hdl_source/media/vp/yingxu_vq_board_top.v
src/user_source/hdl_source/media/vp/yx_vp_vq.v
src/user_source/hdl_source/media/vp/yx_vp_ixdec.v
src/user_source/hdl_source/media/vp/yx_vp_ixbuf.v
src/user_source/hdl_source/media/vp/yx_vp_band.v
src/user_source/hdl_source/media/vp/yx_vp_vbuf.v
src/user_source/hdl_source/media/vp/yx_b_hdr_parse.v
src/user_source/hdl_source/media/vp/yx_b_ix_seq_wr.v
src/user_source/hdl_source/media/vp/yx_b_ix_fetch.v
src/user_source/hdl_source/media/vp/yx_b_scanout.v
src/user_source/hdl_source/media/vp/yx_b_scanout_play.v
```

### 2.2 新增 TB 与 shim（8 个）
```
tb/tb_scanout.v             显示通路独立 TB
tb/tb_yxvp_bboard.v         B 板 SoC 集成验收
tb/tb_sdctrl_sanity.v       vendor 控制器回环（若无则跳过）
tb/tb_yxvp_ixpipe.v         ixpipe 回归（若无则跳过）
tb/bshims/EG_LOGIC_FIFO.v   含真双时钟 CDC（格雷码）行为模型
tb/bshims/EG_PHY_PLL.v
tb/bshims/EG_PHY_SDRAM_2M_32.v
tb/bshims/Sdram_Control_4Port.v
tb/bshims/Sdram_RD_FIFO.v
tb/bshims/pll_hdmi1_4b.v
```

### 2.3 新增工具（保留核心，删一次性排障脚本）
```
tools/sim/run_sim.ps1        带门禁仿真入口（保留）
tools/sim/gen_golden.py      真实流金标生成器（保留）
tools/sim/write_cart.py      已在仓库
tools/sim/music2sd.py        已在仓库
```
> `tools/sim/` 下的 probe_*.py / patch_*.py / sweep*.py / grep_so*.py /
> extract_*.py / solve_lag.py / head_tail.py / enc_check.py / strip_bom.py
> 都是一次性排障脚本，**建议不发布**（已在 .gitignore 中排除）。

### 2.4 新增文档
```
docs/YX_BBOARD_INTEG_DESIGN_20261110.md
docs/YX_BBOARD_INTEG_RESULT_20261110.md
docs/YX_BBOARD_CPRD_20261121.md        cp 读口闭环（含 64 对齐坑）
docs/YX_BBOARD_DELTA_20261121.md       DELTA 合并流
docs/YX_BBOARD_P3_DISPLAY_20261121.md  HDMI 扫出 + 双窗口
docs/STATUS_YX2.md / STATUS_YX4.md     阶段性交接（可选）
```

### 2.5 README 增补
把 `docs/GITHUB_README_SECTION_VQ.md` 全文**插入到 README 的「快速开始」之前**
（即「仓库结构」之后），标题为 `## 0.17.0 · B 板 VQ 视频协处理器（双板「算画分开」）`。

---

## 3. 必须排除的内容（IP 与体积）

| 路径 / 模式 | 原因 |
|---|---|
| `src/**/hdmi1.4b_transmitter_core/*.enc.v` | 厂商**加密 IP**，公开有授权风险 |
| `out/` | 仿真产物，数百 MB |
| `td_*.log` / `td_*.logw` | TD 综合日志（本目录有上千个） |
| `*.vvp` / `*.dmp` / `*.qor` / `*.bid` | 编译/崩溃/报告产物 |
| `YX_交接包*` / `YX_美术资源包*` | 交接压缩包，体积大且含重复内容 |
| `AC201_AL_board_test_Runs/` / `cleanup_backup_*` / `log/` / `scripts/` | 本地临时 |
| `cartridges/*.yxc` | 二进制卡带（可选：如仓库已有则保留） |

### `.gitignore` 追加
```gitignore
# --- 仿真与综合产物 ---
out/
_Runs/
*-Runs/
*.vvp
*.qor
*.bid
*.dmp
td_*.log
td_*.logw
*.logw

# --- 一次性排障脚本 ---
tools/sim/probe_*.py
tools/sim/patch_*.py
tools/sim/sweep*.py
tools/sim/grep_so*.py
tools/sim/extract_*.py
tools/sim/solve_lag.py
tools/sim/head_tail.py
tools/sim/enc_check.py
tools/sim/strip_bom.py

# --- 交接包 / 备份 ---
YX_交接包*/
YX_美术资源包*/
*.zip
cleanup_backup_*/
log/

# --- 厂商加密 IP（不公开） ---
*.enc.v
```

---

## 4. 推送步骤

当前机器**未安装 git**（`git`、`gh` 均不在 PATH），因此需要先装：

```powershell
# 1) 安装 Git for Windows（含 git 与凭据管理器）
winget install --id Git.Git -e
# 或 https://git-scm.com/download/win

# 2) 克隆已有仓库（不要新建，仓库已有 8 次提交）
cd C:\Users\HXF\Desktop
git clone https://github.com/HXFhappiness/yingxu yingxu-repo
cd yingxu-repo

# 3) 把本地的 VQ 文件复制进去（示例，按 §2 清单逐组复制）
robocopy C:\Users\HXF\Desktop\YX\src\user_source\hdl_source\media\vp `
         src\user_source\hdl_source\media\vp /E
robocopy C:\Users\HXF\Desktop\YX\tb\bshims tb\bshims /E

# 4) 追加 .gitignore 规则（§3），插入 README 章节（§2.5）

# 5) 检查将要提交的内容（确认没有 out/ 和 .enc）
git add -A
git status --short
git ls-files | findstr /I ".enc out/ .vvp"

# 6) 提交并推送
git commit -m "feat(vq): 加入 B 板 VQ 视频协处理器（YXV2 解码 / DELTA 合并流 / 720p 双窗扫出）"
git push origin main
```

---

## 5. 建议的后续增强（可选）

1. **Release**：把 `release/RELEASE_g32_FROZEN_20261031.bit` 与烧录说明做成
   Release 附件，比放在仓库里更适合分发。
2. **演示素材**：README 顶部放 1 张 HDMI 实拍图 + 1 个 10 秒 GIF（BMP 轮播、
   卡带游戏、VQ 视频各一），比文字更有说服力。
3. **架构图**：现有 ASCII 框图可换成 SVG（`docs/` 下放源文件）。
4. **CI（可选）**：GitHub Actions 装 iverilog 跑 `run_sim.ps1`，
   把 GATE 行作为 CI 判据——这是本项目"门禁式仿真"的自然延伸。
5. **文档入口**：README 的「文档」一节建议加一行
   `VQ 子系统：docs/YX_BBOARD_P3_DISPLAY_20261121.md`。

---

## 6. 需要你确认的一点

B 板的**显示链路在 TD 综合时**会实例化厂商加密 HDMI 核。公开仓库不包含该核，
因此**别人 clone 后只能跑仿真、不能直接综合出 B 板 bit**。建议在 README 的
「许可」一节加一句说明：

> B 板显示链依赖安路官方 HDMI 1.4b 加密 IP（未随仓库分发）。仿真构建
> （默认）不依赖该 IP，可直接复现全部验收结果；综合 B 板需自行从安路
> IP 库获取该核。
