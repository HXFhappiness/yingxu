#Requires -Version 5.1
# ============================================================================
# run_sim.ps1 — YX B 板带门禁仿真入口
#
# 用法:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sim\run_sim.ps1 -Entry <name>
# 入口:  sdctrl_sanity | bboard_sys
#
# 门禁规则:
#   1. 每次运行生成唯一输出名（含时间戳），.vvp / compile.log / sim.log 三件套互不覆盖；
#   2. iverilog 退出码 != 0 → 打印 COMPILE-FAIL 并 exit 1，绝不执行 vvp；
#   3. 结束打印一行:  VERDICT: <name> PASS|FAIL exit=<vvp退出码> summary="<TB-SUMMARY原文>"
#      脚本自身退出码: PASS=0, FAIL / COMPILE-FAIL / INPUT-FAIL = 1。
#
# ----------------------------------------------------------------------------
# 历史命令 A（docs 版 = 本脚本 bboard_sys 的参数依据）
#   出处: docs\YX_BBOARD_INTEG_RESULT_20261110.md:80-83
#     iverilog -g2005 -o out\bboard.vvp tb\tb_yxvp_bboard.v <top+N 个 vp 模块>
#              tb\bshims\*.v src\5640\sdram_ctrl_4p\{sdram_ip,command,control_interface,
#              sdr_data_path,Sdram_PLL,Sdram_WR_FIFO,Sdram_RD_FIFO}.v
#     vvp out\bboard.vvp +STREAM=out\vp_720_5f.yxv2 +WD=8000000
#   注: 原文 "<top+3 个 vp 模块>" 是占位符。顶层实际实例化 6 个 vp 模块
#       (yingxu_vq_board_top.v:154-222: ixdec/ixbuf/band/hdr_parse/ix_seq_wr/ix_fetch)，
#       加顶层共 7 个 vp 源文件。
#
# 历史命令 B（坏门禁一笔式，用户提供原文；已废弃，仅存档勿用）:
#     cd /d C:\Users\HXF\Desktop\YX && iverilog -g2005 -DBBOARD_SYS -DDISP_NUM=249 -DDISP_DEN=1000 -o out\bboard_sys.vvp <7个vp源文件> <4个bshims> <7个sdram_ctrl_4p文件> 2>&1 | findstr /i "error" & echo OK & vvp out\bboard_sys.vvp +STREAM=out\vp_720_key.yxv2 +WD=1200000
#   缺陷: (a) `| findstr` 吞掉 iverilog 退出码; (b) `&` 链使编译失败仍跑 vvp;
#         (c) 输出名固定 out\bboard_sys.vvp，会复用旧二进制。
#   与 docs 版差异: B 加了 -DDISP_NUM=249 -DDISP_DEN=1000（令牌桶节流档）,
#         码流用 out\vp_720_key.yxv2（KEY-only 合成流）, WD=1200000;
#         docs 版为自由跑 + out\vp_720_5f.yxv2 + WD=8000000。本脚本以 docs 版为准。
#
# ----------------------------------------------------------------------------
# sdctrl_sanity 源单依据（12 个文件）:
#   tb\tb_sdctrl_sanity.v:33   实例化 Sdram_Control_4Port → 用 tb\bshims 仿真副本
#                              （tools\_ctrl_shim.py 生成的 iverilog 兼容版，:1-2 注释）
#   tb\tb_sdctrl_sanity.v:53   实例化 sdram_ip → src\5640\sdram_ctrl_4p\sdram_ip.v:29
#                              内含 EG_PHY_SDRAM_2M_32
#   tb\bshims\Sdram_Control_4Port.v 内部实例化（:261-374）:
#     Sdram_PLL sdram_pll1(:261) / control_interface control1(:274) / command command1(:293)
#     / sdr_data_path data_path1(:319) / Sdram_WR_FIFO write_fifo1,2(:328,343)
#     / Sdram_RD_FIFO read_fifo1,2(:361,374)
#   src\5640\sdram_ctrl_4p\Sdram_PLL.v:38   → EG_PHY_PLL（tb\bshims\EG_PHY_PLL.v）
#   src\5640\sdram_ctrl_4p\Sdram_WR_FIFO.v:31,43 和 Sdram_RD_FIFO.v
#     → EG_LOGIC_FIFO 实例 logic_fifo（tb\bshims\EG_LOGIC_FIFO.v:14）
# bboard_sys 源单依据（19 个文件）:
#   tb\tb_yxvp_bboard.v + 历史命令 A 的文件族（7 vp + 4 bshims + 7 sdram_ctrl_4p）。
# ============================================================================

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('sdctrl_sanity', 'bboard_sys', 'bboard_key', 'eth_rx', 'bboard_sys_eth')]
    [string]$Entry
)

