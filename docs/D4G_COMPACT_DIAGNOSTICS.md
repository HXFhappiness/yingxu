# D4g：删除 word/index 快照，优先恢复 mem_clk 门禁（2026-11-01）

基线 feat/mjpeg@ecd1bbf。用户TD门禁明确FAIL：D4f仍有assembly_reg[39]或sd_bytes/rp_reg到debug_reason/debug_word/debug_index的20条负slack，最差−0.765ns；LUT12387→12586确认使用了新网表。**接受该板级时序证据，D4f不是干净基线，云端映射不能替代TD结论。**

## 1. 复核与本次选择

D4f只把表项详细诊断分拍，头字及写错误支路仍当拍调用remember并写word/index；因此剩余快照D端仍有 `complete_word={sd_byte,word}`、frames/cursor/index等数据来源。旧代理检查只从assembly出发、且使用与TD不同的映射，不能保证完整诊断锥或TD寄存器合并/布线结果。不能据此断言TD报告必然指向旧固件，也不能据分拍表项支路已通过逻辑仿真就宣布mem_clk干净。

采用用户指定的最小方案：**删除word/index数据快照与D4f候选数据寄存器，不叠加SD、仲裁或物理侧口改动；不改SD频率和时序约束，不使用false_path/set_max_delay豁免。**

## 2. 生产RTL改动

- `yingxu_yxv_loader.v`：删除remember任务及其全部调用，删除diag_entry_flags/off/size/index、diag_audio_end等候选寄存器。debug_word32/debug_index10保留兼容端口但常量0，不再是寄存器。
- loader reason只观察已有**功能寄存器**invalid/error_code，在拒绝后下一MEM拍锁存首个reason；不重复读取assembly/SD byte、不重复执行数据比较。92时以已推进的count[5:2]直接得到头字段原因1…8；93统一B8（表项/范围校验）；91为20（SDRAM写错）；其他保留BF。无格式拒绝的9F等故障reason仍0。
- `yingxu_yxv_pipeline.v`：删除MEM frozen_word/frozen_index及SYS fail_word/fail_index寄存器，兼容输出常量0。保留phase/reason/等待flags/ACC冻结，保留D4e在owned释放前公开首fault的机制及全部退场逻辑。
- `hardware_test_P0_UART_V5_CRC32.v`：删除D5坏字段输出选择；RSP恢复仅用D4c首magic或原SPI响应。wrapper接口无修改。

诊断原因比拒绝事件晚1拍。即使首次错误在扇区最后一字节且done已提前到达：T判错/置invalid与error_code，T+1从这些寄存器发布reason并最早置loader_failed，T+2 pipeline fault，T+3首fault冻结，原因仍及时稳定。正常校验、SD/SDRAM握手、帧表、PCM/JPEG数据与pix域均不变。

## 3. 本版遥测契约

| 字段 | D4g |
|---|---|
| MISE | 仍为高byte阶段、低byte精确fault/error，owned未释放也可见 |
| SP高byte | 头字1…8；表项/范围统一B8；SDRAM写错20；无校验原因0 |
| SP低byte | 沿用D4d等待标志，不承诺坏字段/具体表项细因 |
| ACC | 当前传输已收字节数mod2048，保留 |
| LS/F | 沿用D4e reset/init/owned/busy门禁信息 |
| 故障时WC/RDT/I1 | 常量0；不再是帧数、坏表项编号或坏字节值 |
| RSP | 不再出现D5坏字段；D4首magic保留值仍有效，其捕获在SYS域且沿用D4c，不能当作实时CMD响应 |

例如表项错误将显示 `MISE=3993 SP=B8CE WC=000`；坏头word0为 `MISE=3992 SP=01CE`。此前黑屏的949F仍表示PCM写接受后的等待，SP原因0、ACC为模2048；本版没有修改这一故障判定或宣称其已修复。

## 4. 自动验证与范围

- `python tools/yxv_diagnostics_verify.py`：27例；8个头字、PCM尾巴+3996B、各类坏表与多错误、最后字节错误/早同晚done、缺done/缺字节。仍逐项校验phase/reason/flags/count及复位后保留，另断言word/index恒0。原坏表细因有意降为B8，不能把通过表述成保留了原11…17细因。
- `python tools/yxv_pending_verify.py` / `python tools/yxv_d3_verify.py --pending`：退场未完成时仍公开首fault；使用真实UART检查MISE/LS/F。
- `python tools/yxv_d3_verify.py --bad 1`：实际top/UART，检查MISE3992/SP01CE、WC/RDT/I1为0、RSP为D4首magic且没有D5；干净回照片。
- `python tools/yxv_d3_verify.py --frames 2`：正常短程RGB565/HDMI音频/AV/退出回归；不冒充3秒播放。
- `python tools/yxv_d3_units.py`：物理侧口、36/512帧表/PCM/回绕、scanout与PCM单元。
- `python tools/yxv_d4g_structure.py`：与ecd1bbf对照原生LUT代理，自动检查word/index端口全0、reason输入锥没有未经寄存的assembly或sd_byte来源。检查对象包含两类原始数据源，仍不将该代理检查称为TD时序通过。

只运行与诊断删除相关的检查及既有功能回归；不重复D4f耗时的7594物理预载并冒称D4g实测。7594无溢出及D4f预载证据保留历史，当前阶段的硬门禁是诊断删减后的TD结果。

## 5. 本地验收后才烧写

TD必须确认mem_clk/clk2=100MHz **零负slack**；同时确认debug_word_reg/debug_index_reg、候选数据寄存器与frozen_word/frozen_index数据寄存器已移除。若仍报告这些端点，核对综合顶层/源码绝对路径、网表和最终位流的对应关系；不能只看LUT变化判门禁通过。若出现新的reason/phase路径违例，同样停在门禁，不烧写。

mem_clk零违例后才按用户既定方案板测。若楔死消失再结时序问题；若仍949F，用这版简化诊断继续PCM写等待二分。云端没有TD，交付不宣称门禁已过、也不生成板上固件。


## 软件交付结果（生产RTL 6e84711）

27例全部通过，word/index全零；头字原因1…8与表项B8在退场/MEM复位后保留。实际UART坏头：MISE3992/SP01CE/ACC200/WC000/RDT00/I1000000/RSPD400585631；pending：MISE929F/LS6/FA，owned1/failed0仍能看首fault。正常短程4001采样、0/2丢帧、AV1849/2000、460800写字和1985280扫描像素零diff、HDMI4000样本零diff、采样误差0ppm、退出照片一次；36/512帧表/PCM/回绕与相关单元通过。

loader原生代理1338→1080 LUT4（−258）、668→522寄存器（−146）、BRAM2→2；pipeline另删除MEM/SYS两份word/index寄存器，不把loader代理当作全工程TD增量。word/index常量端口与reason无raw assembly/SD byte直达组合来源的检查通过。原始日志、源码哈希与 [verification.json](evidence/D4g/verification.json) 见 [evidence/D4g](evidence/D4g)。**TD零违例仍未由云端验证，不以代理结果宣布门禁通过。**
