# 第三方组件清单（THIRD PARTY NOTICES）

本项目在安路 AC201/AC601 评估板（EG4S20）附带示例代码的基础上构建。
以下文件/目录来自**板卡厂商示例工程**，版权归原作者所有，随原许可分发；
本仓库仅为完整性收录，自研部分见下方第二列。

## 厂商示例代码（随板附带）

| 路径 | 内容 |
|---|---|
| `al_ip/` | TD IP：PLL（HDMI/系统时钟）、FIFO 等 |
| `src/5640/` | SDRAM 控制器（四端口命令/数据通路/PLL） |
| `src/user_source/hdl_source/hdmi1.4b_transmitter_core/` | HDMI 1.4b 发送器核心（音频/视频包） |
| `src/user_source/hdl_source/hdmi_phy_warpper.v` | HDMI PHY 封装 |
| `src/user_source/hdl_source/lane_lvds_10_1.v` | TMDS 10:1 串行化 |
| `src/user_source/hdl_source/media/sd/sd_cmd_*.v` 等 | SD 卡 SPI 命令/初始化/扇区读写（命令层） |
| `src/user_source/hdl_source/media/sd/ram_dual_port_simple.v` | 双口 BRAM 模板 |
| `src/user_source/hdl_source/media/bmp/` | BMP 头解析 |
| `src/user_source/hdl_source/audio_arc_calculate.v` | HDMI 音频包生成 |
| `src/user_source/hdl_source/I2S_receiver.v`、`video_source_test.v`、`key_remove_shakes.v` | 示例外设 |

## 自研（本项目原创）

`src/user_source/hdl_source/` 下的全部 `yingxu_*` / `yx8_*` 模块：
YX-8 CPU 与卡带 SOC、WAV(YXMA) 播放器、PSG 音效、精灵引擎、图块层、
两款游戏硬件加速、BMP 加载与 SDRAM 帧缓冲封装、SD **流式读取层**
（`media/sd/sd_stream_reader*.v`，在厂商命令层之上实现）、SD 集成探针、
OSD/覆盖层；顶层 `hardware_test_P0_UART_V5_CRC32.v` 与
`design_top_wrapper.v`（集成与混音）；`tb/` 全部测试台；`tools/` 全部脚本
（汇编器、模拟器、写卡、遥测、画板）。

> 说明：SD 卡命令层（厂商）与本项目的流式读取层（自研）通过标准
> ready/valid 握手衔接，边界清晰可查（`sd_stream_reader_core.v`）。
