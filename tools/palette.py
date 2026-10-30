# -*- coding: utf-8 -*-
"""palette.py — 《映序主色板》YX-256 生成器与转换工具（零依赖）

硬件事实（务必先读 docs/PALETTE_YINGXU.md）：
  * 精灵颜色寄存器 0xEF/0xF0 = 16 位 RGB565（R5 G6 B5），不是 24 位。
  * 砖块层/背景为 RGB888，但精灵与卡带只能写 RGB565。
  => 所以主色板**以 RGB565 为准**定义，RGB888 只是它的精确展开。

用法:
  python palette.py --table                 打印完整 256 色表
  python palette.py --markdown             打印 Markdown 表（贴文档用）
  python palette.py --asm name.asm         生成 .byte 常量（每色 2 字节）
  python palette.py --index 0x2A           查询单色
  python palette.py --nearest "#3F7FBF"    给定 RGB888 找最近色号
  python palette.py --check img.bmp        校验 8 位索引 BMP 的所有色号
  python palette.py --emit-rects img.bmp   把 8 位索引 BMP 转成矩形列表（.byte）

索引布局（256 项，每项 2 字节 RGB565，小端）:
  0x00-0x0F  16 级灰阶 (YX_GRAY_0..15)
  0x10-0x1F  16 个基础/语义色 (YX_BASE_*)
  0x20-0x9F  16 个色系 x 8 级明暗 (YX_<HUES>_1..8)
  0xA0-0xBF  4 个材质系 x 8 级 (皮肤/木/金属/石)
  0xC0-0xDF  8 个霓虹系 x 4 级
  0xE0-0xEF  16 个 UI 语义色
  0xF0-0xFE  保留（不要用）
  0xFF      TRANSPARENT 标记（不是颜色，写进图里表示"跳过/透明"）
"""
import sys, math, struct

# ---------------------------------------------------------------- 基础工具

