# D4c 交付与板上判据

基线25ea857；设计1596178，源码162e91f，分支feat/mjpeg。默认演示SW=77（SW7、SW3 ON，SW4/5/6 OFF）；E7保留为同路诊断入口。main、冻结位流、厂商IP、SPI12.5MHz和DRAIN_1CYC=0未改。TD/烧写由用户完成。

## 交接与显示

- video_requested成立立即冻结照片FSM及外部legacy新restart；探针legacy_inhibit同时禁止reader_start并清restart_hold。两SYS周期清队列后才允许申请owned；在途读取ready强制1，继续正常排空，不复位/截断SD事务。
- claim只在init_done&&!busy后；owned后唯一restart来自44bit邮箱，LBA/count在启动前稳定。取消D4b裸入口脉冲，不假造done或绕过初始化。
- 有效game_mode在视频请求/owned/照片回退期间为0，使用已有player输出寄存器中的视频选择，游戏sprite/tile通过原清除路径让位。没有往最终pix组合链加新级。
- owned期间BMP加载器复位、WR2 FIFO清空，旧照片尾数据不带入退出后的新加载。accepted物理事务由原控制器完成；视频PCM预载完成之前不读其内容。
- 失败/退出均一次照片重载，不绑原SW7 game_mode；失败保持到拨出再进入。qualified请求在failed时仍保持高，防止handoff结束被误认为退出而自动清failed。退出后照片保持至改变SW7/4/5/6基础模式，再恢复旧模式。

## 真机分歧的证据边界

原77日志I0=249200是错误92（YXV头），不是初始化错误码；SEEN来自init_done历史锁存，DNE来自reader_done。header失败后的sd_reset会让OFF/响应回到零/FF。旧F为cart_flags，不是claim信号。原仿真自动完成sd_card_control、不覆盖真实SPI响应，也没有覆盖人工晚拨入时排队legacy读的所有时序；不能用旧仿真反证板测，更不能把restart=0推为无人初始化。

D4c解决确定的排队/所有权/显示问题，保留真实首请求、首头字节，供本次板测区分真实SPI无响应与读错媒体。尚未声称查明或修复所有电气/协议级无响应。如果首LBA/count正确但头无返回，应停在SD读链路取证，不调高SPI、不继续改JPEG。

## 遥测（视频请求/owned/failed期间）

| 字段 | D4c解释与期望 |
|---|---|
| OFF | 首视频请求后为D+28bit首LBA，期望D02DC6C0；不再是累计字节offset |
| WC | 首请求扇区数低10位，期望001；卡带模式仍是镜像词数25C |
| RSP | 收到头4字节后为D4+实际4B，期望D459585631；此前保留原SPI RSP |
| F | {owned,init_done,busy,handoff}，bit3才是claim；替代旧cart_flags解释 |
| A.GM | 有效游戏模式；77视频期间应为0，这是让位视频，物理SW仍77 |
| I0 | 位23 owned，22音频使能，21失败，20 PCM ready，19解码busy，18请求；错误码位15…8 |
| PC / RC / MISE | 呈现tag/次数/解码次数增长；未呈现PC=3FF |
| DW / I1 / SCE | 丢帧0；实际音频pop约48000/s；SD busy及FIFO即时占用 |

首请求/头不会被视频失败的SD复位抹掉，退出并清失败后才重置。BAD magic可能显示D400585631等，这与初始化无字节不同。原始FF响应在捕获头后被D4标识替换，不能再按CMD响应解读。

## 回归与复现

77、E7完整3秒均通过（源码162e91f），原始日志/实际UART/源码哈希与 [verification.json](evidence/D4c/verification.json) 均在 [evidence/D4c](evidence/D4c)。HANDOFFCHK已验证自动初始化不依赖restart、旧排队清除、busy读排空、首新请求3000000/1及512B逐流、magic59585631。77/E7坏头和noinit均一次回退、有效game_mode=0、failed保持。照片、WAV48/44.1、卡带原回归分别通过。已知CPU cosim基线问题未计通过。

