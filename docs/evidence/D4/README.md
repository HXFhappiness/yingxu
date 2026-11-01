# D4审查证据

测试编译版本372005d，SW=77，实际板级top、原SD服务模型，命令 `python tools/yxv_d3_verify.py --frames 2`。程序非零退出，复现实际compositor覆盖视频。不是612fe6c重跑，也不是SPI/板测日志。用户D4b代码随后快进合入，审查见 ../../D4_REVIEW.md。