def q565(r, g, b):
    """RGB888 -> RGB565（四舍五入）"""
    return ((r * 31 + 127) // 255) << 11 | ((g * 63 + 127) // 255) << 5 | ((b * 31 + 127) // 255)


def un565(c):
    """RGB565 -> RGB888（位复制展开，与 HDMI 输出一致）"""
    r5 = (c >> 11) & 0x1F
    g6 = (c >> 5) & 0x3F
    b5 = c & 0x1F
    r = (r5 << 3) | (r5 >> 2)
    g = (g6 << 2) | (g6 >> 4)
    b = (b5 << 3) | (b5 >> 2)
    return r, g, b


def hsv(h, s, v):
    """HSV(0-360, 0-1, 0-1) -> RGB888，避免依赖 colorsys 的舍入差异"""
    h = h % 360.0
    c = v * s
    x = c * (1 - abs((h / 60.0) % 2 - 1))
    m = v - c
    if   h < 60:  r, g, b = c, x, 0
    elif h < 120: r, g, b = x, c, 0
    elif h < 180: r, g, b = 0, c, x
    elif h < 240: r, g, b = 0, x, c
    elif h < 300: r, g, b = x, 0, c
    else:         r, g, b = c, 0, x
    return (int(round((r + m) * 255)), int(round((g + m) * 255)), int(round((b + m) * 255)))


# ---------------------------------------------------------------- 色板定义

HUES = [                      # (名字, 色相, 基础饱和度)
    ("CRIMSON",  352, 0.86),
    ("VERMILION", 18, 0.88),
    ("ORANGE",    32, 0.90),
    ("AMBER",     45, 0.82),
    ("YELLOW",    55, 0.78),
    ("LIME",      85, 0.74),
    ("GREEN",    125, 0.78),
    ("TEAL",     168, 0.76),
    ("CYAN",     186, 0.80),
    ("AZURE",    202, 0.78),
    ("BLUE",     222, 0.82),
    ("INDIGO",   244, 0.80),
    ("VIOLET",   266, 0.82),
    ("PURPLE",   288, 0.80),
    ("MAGENTA",  312, 0.82),
    ("PINK",     336, 0.72),
]

MATERIALS = [                 # (名字, 色相, 饱和, 明度缩放, 明度偏移)
    ("SKIN",   26, 0.42, 0.95,  0.03),
    ("WOOD",   30, 0.62, 0.90,  0.00),
    ("METAL", 212, 0.14, 1.00,  0.00),
    ("STONE", 220, 0.07, 0.85,  0.02),
]

NEONS = [                     # (名字, 色相)
    ("NEON_GREEN", 118), ("NEON_CYAN", 180), ("NEON_BLUE", 225), ("NEON_PURPLE", 282),
    ("NEON_PINK", 318),  ("NEON_RED", 356),  ("NEON_LIME", 72),  ("NEON_AMBER", 40),
]

# 8 级明暗阶梯：越亮越淡（像素画的经典 ramp：暗部浓、亮部偏白）
SHADE_V = [0.16, 0.28, 0.40, 0.53, 0.66, 0.78, 0.89, 1.00]
SHADE_S = [0.92, 0.92, 0.88, 0.82, 0.74, 0.63, 0.48, 0.30]

BASE16 = [
    ("BLACK",    0,   0,   0),
    ("WHITE",  255, 255, 255),
    ("RED",    255,   0,   0),
    ("GREEN",    0, 255,   0),
    ("BLUE",     0,   0, 255),
    ("CYAN",     0, 255, 255),
    ("MAGENTA", 255,   0, 255),
    ("YELLOW",  255, 255,   0),
    ("ORANGE",  255, 128,   0),
    ("LIME",    128, 255,   0),
    ("TEAL",     0, 128, 128),
    ("AZURE",    0, 128, 255),
    ("INDIGO",  64,   0, 255),
    ("PURPLE", 128,   0, 255),
    ("PINK",    255, 128, 192),
    ("BROWN",   128,  96,  64),
]

UI16 = [                      # 0xE0-0xEF
    ("UI_BG",        12,  14,  22),
    ("UI_BG_ALT",    20,  24,  36),
    ("UI_PANEL",     32,  38,  56),
    ("UI_BORDER",    66,  76, 104),
    ("UI_TEXT",     232, 236, 248),
    ("UI_TEXT_DIM", 144, 152, 176),
    ("UI_ACCENT",    56, 224, 248),
    ("UI_OK",        72, 224, 120),
    ("UI_WARN",     248, 200,  56),
    ("UI_ERROR",    248,  72,  72),
    ("UI_INFO",     112, 168, 248),
    ("UI_SHADOW",    10,  10,  16),
    ("UI_HILITE",   255, 255, 255),
    ("UI_FOCUS",    248, 240, 120),
    ("UI_DISABLED",  88,  96, 112),
    ("UI_MASK",      24,  26,  40),
]

TRANSPARENT = 0xFF


def build_palette():
    """返回 256 项 (索引, 名字, RGB565, RGB888)"""
    pal = {}
    names = {}

    # 0x00-0x0F 灰阶：先在 RGB888 上等分，再量化到 565（展开后仍中性）
    for i in range(16):
        v = i * 17
        r5 = (v * 31 + 127) // 255
        g6 = (v * 63 + 127) // 255
        c = (r5 << 11) | (g6 << 5) | r5
        pal[0x00 + i] = c
        names[0x00 + i] = f"YX_GRAY_{i}"

    # 0x10-0x1F 基础色
    for i, (nm, r, g, b) in enumerate(BASE16):
        pal[0x10 + i] = q565(r, g, b)
        names[0x10 + i] = f"YX_{nm}"

    # 0x20-0x9F 16 色系 x 8 级
    for fi, (hname, hue, sat) in enumerate(HUES):
        base = 0x20 + fi * 8
        for si in range(8):
            r, g, b = hsv(hue, sat * SHADE_S[si], SHADE_V[si])
            pal[base + si] = q565(r, g, b)
            names[base + si] = f"YX_{hname}_{si + 1}"

    # 0xA0-0xBF 材质 x 8 级
    for fi, (mname, hue, sat, vs, vo) in enumerate(MATERIALS):
        base = 0xA0 + fi * 8
        for si in range(8):
            v = min(1.0, SHADE_V[si] * vs + vo)
            r, g, b = hsv(hue, sat * (0.55 + 0.45 * SHADE_S[si]), v)
            pal[base + si] = q565(r, g, b)
            names[base + si] = f"YX_{mname}_{si + 1}"

    # 0xC0-0xDF 霓虹 x 4 级
    for fi, (nname, hue) in enumerate(NEONS):
        base = 0xC0 + fi * 4
        for si in range(4):
            v = [0.42, 0.64, 0.84, 1.00][si]
            r, g, b = hsv(hue, [0.95, 0.88, 0.72, 0.48][si], v)
            pal[base + si] = q565(r, g, b)
            names[base + si] = f"YX_{nname}_{si + 1}"

    # 0xE0-0xEF UI
    for i, (uname, r, g, b) in enumerate(UI16):
        pal[0xE0 + i] = q565(r, g, b)
        names[0xE0 + i] = f"YX_{uname}"

    # 0xF0-0xFE 保留（填中性值，禁止使用）
    for i in range(0xF0, 0xFF):
        pal[i] = 0x0000
        names[i] = "YX_RESERVED"

    pal[TRANSPARENT] = 0x0000
    names[TRANSPARENT] = "YX_TRANSPARENT"
    return pal, names


PAL, NAMES = build_palette()


# ---------------------------------------------------------------- 查询/输出

def fmt565(c):
    return f"0x{c:04X}"


def fmt_rgb888(c):
    r, g, b = un565(c)
    return f"#{r:02X}{g:02X}{b:02X}"


def cmd_table():
    print(f"{'idx':>5} {'name':<20} {'RGB565':>7} {'RGB888':>8}  R5 G6 B5")
    for i in range(256):
        c = PAL[i]
        r5, g6, b5 = (c >> 11) & 0x1F, (c >> 5) & 0x3F, c & 0x1F
        print(f"0x{i:02X}  {NAMES[i]:<20} {fmt565(c):>7} {fmt_rgb888(c):>8}  {r5:2d} {g6:2d} {b5:2d}")


def cmd_markdown():
    print("| 色号 | 名称 | RGB565 | RGB888 |")
    print("|---|---|---|---|")
    for i in range(256):
        c = PAL[i]
        print(f"| `0x{i:02X}` | `{NAMES[i]}` | `{fmt565(c)}` | `{fmt_rgb888(c)}` |")


def cmd_asm(path, lo=0x10, hi=0x20):
    """把一段色号导出成 .byte（默认 0x10..0x1F 基础 16 色 = 32 字节）

    卡带 .data 段上限 224 字节，所以只导子色板，别导全 256 色。
    """
    lines = []
    lines.append("; ============================================================")
    lines.append("; YingXu palette slice 0x%02X..0x%02X  (generated by tools/palette.py)" % (lo, hi - 1))
    lines.append("; 2 bytes per entry, little endian: low -> SCL(0xEF), high -> SCH(0xF0)")
    lines.append("; ============================================================")
    lines.append(".data 0x50")
    lines.append("PAL:")
    for i in range(lo, hi):
        c = PAL[i]
        lines.append("    .byte 0x%02X, 0x%02X    ; 0x%02X %s %s"
                     % (c & 0xFF, (c >> 8) & 0xFF, i, NAMES[i], fmt_rgb888(c)))
    lines.append("; total %d entries = %d bytes (cart data limit is 224 bytes)"
                 % (hi - lo, (hi - lo) * 2))
    open(path, "w", encoding="ascii", newline="\n").write("\n".join(lines) + "\n")
    print("palette.py: wrote %s (%d entries, %d bytes)" % (path, hi - lo, (hi - lo) * 2))


def cmd_index(h):
    i = int(h, 0)
    c = PAL[i]
    print(f"0x{i:02X} {NAMES[i]} RGB565={fmt565(c)} RGB888={fmt_rgb888(c)}")


def cmd_nearest(rgbhex):
    s = "".join(ch for ch in rgbhex if ch.upper() in "0123456789ABCDEF")
    if len(s) < 6:
        sys.exit(f"palette.py: 颜色格式应为 RRGGBB（收到 {rgbhex!r}）")
    r, g, b = int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16)
    best, bestd = None, 1 << 30
    for i in range(0xF0):
        cr, cg, cb = un565(PAL[i])
        d = (cr - r) ** 2 * 2 + (cg - g) ** 2 * 4 + (cb - b) ** 2 * 3   # 人眼权重
        if d < bestd:
            best, bestd = i, d
    c = PAL[best]
    print(f"最近色: 0x{best:02X} {NAMES[best]} RGB565={fmt565(c)} RGB888={fmt_rgb888(c)}")


