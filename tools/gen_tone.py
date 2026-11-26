# -*- coding: utf-8 -*-
# gen_tone.py — 生成测试旋律 YXMA（C 大调琶音 × 循环，正弦波，48k 立体声）
# 用途：WAV 播放器验收——听得出旋律 = 采样率/对齐/声道全对
import math, struct, sys

RATE = 48000
NOTE = 0.25          # 每音 0.25s
NOTES = [262, 330, 392, 523, 392, 330, 262, 196]   # C4 E4 G4 C5 G4 E4 C4 G3
REPEAT = 4

samples = []
for rep in range(REPEAT):
    for f in NOTES:
        n = int(RATE * NOTE)
        for i in range(n):
            v = int(12000 * math.sin(2 * math.pi * f * i / RATE))
            samples.append(v)

pcm = b''.join(struct.pack('<hh', v, v) for v in samples)   # 立体声同相

hdr = bytearray(32)
hdr[0:4] = b'YXMA'
hdr[4] = 1
hdr[5] = 2
struct.pack_into('<H', hdr, 6, 16)
struct.pack_into('<I', hdr, 8, RATE)
struct.pack_into('<I', hdr, 12, len(samples))
struct.pack_into('<I', hdr, 16, len(pcm))

out = r'C:\Users\HXF\Desktop\YX\out\test_tune.yxm'
open(out, 'wb').write(bytes(hdr) + pcm)
print('generated %s: %d frames, %.1f s, %.2f MB' %
      (out, len(samples), len(samples) / RATE, (32 + len(pcm)) / 1e6))