$ErrorActionPreference = 'Stop'
$Root = 'C:\Users\HXF\Desktop\YX'
Set-Location $Root

# ---- 工具链（出处: docs\HANDOFF_20261026.md:147, tools\_verify_s1b.py:6-7）----
$IV  = 'D:\iverilog\bin\iverilog.exe'
$VVP = 'D:\iverilog\bin\vvp.exe'
if (-not (Test-Path $IV))  { $c = Get-Command iverilog.exe -ErrorAction SilentlyContinue; if ($c) { $IV  = $c.Source } }
if (-not (Test-Path $VVP)) { $c = Get-Command vvp.exe     -ErrorAction SilentlyContinue; if ($c) { $VVP = $c.Source } }
if (-not (Test-Path $IV))  { Write-Output 'TOOL-FAIL: iverilog.exe not found'; exit 1 }
if (-not (Test-Path $VVP)) { Write-Output 'TOOL-FAIL: vvp.exe not found';      exit 1 }

$VP   = 'src\user_source\hdl_source\media\vp'
$CTRL = 'src\5640\sdram_ctrl_4p'
$BSHM = 'tb\bshims'

$Entries = @{}

# ---- 入口 1: sdctrl_sanity（vendor SDRAM 控制器写读回环，看门狗 4ms sim 时间，快）----
$Entries['sdctrl_sanity'] = @{
    Defines  = @()
    PlusArgs = @()
    Sources  = @(
        'tb\tb_sdctrl_sanity.v',
        "$BSHM\Sdram_Control_4Port.v",
        "$BSHM\EG_PHY_PLL.v",
        "$BSHM\EG_LOGIC_FIFO.v",
        "$BSHM\EG_PHY_SDRAM_2M_32.v",
        "$CTRL\sdram_ip.v",
        "$CTRL\command.v",
        "$CTRL\control_interface.v",
        "$CTRL\sdr_data_path.v",
        "$CTRL\Sdram_PLL.v",
        "$CTRL\Sdram_WR_FIFO.v",
        "$CTRL\Sdram_RD_FIFO.v"
    )
}

# ---- 入口 2: bboard_sys（B 板 SYS 集成验收，真实流 720p×5 帧，耗时较长）----
# 文件金标（gen_golden.py）在运行前生成：DELTA 帧存在 → 合并流路径被真实覆盖。
# WD 8M→12M：DELTA 合并流重建 + 真实流节奏比 KEY-only 略慢（YX4 实测 4 帧/8M 边缘）。
# ★ P3（YX6）：显示 = HDMI 扫出（73.33M 像素域双窗），DISP_NUM/DEN 令牌桶退役
#   （define 保留传入无害）；RD1_FIFO 用 bshims 版（CDC=1 格雷码双时钟）。
$Entries['bboard_sys'] = @{
    Defines  = @('BBOARD_SYS')
    Stream   = 'out\vp_720_5f.yxv2'
    Golden   = $true
    PlusArgs = @('+STREAM=out\vp_720_5f.yxv2', '+WD=12000000')
    Sources  = @(
        'tb\tb_yxvp_bboard.v',
        "$VP\yingxu_vq_board_top.v",
        "$VP\yx_vp_band.v",
        "$VP\yx_vp_ixbuf.v",
        "$VP\yx_vp_ixdec.v",
        "$VP\yx_b_hdr_parse.v",
        "$VP\yx_b_ix_seq_wr.v",
        "$VP\yx_b_ix_fetch.v",
        "$VP\yx_b_scanout.v",
        "$VP\yx_b_scanout_play.v",
        'src\user_source\hdl_source\video_source_test.v',
        "$BSHM\EG_LOGIC_FIFO.v",
        "$BSHM\EG_PHY_PLL.v",
        "$BSHM\EG_PHY_SDRAM_2M_32.v",
        "$BSHM\Sdram_Control_4Port.v",
        "$BSHM\Sdram_RD_FIFO.v",
        "$BSHM\pll_hdmi1_4b.v",
        "$CTRL\sdram_ip.v",
        "$CTRL\command.v",
        "$CTRL\control_interface.v",
        "$CTRL\sdr_data_path.v",
        "$CTRL\Sdram_PLL.v",
        "$CTRL\Sdram_WR_FIFO.v"
    )
}

