# D4c 设计与验收

基线25ea857；先设计后实现。默认入口77，E7保留诊断兼容入口，均经相同handoff。只改自研RTL，SPI12.5MHz/两拍和厂商初始化协议不变。

## 三道闸

1. 请求视频即冻结新的照片/音乐/卡带restart。探针增加显式handoff禁止启动/清排队请求，持续到视频owned。在途SD事务继续读完，handoff阶段ready强制1以防旧消费者停用后反压死锁；至少两SYS周期清队列后才允许管线申请owned。只有init_done且!busy才能claim。owned后只有邮箱命令能restart，地址/count在请求前稳定，首读固定3000000/1。删除D4b入口裸脉冲。
2. 不把读done当init_done。SEEN=1证明init_done曾到达，0x92是YXV头校验失败；失败后的OFF=0/RSP全FF不能还原此前初始化过程。尚不能从现有证据确定真机SPI零响应机制。增加首请求/首4字节取证；不重写厂商init，不承诺其电气修复。保持原上电等待、flush及硬件重试。
3. pending/owned/失败回退均使有效游戏模式关闭；video_owned选择在原player输出寄存器入口，sprite表通过既有清除逻辑释放。退出/失败触发一次照片重载，不再受原game_mode限制；退出后照片保持至用户改变SW7/4/5/6基础模式。恢复其他组合的原游戏合成，不增加最终pix组合级。

handoff取消未接受请求，不取消已接受事务；物理内存/SD完成后才释放owned。失败sticky，拨出再进入才重试。照片加载器在owned期间复位，退出照片reload从头开始。写FIFO只在视频占有时清理，旧照片数据仅可在PCM预载前留下无效内容，不允许进入视频帧缓冲。

## 自动验收

- 默认77及兼容E7：真实top预算向量3秒，丢帧0/72、AV<2000采样，实际compositor、HDMI PCM逐点一致，UART新SW断言一致。
- 冷启动、初始化期间进入、旧SD busy期间进入：排队旧restart被清、在途读取完成、首个视频请求LBA3000000/count1，首4字节59585631，不能以新消费者接收旧事务。
- 坏头/noinit在77/E7均有限退出，一次照片reload；noinit不强行伪造init_done。
- 照片/WAV48/44.1/卡带分别回归；不计CPU cosim基线为通过。
- TD/板测用户执行，保留综合层次以核实DSP0/BRAM41是否包含完整decoder。旧3秒E7证据保持历史，不冒充D4c。

## 实现检查点

已实现quiesce清排队/在途排空、77/E7同路请求、有效游戏模式/照片回退、owned期间BMP/FIFO失效。HANDOFFCHK、77/E7坏头回退、77 noinit及三路原回归已过；完整3秒仍运行，不提前标通过。退出后照片保持，改变SW7/4/5/6基础模式返回原选择。

板上取证字段：视频首请求后OFF=Dxxxxxxx（低28位为首LBA，预期D02DC6C0）；WC为首count低10位（预期001）；实际收到头4字节后RSP=D4xxxxxxxx（预期D459585631），此前保留原SPI RSP。F改为{owned,init_done,busy,handoff}；旧F是cart_flags，不能作为旧版claim证明。失败时首请求/头保留，I0错误码保持；不再用DNE推断init。
