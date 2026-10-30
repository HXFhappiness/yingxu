# -*- coding: utf-8 -*-
# gen_tb_tune.py — 生成短测试 YXMA（0.5s 的 262Hz + 0.5s 的 392Hz，供仿真用）
import math, struct

RATE = 48000
out = []
for f, dur in ((262.0, 0.25), (392.0, 0.25)):
    n = int(RATE * dur)
    for i in range(n):
        v = int(12000 * math.sin(2 * math.pi * f * i / RATE))
        out.append(v)

pcm = b''.join(struct.pack('<hh', v, v) for v in out)
hdr = bytearray(32)
hdr[0:4] = b'YXMA'
hdr[4] = 1
hdr[5] = 2
struct.pack_into('<H', hdr, 6, 16)
struct.pack_into('<I', hdr, 8, RATE)
struct.pack_into('<I', hdr, 12, len(out))
struct.pack_into('<I', hdr, 16, len(pcm))

p = r'C:\Users\HXF\Desktop\YX\out\tb_tune.yxm'
open(p, 'wb').write(bytes(hdr) + pcm)
print('tb_tune.yxm: %d samples, %d bytes' % (len(out), 32 + len(pcm)))
