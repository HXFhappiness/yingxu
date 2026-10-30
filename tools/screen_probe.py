# -*- coding: utf-8 -*-
"""screen_probe.py — 分析采集卡抓到的画面，用数值描述"屏幕上有什么"

能力：
  * 解码 PNG（纯 zlib，无第三方依赖）
  * 找出画面中与背景明显不同的**连通色块**，输出边界框/中心/尺寸/平均色
  * 可选两帧对比，标记变化区域（判断闪烁/动画）

用法：
  python tools/screen_probe.py snap.png
  python tools/screen_probe.py snap.png --min-area 200 --top 12
  python tools/screen_probe.py a.png --diff b.png
"""
import sys, zlib, struct, os

# ------------------------------------------------------------------ PNG 解码

def read_png(path):
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit('not a png')
    pos, w, h, bd, ct = 8, 0, 0, 8, 6
    idat = bytearray()
    while pos < len(data):
        ln = struct.unpack('>I', data[pos:pos+4])[0]
        tag = data[pos+4:pos+8]
        body = data[pos+8:pos+8+ln]
        pos += 12 + ln
        if tag == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', body[:10])
        elif tag == b'IDAT':
            idat += body
        elif tag == b'IEND':
            break
    if bd != 8 or ct not in (2, 6):
        raise SystemExit(f'unsupported png: bitdepth={bd} colortype={ct}')
    nch = 3 if ct == 2 else 4
    raw = zlib.decompress(bytes(idat))
    stride = w * nch
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p+stride]); p += stride
        if f == 1:
            for i in range(nch, stride):
                line[i] = (line[i] + line[i-nch]) & 0xFF
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                a = line[i-nch] if i >= nch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = line[i-nch] if i >= nch else 0
                b = prev[i]
                c = prev[i-nch] if i >= nch else 0
                pp = a + b - c
                pa, pb, pc = abs(pp-a), abs(pp-b), abs(pp-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out[y*stride:(y+1)*stride] = line
        prev = line
    return w, h, nch, bytes(out)


def px(buf, nch, w, x, y):
    o = (y*w + x) * nch
    return buf[o], buf[o+1], buf[o+2]


# ------------------------------------------------------------------ 色块检测

def quant(c, q=32):
    return (c[0]//q, c[1]//q, c[2]//q)


def components(w, h, nch, buf, bg, tol=26, min_area=120, step=2):
    """网格化连通域：与背景色差异超过 tol 的像素视为前景"""
    gw, gh = (w + step - 1)//step, (h + step - 1)//step
    fg = [[False]*gw for _ in range(gh)]
    cols = [[None]*gw for _ in range(gh)]
    for gy in range(gh):
        for gx in range(gw):
            x, y = gx*step, gy*step
            if x >= w or y >= h:
                continue
            c = px(buf, nch, w, x, y)
            if abs(c[0]-bg[0]) + abs(c[1]-bg[1]) + abs(c[2]-bg[2]) > tol:
                fg[gy][gx] = True
                cols[gy][gx] = c
    seen = [[False]*gw for _ in range(gh)]
    comps = []
    for gy in range(gh):
        for gx in range(gw):
            if not fg[gy][gx] or seen[gy][gx]:
                continue
            stack = [(gx, gy)]
            seen[gy][gx] = True
            n = 0
            x0 = x1 = gx
            y0 = y1 = gy
            r = g = b = 0
            while stack:
                cx, cy = stack.pop()
                n += 1
                c = cols[cy][cx]
                r += c[0]; g += c[1]; b += c[2]
                x0 = min(x0, cx); x1 = max(x1, cx)
                y0 = min(y0, cy); y1 = max(y1, cy)
                for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
                    nx, ny = cx+dx, cy+dy
                    if 0 <= nx < gw and 0 <= ny < gh and fg[ny][nx] and not seen[ny][nx]:
                        seen[ny][nx] = True
                        stack.append((nx, ny))
            area = n * step * step
            if area >= min_area:
                comps.append(dict(
                    x=x0*step, y=y0*step,
                    w=(x1-x0+1)*step, h=(y1-y0+1)*step,
                    area=area,
                    color=(r//n, g//n, b//n)))
    comps.sort(key=lambda c: -c['area'])
    return comps


def hexs(c):
    return '#%02X%02X%02X' % c


def name_color(c):
    r, g, b = c
    mx, mn = max(c), min(c)
    if mx < 40: return '黑'
    if mn > 210: return '白'
    if mx - mn < 26: return '灰'
    if r >= g and r >= b:
        if g > r*0.6 and b < r*0.6: return '橙/黄' if g > r*0.8 else '橙'
        if b > r*0.5: return '粉/品红'
        return '红'
    if g >= r and g >= b:
        if r > g*0.7 and b < g*0.6: return '黄绿'
        if b > g*0.6: return '青绿'
        return '绿'
    if r > b*0.6 and g > b*0.6: return '紫'
    return '蓝'


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__); return
    path = a[0]
    min_area, top, step = 120, 12, 2
    diff = None
    i = 1
    while i < len(a):
        if a[i] == '--min-area': min_area = int(a[i+1]); i += 2
        elif a[i] == '--top': top = int(a[i+1]); i += 2
        elif a[i] == '--step': step = int(a[i+1]); i += 2
        elif a[i] == '--diff': diff = a[i+1]; i += 2
        else: i += 1

    w, h, nch, buf = read_png(path)
    print(f'{path}: {w}x{h}')
    # 背景取四角中位
    corners = [px(buf, nch, w, 2, 2), px(buf, nch, w, w-3, 2),
               px(buf, nch, w, 2, h-3), px(buf, nch, w, w-3, h-3)]
    bg = tuple(sorted(c[k] for c in corners)[1:3].__iter__().__next__() if False else
               int(sorted(c[k] for c in corners)[1]) for k in range(3))
    print(f'背景估计 {hexs(bg)}')

    comps = components(w, h, nch, buf, bg, min_area=min_area, step=step)
    print(f'前景色块 {len(comps)} 个（面积 >= {min_area}）:')
    for c in comps[:top]:
        print(f"  {name_color(c['color']):6s} {hexs(c['color'])}  "
              f"@({c['x']},{c['y']}) {c['w']}x{c['h']} 面积={c['area']}")

    if diff:
        w2, h2, n2, buf2 = read_png(diff)
        if (w2, h2) != (w, h):
            print(f'{diff}: 尺寸不同 {w2}x{h2}')
        else:
            changed = 0
            boxes = []
            for y in range(0, h, 8):
                for x in range(0, w, 8):
                    c1 = px(buf, nch, w, x, y)
                    c2 = px(buf2, n2, w2, x, y)
                    if abs(c1[0]-c2[0]) + abs(c1[1]-c2[1]) + abs(c1[2]-c2[2]) > 40:
                        changed += 1
                        boxes.append((x, y))
            print(f'{diff}: 变化采样点 {changed}')
            if boxes:
                xs = [b[0] for b in boxes]; ys = [b[1] for b in boxes]
                print(f'  变化范围 x {min(xs)}..{max(xs)}  y {min(ys)}..{max(ys)}')


if __name__ == '__main__':
    main()
