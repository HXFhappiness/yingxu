# -*- coding: utf-8 -*-
"""tilekit.py — 图块表 / 关卡网格 工具

用法：
  python tilekit.py --template tiles_xxx.png     生成 256x256 图块表模板（16x16 格线）
  python tilekit.py --check tiles_xxx.png        检查图块表规格（256x256、16 对齐、色数）
  python tilekit.py --level-template lvl.txt     生成 240x15 关卡模板
  python tilekit.py --level-check lvl.txt        检查关卡网格（240x15、索引 0..255）
  python tilekit.py --slice tiles_xxx.png out/   把 256x256 切成 256 个 16x16 PNG
"""
import sys, os, struct, zlib

COLS, ROWS, TILE = 16, 16, 16
SHEET_W = COLS * TILE   # 256
SHEET_H = ROWS * TILE   # 256
LVL_W, LVL_H = 240, 15


# ---------------------------------------------------------------- PNG 读写（纯 zlib）
def write_png_rgb(path, w, h, pixels):
    """pixels: bytes, RGB 每像素 3 字节"""
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += pixels[y * w * 3:(y + 1) * w * 3]
    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data +
                struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    open(path, 'wb').write(png)


def read_png(path):
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit('不是 PNG')
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
    if bd != 8 or ct not in (2, 3, 6):
        raise SystemExit(f'不支持的 PNG: bitdepth={bd} colortype={ct}')
    nch = {2: 3, 3: 1, 6: 4}[ct]
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
    return w, h, nch, ct, bytes(out)


# ---------------------------------------------------------------- 模板
def make_template(path):
    """棋盘格底色 + 16px 格线，方便按格绘制"""
    bg = [(44, 48, 60), (52, 57, 72)]
    px = bytearray(SHEET_W * SHEET_H * 3)
    for y in range(SHEET_H):
        for x in range(SHEET_W):
            c = bg[((x // TILE) + (y // TILE)) & 1]
            o = (y * SHEET_W + x) * 3
            px[o:o+3] = bytes(c)
    # 格线
    line = (140, 205, 255)
    for y in range(SHEET_H):
        for x in range(SHEET_W):
            if x % TILE == 0 or y % TILE == 0:
                o = (y * SHEET_W + x) * 3
                px[o:o+3] = bytes(line)
    write_png_rgb(path, SHEET_W, SHEET_H, bytes(px))
    print(f'已生成图块表模板 {path} ({SHEET_W}x{SHEET_H}, {COLS}x{ROWS} 格，每格 {TILE}px)')


def check_tileset(path):
    w, h, nch, ct, buf = read_png(path)
    ok = True
    print(f'{path}: {w}x{h} colortype={ct}')
    if w != SHEET_W or h != SHEET_H:
        print(f'  ✗ 尺寸应为 {SHEET_W}x{SHEET_H}（16x16 格 × 16px）'); ok = False
    else:
        print(f'  ✓ 尺寸正确（{COLS}x{ROWS} 格）')
    if ct == 3:
        print('  ✓ 索引色 PNG（推荐）')
    else:
        print('  · 非索引色，请在导出时转成 8 位索引 + YX-256 调色板')
    # 统计颜色
    colors = set()
    for i in range(0, len(buf) // nch):
        o = i * nch
        colors.add(buf[o:o+3])
        if len(colors) > 300:
            break
    print(f'  · 采样到 {len(colors)} 种颜色（建议 ≤256）')
    if len(colors) > 256:
        print('  ✗ 颜色超过 256，请用 YX-256 重新量化'); ok = False
    return ok


def slice_sheet(path, outdir):
    w, h, nch, ct, buf = read_png(path)
    os.makedirs(outdir, exist_ok=True)
    n = 0
    for ty in range(h // TILE):
        for tx in range(w // TILE):
            px = bytearray()
            for y in range(TILE):
                for x in range(TILE):
                    o = ((ty*TILE + y) * w + (tx*TILE + x)) * nch
                    px += buf[o:o+3]
            p = os.path.join(outdir, f'tile_{ty*COLS+tx:03d}.png')
            write_png_rgb(p, TILE, TILE, bytes(px))
            n += 1
    print(f'已切出 {n} 个 {TILE}x{TILE} 图块到 {outdir}')


# ---------------------------------------------------------------- 关卡
def make_level_template(path):
    rows = []
    for y in range(LVL_H):
        if y >= LVL_H - 2:
            rows.append('1' * LVL_W)      # 底部两行地面
        else:
            rows.append('0' * LVL_W)      # 其余天空
    open(path, 'w', encoding='utf-8', newline='\n').write('\n'.join(rows) + '\n')
    print(f'已生成关卡模板 {path}（{LVL_W}x{LVL_H}，0=空 1=地面，十六进制字符）')


def check_level(path):
    txt = open(path, encoding='utf-8').read().split('\n')
    rows = [r.strip() for r in txt if r.strip()]
    ok = True
    print(f'{path}: {len(rows)} 行')
    if len(rows) != LVL_H:
        print(f'  ✗ 行数应为 {LVL_H}'); ok = False
    bad = 0
    for i, r in enumerate(rows):
        if len(r) != LVL_W:
            print(f'  ✗ 第 {i+1} 行长度 {len(r)}，应为 {LVL_W}'); ok = False
        for ch in r:
            if ch not in '0123456789abcdefABCDEF':
                bad += 1
    if bad:
        print(f'  ✗ 有 {bad} 个非法字符（只允许 0-9a-f）'); ok = False
    if ok:
        print('  ✓ 关卡网格格式正确')
    return ok


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__); return
    if a[0] == '--template':
        make_template(a[1] if len(a) > 1 else 'tiles_new_256x256.png')
    elif a[0] == '--check':
        check_tileset(a[1])
    elif a[0] == '--slice':
        slice_sheet(a[1], a[2] if len(a) > 2 else 'tiles_out')
    elif a[0] == '--level-template':
        make_level_template(a[1] if len(a) > 1 else 'level_new.txt')
    elif a[0] == '--level-check':
        check_level(a[1])
    else:
        print(__doc__)


if __name__ == '__main__':
    main()