# ---------------------------------------------------------------- BMP 支持

def write_bmp_indexed(path, w, h, rows, entries=256):
    """写 8bpp 索引 BMP（调色板取主色板前 entries 项）"""
    stride = (w + 3) & ~3
    pix = bytearray()
    for y in range(h - 1, -1, -1):
        row = bytes(rows[y][:w])
        pix += row + b"\x00" * (stride - w)
    hdr = 14 + 40
    off = hdr + entries * 4
    data = b"BM" + struct.pack("<IHHI", off + len(pix), 0, 0, off)
    data += struct.pack("<IiiHHIIiiII", 40, w, h, 1, 8, 0, len(pix), 2835, 2835, entries, 0)
    for i in range(entries):
        r, g, b = un565(PAL[i])
        data += bytes([b, g, r, 0])
    data += bytes(pix)
    open(path, "wb").write(data)


def cmd_export(dirname):
    """导出美术资源包：.gpl / .act / .hex / 色卡 / 空白模板"""
    import os
    os.makedirs(dirname, exist_ok=True)

    # GIMP / Aseprite / Krita 通用
    gpl = ["GIMP Palette", "Name: YingXu256 (YX-256)", "Columns: 16", "#"]
    for i in range(256):
        r, g, b = un565(PAL[i])
        gpl.append("%3d %3d %3d\t%02X %s" % (r, g, b, i, NAMES[i]))
    open(os.path.join(dirname, "yingxu256.gpl"), "w", encoding="ascii", newline="\n").write("\n".join(gpl) + "\n")

    # Adobe 色表（Photoshop / Aseprite 的 .act）
    act = bytearray()
    for i in range(256):
        r, g, b = un565(PAL[i])
        act += bytes([r, g, b])
    open(os.path.join(dirname, "yingxu256.act"), "wb").write(bytes(act))

    # 纯 hex 列表
    open(os.path.join(dirname, "yingxu256.hex"), "w", encoding="ascii", newline="\n").write(
        "\n".join("%02X%02X%02X" % un565(PAL[i]) for i in range(256)) + "\n")

    # 色卡：16x16 个色块，每块 16x16 像素（索引图，每块填自己的色号）
    n, cell = 16, 16
    W = H = n * cell
    rows = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            idx = (y // cell) * n + (x // cell)
            rows[y][x] = idx
    write_bmp_indexed(os.path.join(dirname, "yingxu256_swatch.bmp"), W, H, rows)

    # 空白画布模板：64x64，全 0xFF（透明）
    TW = TH = 64
    write_bmp_indexed(os.path.join(dirname, "template_64x64.bmp"), TW, TH, [[TRANSPARENT] * TW for _ in range(TH)])

    # 示例：16x16 外星人（用色板色号画的示范）
    W2 = H2 = 16
    ex = [[TRANSPARENT] * W2 for _ in range(H2)]
    for y in range(H2):
        for x in range(W2):
            if (2 <= x <= 13 and 3 <= y <= 10) or (4 <= x <= 11 and 11 <= y <= 12) or (x in (3, 12) and y == 13):
                ex[y][x] = 0x13
    for x in (5, 10):
        ex[6][x] = 0x10
    write_bmp_indexed(os.path.join(dirname, "sample_alien16.bmp"), W2, H2, ex)

    print("palette.py: exported kit to", dirname)
    for f in sorted(os.listdir(dirname)):
        print("   -", f)
def read_bmp_indexed(path):
    """读 8bpp 索引 BMP → (w, h, indices[y][x], palette_used, bmp_palette)"""
    data = open(path, "rb").read()
    if data[:2] != b"BM":
        sys.exit("palette.py: 不是 BMP")
    off = struct.unpack("<I", data[10:14])[0]
    hdr = struct.unpack("<I", data[14:18])[0]
    w = struct.unpack("<i", data[18:22])[0]
    h = struct.unpack("<i", data[22:26])[0]
    bpp = struct.unpack("<H", data[28:30])[0]
    if bpp != 8:
        sys.exit(f"palette.py: 需要 8bpp 索引 BMP（当前 {bpp}bpp）")
    flip = h > 0
    h = abs(h)
    ncol = struct.unpack("<I", data[46:50])[0] or 256
    bmpal = []
    p = 14 + hdr
    for _ in range(ncol):
        b, g, r, _a = data[p], data[p + 1], data[p + 2], data[p + 3]
        bmpal.append((r, g, b))
        p += 4
    stride = (w + 3) & ~3
    rows = []
    for y in range(h):
        src = h - 1 - y if flip else y
        base = off + src * stride
        rows.append(list(data[base:base + w]))
    used = sorted({i for row in rows for i in row})
    return w, h, rows, used, bmpal


def cmd_check(path):
    w, h, rows, used, bmpal = read_bmp_indexed(path)
    print(f"{path}: {w}x{h}, 用到 {len(used)} 个索引: " + ", ".join(f"0x{i:02X}" for i in used[:24]) + (" ..." if len(used) > 24 else ""))
    bad = []
    for i in used:
        if i == TRANSPARENT:
            continue                # 0xFF = 透明标记，允许
        if i >= 0xF0:
            bad.append(f"0x{i:02X} 落在保留区(0xF0-0xFE)")
            continue
        r, g, b = bmpal[i]
        c = PAL[i]
        er, eg, eb = un565(c)
        if max(abs(r - er), abs(g - eg), abs(b - eb)) > 12:
            bad.append(f"0x{i:02X} BMP#{r:02X}{g:02X}{b:02X} != 主色板 {fmt_rgb888(c)}")
    if bad:
        print("不一致：")
        for s in bad:
            print("  -", s)
        sys.exit(1)
    print("OK: 所有索引都在主色板内且颜色一致")


def cmd_emit_rects(path):
    """把索引图压成矩形列表: 输出 x,y,w,h,idx（每项 1 字节，0xFF 结束）

    合并策略：按 (x, 宽, 色号) 建索引，竖直相邻即延长矩形。
    """
    w, h, rows, used, _ = read_bmp_indexed(path)
    rects = []                 # [x, y, w, h, idx]
    open_by_key = {}           # (x, w, idx) -> rect index
    for y in range(h):
        row = rows[y]
        x = 0
        while x < w:
            c = row[x]
            if c == TRANSPARENT:
                x += 1
                continue
            run = 1
            while x + run < w and row[x + run] == c:
                run += 1
            key = (x, run, c)
            idx = open_by_key.get(key)
            if idx is not None and rects[idx][1] + rects[idx][3] == y:
                rects[idx][3] += 1
            else:
                rects.append([x, y, run, 1, c])
                open_by_key[key] = len(rects) - 1
            x += run
    print(f"; {path}: {w}x{h} -> {len(rects)} rects (limit 16 per frame, split frames if more)")
    for (x, y, ww, hh, c) in rects:
        print(f"    .byte {x}, {y}, {ww}, {hh}, 0x{c:02X}")
    print("    .byte 0xFF")


# ---------------------------------------------------------------- main

def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return
    cmd = a[0]
    if cmd == "--table":            cmd_table()
    elif cmd == "--markdown":       cmd_markdown()
    elif cmd == "--asm":
        lo = int(a[2], 0) if len(a) > 2 else 0x10
        hi = int(a[3], 0) if len(a) > 3 else 0x20
        cmd_asm(a[1], lo, hi)
    elif cmd == "--index":          cmd_index(a[1])
    elif cmd == "--nearest":        cmd_nearest(a[1])
    elif cmd == "--check":          cmd_check(a[1])
    elif cmd == "--emit-rects":     cmd_emit_rects(a[1])
    elif cmd == "--export":         cmd_export(a[1] if len(a) > 1 else "art_kit")
    elif cmd == "--snap":           cmd_snap(a[1], a[2] if len(a) > 2 else a[1].replace(".bmp", "_idx.bmp"))
    elif cmd == "--png":            cmd_png(a[1] if len(a) > 1 else "yingxu256_swatch.png")
    elif cmd == "--js":             cmd_js()
    else:
        print(__doc__)
        sys.exit(2)



# ---------------------------------------------------------------- SAI 友好输出

def _png_chunk(tag, data):
    import zlib, struct
    c = tag + data
    return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)


