# -*- coding: utf-8 -*-
# telem.py — 读 COM4 串口遥测（115200 8N1），抓 D 行看 CPU 状态
import serial, time, sys

DUR = float(sys.argv[1]) if len(sys.argv) > 1 else 3.0
sp = serial.Serial('COM4', 115200, timeout=0.2)
t0 = time.time()
lines = []
while time.time() - t0 < DUR:
    chunk = sp.readlines()
    for ln in chunk:
        s = ln.decode('ascii', 'replace').strip()
        if s:
            lines.append(s)
sp.close()
seen = set()
out = []
for s in lines:
    k = s[:20]
    if s.startswith('D ') or s.startswith('A '):
        if k not in seen:
            seen.add(k)
            out.append(s)
    elif not out or out[-1] != s:
        out.append(s)
for s in out[-14:]:
    print(s)
