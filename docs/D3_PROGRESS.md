# D3 分步记录

2026-11-01，基线a35f9ef；TD/板测由用户本地完成，以下均为软件仿真。

- 文档027060b已推；物理适配917d97e已推。真实自研四口状态机+原样厂商command/control_interface/data_path参与，逻辑1…8word→固定8物理word，DQM保护尾字，读写反压及显示优先级通过。测试模型替代PLL/FIFO/SDRAM介质，不替代自研调度或done。
- SD供给单元：YXV表36帧、288000B PCM预载逐字节零diff，JPEG槽0/1/2与原帧表逐字节一致；坏magic读完整扇区后错误92，停止后续请求。默认SD探针仍5401扇区，动态LBA/count入口只在显式启用时生效。

原始输出（tb_yxv_loader，Verilator，exit0）：

```text
SUPPLYCHK: PASS frames=36 PCM=288000 bytes zero-diff JPEG=0,1,2 exact table-indexed commands=5
HEADERCHK: PASS bad magic code=92 finite reject drained-SD
```

后续：连接100/50MHz CDC、显示消隐交换、WAV字节适配、顶层开关/遥测与3秒验收。尚未宣布D3整体验收通过。

## 显示单元

`tb_yxv_scanout`双缓冲窗口检查：frame0红/蓝、frame1绿/白，高半字先出，消隐才交换，LOAD保持256pix周期覆盖旧128字物理burst尾部；新端口开启且视频活动时RD2 FIFO复位，旧参数关闭行为保持。颜色选择在原player的既有RGB输出寄存器入口，不串入亮度/对比度或sprite组合链。

```text
SCANOUTCHK: PASS centered640x480 high-half-first both banks pixels=306240/305602 vblank swaps=2 stretched flush no-underflow
```

该单元测试覆盖窗口内部并剔除流水边沿，完整图像/帧率/AV仍以最终顶层3秒TB为门禁。