```bash
python tools/mjpeg_d2_verify.py --prepare-only
python tools/yxv_d3_verify.py --sw 0x77
python tools/yxv_d3_verify.py --no-build --sw 0xe7
python tools/yxv_d3_verify.py --no-build --sw 0x77 --bad 1
python tools/yxv_d3_verify.py --no-build --sw 0xe7 --bad 1
python tools/yxv_d3_verify.py --noinit --sw 0x77
python tools/yxv_d3_verify.py --noinit --no-build --sw 0xe7
PATH=/path/to/iverilog/bin:$PATH python tb/run_sd_drain.py
```

完整3秒维持真实时钟、原budget文件，目标0/72丢帧、AV<2000采样、图像/HDMI PCM逐点一致及真实UART断言。SD卡为服务模型，不能等同于SPI电气板测。

最终完整结果，两组合分别相同：

| 判据 | 77 | E7 |
|---|---:|---:|
| 实际播放 | 144001采样，3000000066ns | 同左 |
| 丢帧 | 0/72 | 0/72 |
| AV最大偏移 | 1849/2000采样 | 1849/2000采样 |
| 已写图像 | 73帧11212800word零diff | 同左 |
| 扫描像素 | 55053610点零diff，包含实际player/base复用 | 同左 |
| HDMI音频 | 144000样本零diff、48k误差0ppm | 同左 |
| SD播放期平均 | 1121450B/s，低于1300000 | 同左 |
| UART | 14条D帧，首地址/长度/头字节均验证 | 14条D帧，同左 |
| 退出/坏头/noinit | 一次照片重载，失败保持、有效GM=0 | 同左 |

73帧包含提前发布的下一帧，丢帧分母仍为实际3秒目标72。退出测试验证模式与重载请求，照片完整显示仍由本地板测确认。测试不把SD服务模型当作真实SPI协议通过，也不把TD代理当实测。

## 本地TD与当天板测

pull feat/mjpeg，TD打开AC201_AL_board_test.al；SIM_FAST_BOOT保持默认0。若phy启动崩溃，保留日志后按已知phy-only恢复流程重跑，核对源码版本与最终bit哈希；云端没有执行TD或生成bit。

用户既有D3实测12186 LUT/41 BRAM/0 DSP，余7414 LUT；这是该构建数据，不冒充D4c综合结果。D4c未改变JPEG主体；代理完整pipeline约8242 LUT、7 BRAM、21 DSP，物理差值149 LUT，板级模式和取证另列，均不是TD实测。新增取证主要为约80个寄存位和若干选择逻辑，不能用旧“仅余341”代理结论代替实测。重点核对decoder/IDCT/RGB层次是否保留、实际DSP/RAM映射及mem100/pix73.33时序。任何超容量或负slack即停，不据旧Fmax74.6/76.2在未明域归属时判通过。

用户486帧素材有3888000B PCM，按1.30MB/s预载约3秒，另加原上电/flush/init等待与首两帧准备；上电约5秒以上才出声是本版预载策略的估计，不应只凭初始背景判死锁。预载期间I0位20为0、DNE=0可以正常，RSP首头及帧数可先到达。

烧写后首先查看OFF/WC/RSP首请求证据；再要求MISE/RC/PC持续增长、DW=0、I1按48k推进，观察视频不被背景覆盖、退出/坏头可回到照片。保留77和E7各至少10秒原始A/B/C/D及准确bit版本。板测未通过之前仅称软件回归交付。


## D4c板测后续

用户确认首读OFF/RSP/count及回退sticky生效，失败收窄到首扇区后；不能从归零计数断言fault码。后续D4d诊断字段与完整首扇区状态顺序见 [D4D_DIAGNOSTICS.md](D4D_DIAGNOSTICS.md)，失败时MISE/SP/WC/ACC/RSP解释以D4d为准。
