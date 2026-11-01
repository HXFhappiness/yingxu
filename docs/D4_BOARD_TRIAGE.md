# D4 视频板测排查报告：三组合遥测对照与 D4c 设计建议

> 2026-11-01。D3 顶层集成（976624e）板测失败（"只有背景"）。本地依次做了 D4a（入口开关组合变更，
> 372005d）、D4b（入口脉冲修复尝试，612fe6c，已被审查否决）、以及 D3 原组合（E7）的对照实验。
> 本文汇总三组遥测证据、统一诊断与 D4c 设计建议。**RTL 修复由 D4c 承担，本地不再另改。**

## 0. 实验环境

- 固件：D3=976624e / D4a=372005d / D4b=612fe6c（均 12.5MHz SPI + 两拍排空）
- 媒体：YXV（640x480@24, 486 帧, PCM 48kHz, 22.2MB）已写入 SD 卡绝对 LBA 3000000..3043298，PC 侧全量读回校验逐字节一致
- 遥测：COM5 UART 数据流（与采集卡/OBS 无关）；每秒约 2 帧 A/B/C/D

## 1. 三组合对照（决定性数据）

| 观测项 | 77（D4a/D4b，SW7 ON+SW3 ON） | E7（D3 原组合，SW7 OFF+SW4 ON+SW3 ON） | 1F（卡带对照，SW7+SW5+SW6） |
|---|---|---|---|
| game_mode | 1 | 0 | 1 |
| 照片/幻灯引擎 | 死（被 `!game_mode` 屏蔽，见 blocker#3） | **活：持续装载照片** | 正确让位 |
| SD 初始化 | **失败**：ERR=1、DNE=0、RSP 全 FF@400kHz 档、SST=125 次重试后停 | **完成**（照片能读=初始化好的） | 完成，DNE=1，WC=25C，PC=014 |
| SD 数据 | OFF=0（零字节） | OFF 十秒涨 1.5MB+（SDN≈42268 爬升，BUSY=1，DIV=02=12.5MHz 读态，RD=3） | OFF 累计 2.76MB |
| 视频管线 | 接管了（F: 4→E）但 source_ready 锁死 | **从未接管**（F=0 恒定 10s，尽管按条件 video_requested=1） | — |
| 屏幕 | 背景 | 照片幻灯片（用户目视确认） | 游戏正常 |

D4b（入口单拍脉冲）在 77 下复测：SST=559 冻结、F=0、DNE=0、ERR=1、OFF=0 — **无效**，脉冲修法作废
（与审查结论一致：restart 须等 init_done；且遗留请求会以错误 LBA 启动）。

## 2. 关键遥测原始帧

77（D4a 启动即视频，稳定后）：
```text
A SEEN=1 BUSY=0 ERR=1 DNE=0 POR=1 GM=1 CA=0
B CTRL=4 INIT=0 RSP=00FFFFFFFF RD=0 DIV=3E SPIK=0 CNT=0 CSN=1
C SST=022F SNX=022F SDN=3290 ACC=000 OFF=00000000 VLD=0
D SW=77 LS=0 WC=000 BU=0 SP=BB80 F=0 PC=3FF DW=0000 I0=249200 RC=0000 I1=000000
```

77（D4b 同位置）：SST=559 冻结、SDN=3290、F=0、其余同上。

E7（D3，进入 10 秒后）：
```text
A SEEN=1 BUSY=1 ERR=1 DNE=0 POR=1 GM=0 CA=0
B CTRL=3 INIT=0 RSP=00FFFFFFFF RD=3 DIV=02 SPIK=1 CNT=F CSN=0 MISO=0
C SST=CA36 SNX=CA37 SDN=A51C ACC=200 OFF=00180E00 VLD=0
D SW=E7 LS=0 WC=000 SP=BB80 F=0 PC=3FF
（10 秒内 SST: AB80→CA36，OFF: 0x4F200→0x180E00，SDN 在照片扇区区段爬升）
```

1F（卡带对照，D4a 固件）：
```text
A SEEN=1 BUSY=0 ERR=0 DNE=1 GM=1 CA=1
C SST=15BE SDN=4C85 OFF=002A3200
D SW=1F LS=4 WC=25C PC=014 F=F
```

## 3. 统一诊断

1. **E7（game_mode=0）**：video_requested 条件成立，但管线 claim 需要 `!sd_busy`——
   照片/幻灯引擎持续占用 SD（每扇区 CMD17 连发），总线永远不空，claim 永远等不到；
   ACQUIRE_LIMIT（2.5e8 拍）内没有出现空闲窗口。**视频输给了照片引擎。**
2. **77（game_mode=1）**：照片引擎被 `!game_mode` 屏蔽（正是 blocker#3），总线空出来，
   管线成功接管（F 变化可证）——但 **SD 核自启初始化在真机上失败**（125 次重试零响应后 ERR sticky，
   DNE 恒 0）。与仿真相悖（仿真里帧 0 解码正确），说明真机 77 组合下有仿真模型覆盖不到的
   初始化路径问题（restart=0 是否同时门控了自启序列？仲裁器在初始化期间是否抢占了什么？）。
   D4b 的入口脉冲（init 完成前打 restart）无效，已作废。
3. **compositor（blocker#1）**：仿真复现 306ms 后被覆盖——即使数据通了，显示权还会被
   照片合成层夺回。这是第三道独立的闸。
4. **照片回退（blocker#3）**：`video_photo_reload` 的 `!game_mode` 条件在 77 下恒假，
   视频失败后无法回退照片模式。

**结论：视频要通需要按顺序过三道闸：**
`① 照片引擎让位（E7 堵点） → ② 初始化协议正确（77 堵点） → ③ compositor 显示权（仿真 306ms 堵点）`
失败回退要在 77/E7 两种组合下都能触发（blocker#3）。

## 4. D4c 设计建议

1. **照片引擎让位**：`video_requested` 上升沿 → 抑制照片/幻灯引擎的 SD 请求并等待在途事务完成
   （而不是等 `!sd_busy` 自然窗口）；完成后才允许管线 claim。E7 与 77 两种组合下都必须生效。
2. **初始化协议**：入口后按 init_done 协议允许 restart/首次读；明确管线真实依赖链
   （审查指出"管线依赖的不是 DNE"——请在代码注释与本文件同步写清），并解释真机 77 下
   自启初始化零响应的机制（仿真不可见的那部分）。
3. **compositor**：`video_owned` 期间强制视频层显示优先，禁止照片合成层在 306ms 类时点重夺
   display 权；退视频时恢复原合成逻辑。
4. **回退**：视频失败/退出的照片重载触发条件去掉 `!game_mode` 死绑，77/E7 下均可回退；
   失败 sticky、禁止无限自动重试的既有语义保留。
5. **TB/断言**：UART 断言、tb_yxv_top 引脚（已改 0x77）、遥测期望值全部同步 77 组合。

## 5. 本地资产状态

- 已烧写过：d3_video_976624e.bit（当前在板）、d4a、d4b（位流均已备份于 bitstream_backup/）
- P1 已知好位流：p1_12p5mhz_2cyc.bit（随时可回滚）
- 本地 commit：D4a=372005d、D4b=612fe6c（均已推送）；D4c 待 Codex 交付后本地构建板测
