#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cosim_diff.py — 比对 yxem 黄金轨迹与 RTL 轨迹
用法: python cosim_diff.py gold.txt rtl.txt
"""
import sys

g = open(sys.argv[1]).read().splitlines()
r = open(sys.argv[2]).read().splitlines()
n = min(len(g), len(r))
print(f'gold={len(g)} rtl={len(r)} compare={n}')
mism = 0
for i in range(n):
    if g[i] != r[i]:
        mism += 1
        if mism <= 3:
            print(f'-- line {i+1} --')
            print(' gold:', g[i])
            print(' rtl :', r[i])
if mism == 0:
    print('COSIM: MATCH - %d instructions zero-diff' % n)
    sys.exit(0)
print(f'COSIM: {mism} MISMATCHES in first {n}')
sys.exit(1)
