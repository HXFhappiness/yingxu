# -*- coding: utf-8 -*-
"""track.py — 逐帧追踪指定颜色的精灵位置，用于判断"斜着飞"/漂移/闪烁

用法: python tools/track.py out/track_01.png out/track_02.png ...
输出: 每帧里 绿/黄/红/青 色块的 (x,y) 列表
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from screen_probe import read_png, px, components

NAMES = {'绿': (0x06, 0xFF, 0x06), '黄': (0xFF, 0xFF, 0x06),
         '红': (0xEB, 0x00, 0x00), '青': (0x03, 0xFF, 0xFF),
         '白': (0xFF, 0xFF, 0xFF)}


def classify(c):
    best, bd = None, 1e9
    for name, ref in NAMES.items():
        d = abs(c[0]-ref[0]) + abs(c[1]-ref[1]) + abs(c[2]-ref[2])
        if d < bd:
            bd, best = d, name
    return best if bd < 140 else None


def frame_boxes(path):
    w, h, nch, buf = read_png(path)
    bg = (0, 0, 0)
    comps = components(w, h, nch, buf, bg, tol=60, min_area=120, step=2)
    out = []
    for c in comps:
        n = classify(c['color'])
        if n:
            out.append((n, c['x'], c['y'], c['w'], c['h']))
    return out


def main():
    files = sys.argv[1:]
    if not files:
        print(__doc__); return
    for f in files:
        boxes = frame_boxes(f)
        groups = {}
        for n, x, y, w, h in boxes:
            groups.setdefault(n, []).append((x, y))
        parts = []
        for n in ('绿', '黄', '红', '青', '白'):
            if n in groups:
                pts = sorted(groups[n])
                parts.append(f'{n}=' + ','.join(f'({x},{y})' for x, y in pts))
        print(os.path.basename(f), ' | '.join(parts))


if __name__ == '__main__':
    main()