def write_png_rgb(path, w, h, rows_rgb):
    """写 24 位 PNG（无依赖，zlib 即可）"""
    import zlib, struct
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for (r, g, b) in rows_rgb[y]:
            raw += bytes([r, g, b])
    png = b"\x89PNG\r\n\x1a\n"
    png += _png_chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += _png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += _png_chunk(b"IEND", b"")
    open(path, "wb").write(png)


def read_bmp_rgb(path):
    """读 24/32 位 BMP -> (w, h, [[(r,g,b), ...], ...])"""
    import struct
    d = open(path, "rb").read()
    if d[:2] != b"BM":
        sys.exit("palette.py: 不是 BMP")
    off = struct.unpack("<I", d[10:14])[0]
    w = struct.unpack("<i", d[18:22])[0]
    h = struct.unpack("<i", d[22:26])[0]
    bpp = struct.unpack("<H", d[28:30])[0]
    if bpp not in (24, 32):
        sys.exit(f"palette.py: --snap 需要 24/32 位 BMP（当前 {bpp}bpp）")
    flip = h > 0
    h = abs(h)
    stride = ((w * bpp // 8) + 3) & ~3
    step = bpp // 8
    rows = []
    for y in range(h):
        src = h - 1 - y if flip else y
        base = off + src * stride
        row = []
        for x in range(w):
            o = base + x * step
            row.append((d[o + 2], d[o + 1], d[o]))   # BGR -> RGB
        rows.append(row)
    return w, h, rows


def nearest_index(r, g, b, cache={}):
    key = (r, g, b)
    if key in cache:
        return cache[key]
    best, bestd = 0, 1 << 30
    for i in range(0xF0):
        cr, cg, cb = un565(PAL[i])
        dd = (cr - r) ** 2 * 2 + (cg - g) ** 2 * 4 + (cb - b) ** 2 * 3
        if dd < bestd:
            best, bestd = i, dd
    cache[key] = best
    return best


def cmd_snap(src, dst):
    """RGB BMP -> 吸附到主色板的 8bpp 索引 BMP（同尺寸）"""
    w, h, rows = read_bmp_rgb(src)
    idx_rows = []
    hist = {}
    exact = 0
    for row in rows:
        irow = []
        for (r, g, b) in row:
            i = nearest_index(r, g, b)
            irow.append(i)
            hist[i] = hist.get(i, 0) + 1
            if un565(PAL[i]) == (r, g, b):
                exact += 1
        idx_rows.append(irow)
    write_bmp_indexed(dst, w, h, idx_rows)
    total = w * h
    used = sorted(hist.items(), key=lambda kv: -kv[1])
    print(f"palette.py: {src} {w}x{h} -> {dst}")
    print(f"  完全命中 {exact}/{total} 像素（{exact*100//max(total,1)}%），用了 {len(used)} 个色号")
    for i, n in used[:12]:
        print(f"   0x{i:02X} {NAMES[i]:<18} {fmt_rgb888(PAL[i])}  {n} px")


def cmd_png(dst):
    """导出色卡 PNG：16x16 色块，每块 24x24 像素"""
    cell = 24
    n = 16
    W = H = n * cell
    rows = []
    for y in range(H):
        row = []
        for x in range(W):
            idx = (y // cell) * n + (x // cell)
            row.append(un565(PAL[idx]))
        rows.append(row)
    write_png_rgb(dst, W, H, rows)
    print(f"palette.py: 写出色卡 {dst}（{W}x{H}）")


def cmd_js():
    """输出 JS 数组（yxpad.html 用）"""
    vals = []
    for i in range(256):
        r, g, b = un565(PAL[i])
        vals.append("0x%02X%02X%02X" % (r, g, b))
    print("const YX_PAL = [" + ",".join(vals) + "];")


if __name__ == "__main__":
    main()