# ---- 入口 3: bboard_key（KEY-only 合成流金标验收）----
# 金标公式（idx=(blk*11+frame*313)%CBSIZE、码本字=i+j）只对 tb_gen_key_stream 生成
# 的合成流成立。docs 版参数喂真实编码流 vp_720_5f.yxv2 → 金标必然全错
# （证据 out\sim\bboard_sys_20261111_164147：BOOK=65535×8、PATCH idx=43 恒值均为真实流
#   内容，与旧通过记录 ixpipe_regress.log 的 WR#1 data=002b 一致，非 RTL 错）。
# 本入口 = bboard_sys 源单/门禁 + 合成码流（历史命令 B 的码流选择）。
$Entries['bboard_key'] = @{
    Defines  = @('BBOARD_SYS')
    Stream   = 'out\vp_720_key.yxv2'
    # WD 8M→12M（YX6）：YX4 §五.2 实测 KEY-only 5 帧 7.91M 拍、裕量仅 1.1%；
    # fetch v5（cp 分时）对 KEY 流零扰动，裕量不变，WD 提至与 sys 同档消除边缘风险。
    PlusArgs = @('+STREAM=out\vp_720_key.yxv2', '+WD=12000000')
    Sources  = $Entries['bboard_sys'].Sources
}

# ---- 入口 4: eth_rx（P4 以太网入口独立验收，快速迭代）----
# GMII 帧发生器 → yx_b_eth_rx → 逐字节对拍源文件。
# 用例：坏 CRC 包整包丢弃、错端口包被厂商核丢帧、广播 MAC 接收、消费者背压。
$Entries['eth_rx'] = @{
    Defines  = @()
    Stream   = 'out\vp_720_5f.yxv2'
    PlusArgs = @('+STREAM=out\vp_720_5f.yxv2')
    Sources  = @(
        'tb\tb_eth_rx.v',
        "$VP\yx_b_eth_rx.v",
        'src\eth_udp_rx_gmii.v',
        'src\ip_checksum.v',
        'src\crc32_d8.v',
        'src\rgmii_to_gmii.v',
        "$BSHM\BUFG_0.v",
        "$BSHM\IDDR_0.v"
    )
}

# ---- 入口 5: bboard_sys_eth（P4 全链路：UDP 码流 → 解码/渲染/扫描 → HDMI AXIS）----
# 判据与 bboard_sys 完全一致（golden/igold/axerr/…）+ 传输层零丢包。
# WD 16M：以太网按消费能力节流，总拍数略高于文件直推。
$Entries['bboard_sys_eth'] = @{
    Defines  = @('BBOARD_SYS', 'BBOARD_ETH')
    Stream   = 'out\vp_720_5f.yxv2'
    Golden   = $true
    PlusArgs = @('+STREAM=out\vp_720_5f.yxv2', '+WD=16000000')
    Sources  = $Entries['bboard_sys'].Sources + @(
        "$VP\yx_b_eth_rx.v",
        'src\eth_udp_rx_gmii.v',
        'src\ip_checksum.v',
        'src\crc32_d8.v',
        'src\rgmii_to_gmii.v',
        "$BSHM\BUFG_0.v",
        "$BSHM\IDDR_0.v"
    )
}

$Cfg = $Entries[$Entry]

# ---- 文件金标预生成（真实流入口）----
# gen_golden.py 解析码流 → 每帧窗状态 idx.mem + 每帧行缓冲期望 fb.mem；
# 生成失败按 INPUT-FAIL 处理（不进编译/仿真）。
if ($Cfg.Golden) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($Cfg.Stream)
    $gdir = Join-Path $Root ('out\goldens\' + $stem)
    New-Item -ItemType Directory -Force -Path $gdir | Out-Null
    & python -I (Join-Path $Root 'tools\sim\gen_golden.py') (Join-Path $Root $Cfg.Stream) $gdir
    if ($LASTEXITCODE -ne 0) {
        Write-Output ('INPUT-FAIL: golden gen failed for ' + $Cfg.Stream)
        exit 1
    }
    $Cfg.PlusArgs += @(
        ('+GOLDEN_IDX=' + (Join-Path 'out\goldens' ($stem + '\idx.mem'))),
        ('+GOLDEN_FB=' + (Join-Path 'out\goldens' ($stem + '\fb.mem')))
    )
    Write-Output ('GOLDEN-GEN ok dir=' + $gdir)
}

