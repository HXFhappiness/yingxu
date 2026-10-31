# tb/testvectors — MJPEG 解码器仿真向量

由 `tools/video2yxv.py` 生成（源: ffmpeg lavfi testsrc2 + 时域噪声 + 440Hz 正弦音），
`tools/yxv_extract.py` 校验/提取。

| 文件 | 内容 | 用途 |
|---|---|---|
| `testvec_stress.yxv` | 640x480@24, 36帧, 均 59.6KB/帧, 4:2:0 baseline | 解码压力档（Huffman/IDCT 高系数密度） |
| `testvec_budget.yxv` | 640x480@24, 36帧, 均 45.3KB/帧 | **带宽预算档**：总码率 1.30MB/s = 12.5MHz SPI 实测预算线 |
| `ref_stress_f000.rgb` | 921600B = 640*480*3 RGB24 | 帧 0 的 ffmpeg 参考解码输出（逐像素比对基准） |
| `ref_stress_f001.rgb` | 同上 | 帧 1 参考输出 |
| `ref_budget_f000.rgb` | 同上 | 预算档帧 0 参考输出 |

## tb_mjpeg 判据建议

1. 从 YXV 帧表取帧 0（frames_off=512, 表项 `<II` offset,len）
2. 硬件解码输出 RGB vs `ref_*.rgb`：**PSNR >= 35dB**（JPEG 有损参考本身由 ffmpeg 生成，
   实现正确的 IDCT/上采样应达 38dB+，35dB 留色度相位裕量）
3. 边界用例：截断帧（去掉 EOI 后 16B）、坏 Huffman 表——不挂死、不越界写
4. 帧尺寸均 <64KB → 单帧 128 扇区以内，SDRAM 环形缓冲 2 帧深度即可

## 已板测定案（P1, 2026-10-31）

- SPI 12.5MHz + 传统两拍排空 = 卡带 WC=25C PASS
- 25MHz 本卡无响应（默认速度模式规格上限），**视频带宽按 12.5MHz 预算: 有效 ~1.3MB/s**
- `testvec_budget.yxv` 的 1.30MB/s 即按此线设计的"贴线"向量
