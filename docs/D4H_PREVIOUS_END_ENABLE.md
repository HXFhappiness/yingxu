# D4h：缩短 previous_end 写使能路径（2026-11-01）

基线feat/mjpeg@8eb0151。用户TD确认D4g诊断端点已清零，但mem_clk仍有1条 `assembly_reg[34] → previous_end_reg[0].ce`，slack−0.221ns；10条TMDS/LVDS历史路径单独计，不作为本次修改对象。**D4g诊断删减保留，D4h只修这条功能寄存器CE路径；仍须TD确认mem100零负slack后才烧写。**

## 1. 最小修复

生产RTL只改 `src/user_source/hdl_source/media/mjpeg/yingxu_yxv_loader.v`，将 `previous_end<=entry_end[18:0]` 从“完整表项通过全部校验”分支，移到“完整表项已接收”分支。

旧CE：`byte_fire && !abort && meta && !invalid && 表项范围/第8字节 && 全部内容校验通过`。最后一项含长度范围、地址对齐、顺序、末端/音轨界限等，导致assembly经比较网络进入19bit寄存器CE。

新CE仅取“接收完整表项”的控制条件，**与本表项的原始offset/length值无关**。不增加使能寄存器、不改变时钟域或拍数，不缩短比较位宽，不放宽任何JPEG/YXV范围或重叠检查，不改约束或SD/SDRAM仲裁。

## 2. 为什么行为仍安全

非阻塞赋值保证同一边沿的校验仍读取**旧previous_end**，也就是前一已接收有效表项的末端；不会拿当前entry_end与当前offset自比较。

- 当前表项有效：新旧都在本边沿更新previous_end、写同一BRAM表项，最后一项更新audio_off；所有有效路径、数据和时序拍数相同。
- 当前表项无效：新版本允许previous_end记下这个候选末端，但仍同步置invalid/error93，**不写帧表、不更新audio_off**。invalid只在共同复位清零；后续表项处理由 `!invalid` 阻断，FINISH进入失败而不发PCM/JPEG，故这个拒绝后的候选值不会再作为校验基准使用。共同复位时previous_end仍清0。
- 首项与末项边界、512项上限、跨扇区、连续表项均沿用原完整校验。D4g的B8粗粒度诊断、数据快照常量0和提前显示机制均保留。

**有意变化仅是错误已锁存时这个内部寄存器的值；对外仍严格拒绝，不能据此把无效表项当已提交。** 相较新增sys域采样/CDC或多拍提交，此修改能保持原事务顺序与延迟。

## 3. 判据与复现命令

- `python tools/yxv_diagnostics_verify.py`：27例，保留头/表/缺done/缺字节/早同晚done/最后字节判错。另要求10/10坏表实例满足：invalid持续、previous_end不再被后续表项重用，且不进入PCM/JPEG、不置loader_ready或slot_valid。word/index仍恒0。
- `python tools/yxv_d3_units.py`：36与512帧完整表逐项比对，PCM/JPEG逐字节、全部帧回绕，验证有效表项端点仍正确；含快字节流、扇区边界与写背压。另重跑物理侧口、scanout和PCM既有单元。
- `python tools/yxv_d3_verify.py --frames 2`：实际top正常短程图像/HDMI音频/AV/退出回归；不是新的3秒播放。top编译后可用 `--no-build` 复用对应二进制。
- `python tools/yxv_d3_verify.py --pending`：检查D4e退场未完成时MISE/LS/F仍从实际UART可见。
- `python tools/yxv_d4h_structure.py`：以8eb0151为对照，检查映射后的previous_end全部19个CE及bit0 CE的输入锥，要求新版本没有assembly/SD byte组合直达CE；同时记录D端仍有原始数据计算、面积与常量诊断端口，**不能把CE断开说成整个寄存器时序已通过**。

该改动不重跑耗时7594物理预载并冒称板测；对应宽度与历史预载结论保留。当前优先完成单一CE修改的功能验证与TD验收，不叠加其他修复。

## 4. TD门禁

本地TD必须确认mem_clk/clk2=100MHz **零负slack**，同时查看previous_end的CE、D端以及其他功能端点；不能只确认旧路径不再列出。若仍存在任何mem负slack，停在门禁，不烧写。保持D4g诊断端点清零；不修改TMDS/LVDS历史路径或用false_path/set_max_delay豁免本路径。

门禁通过才烧写并复测头/表/PCM→解码链。若仍949F，继续在时序干净的固件上二分写数据/物理授权/done。本轮云端未执行TD或烧录，不宣称门禁已经通过。