# ---- 唯一输出名（时间戳三件套，绝不覆盖）----
$TS     = Get-Date -Format 'yyyyMMdd_HHmmss'
$OutDir = Join-Path $Root 'out\sim'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$VvpPath = Join-Path $OutDir ('{0}_{1}.vvp' -f $Entry, $TS)
$CmpLog  = Join-Path $OutDir ('{0}_{1}_compile.log' -f $Entry, $TS)
$SimLog  = Join-Path $OutDir ('{0}_{1}_sim.log' -f $Entry, $TS)

# ---- 输入预检 ----
$missing = @($Cfg.Sources | Where-Object { -not (Test-Path (Join-Path $Root $_)) })
if ($missing.Count -gt 0) {
    Write-Output ('INPUT-FAIL: missing ' + $missing.Count + ' file(s): ' + ($missing -join ', '))
    exit 1
}
if ($Cfg.Stream) {
    if (-not (Test-Path (Join-Path $Root $Cfg.Stream))) {
        Write-Output ('INPUT-FAIL: ' + $Cfg.Stream + ' not found')
        exit 1
    }
}

# ============================ 编译（门禁）============================
$argList = @('-g2005')
foreach ($d in $Cfg.Defines) { $argList += ('-D' + $d) }
$argList += @('-o', $VvpPath)
$argList += $Cfg.Sources
$argStr = $argList -join ' '

# cmd 层重定向（stdout+stderr 同文件），退出码走 $LASTEXITCODE；路径均不含空格
$raw = "$CmpLog.raw"
cmd /c ($IV + ' ' + $argStr + ' > ' + $raw + ' 2>&1')
$rc = $LASTEXITCODE

$hdr  = 'cmd: ' + $IV + ' ' + $argStr + "`r`n"
$body = ''
if (Test-Path $raw) { $body = [IO.File]::ReadAllText($raw) }
[IO.File]::WriteAllText($CmpLog, $hdr + $body, (New-Object Text.UTF8Encoding $true))
Remove-Item $raw -ErrorAction SilentlyContinue

if ($rc -ne 0) {
    # 门禁：编译失败绝不运行 vvp
    Write-Output ('COMPILE-FAIL entry=' + $Entry + ' exit=' + $rc + ' log=' + $CmpLog)
    Get-Content $CmpLog -Tail 15 | ForEach-Object { Write-Output ('  ' + $_) }
    exit 1
}
Write-Output ('COMPILE-OK vvp=' + $VvpPath)

# ============================ 运行 ============================
$simArg = $VvpPath
foreach ($p in $Cfg.PlusArgs) { $simArg += (' ' + $p) }
cmd /c ($VVP + ' ' + $simArg + ' > ' + $SimLog + ' 2>&1')
$simRc = $LASTEXITCODE

# ============================ VERDICT ============================
$sumLine = Get-Content $SimLog | Where-Object { $_ -match 'TB-SUMMARY' } | Select-Object -Last 1
$verdict = 'FAIL'
if ($sumLine -and ($sumLine -match 'PASS') -and ($sumLine -notmatch 'FAIL')) { $verdict = 'PASS' }
$sumText = if ($sumLine) { $sumLine.Trim() } else { '(no TB-SUMMARY found)' }

$vLine = ('VERDICT: ' + $Entry + ' ' + $verdict + ' exit=' + $simRc + ' summary="' + $sumText + '"')
# 同步追加进 _sim.log 末尾（时间戳 + VERDICT 原文），便于事后追溯
[IO.File]::AppendAllText($SimLog, '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $vLine + "`r`n", (New-Object Text.UTF8Encoding $true))
Write-Output $vLine
Write-Output ('artifacts: vvp=' + $VvpPath + ' compile=' + $CmpLog + ' sim=' + $SimLog)

if (($verdict -eq 'PASS') -and ($simRc -eq 0)) { exit 0 } else { exit 1 }
