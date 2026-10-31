"""Bit-exact integer IDCT and an independent direct floating reference."""
import math
from .jpeg import require

K = tuple(tuple(round(65536 * (1/math.sqrt(2) if k == 0 else 1) / 2 *
                     math.cos((2*n+1)*k*math.pi/16)) for k in range(8)) for n in range(8))

def idct_int(coeff, *, intermediate=False):
    require(len(coeff) == 64 and all(-2048 <= n <= 2047 for n in coeff),
            'IDCT_RANGE','64 supported dequantized values required')
    first = [0]*64
    for v in range(8):
        for x in range(8):
            first[v*8+x] = (sum(coeff[v*8+u]*K[x][u] for u in range(8))+32768)//65536
    last = [0]*64
    for y in range(8):
        for x in range(8):
            value = (sum(first[v*8+x]*K[y][v] for v in range(8))+32768)//65536+128
            last[y*8+x] = min(255,max(0,value))
    return (first,last) if intermediate else last

def idct_float(coeff):
    out = []
    for y in range(8):
        for x in range(8):
            value = 128 + 0.25*math.fsum(
                coeff[v*8+u] * (1/math.sqrt(2) if u == 0 else 1) *
                (1/math.sqrt(2) if v == 0 else 1) *
                math.cos((2*x+1)*u*math.pi/16) * math.cos((2*y+1)*v*math.pi/16)
                for v in range(8) for u in range(8))
            out.append(min(255,max(0,math.floor(value+0.5))))
    return out

def rgb565(y,cb,cr):
    cb, cr = cb-128, cr-128
    clamp = lambda n: min(255,max(0,n))
    r = clamp(y+(22970*cr+8192)//16384)
    g = clamp(y+(-5638*cb-11700*cr+8192)//16384)
    b = clamp(y+(29032*cb+8192)//16384)
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)

def decode_rgb565(jpeg):
    require(len(jpeg.blocks) == 7200 and all(b.coefficients is not None for b in jpeg.blocks),
            'TRACE_REQUIRED','parse with collect_coefficients=True')
    result = [0]*(640*480)
    for mcu in range(1200):
        blocks = [idct_int(b.coefficients) for b in jpeg.blocks[mcu*6:mcu*6+6]]
        mx, my = (mcu % 40)*16, (mcu // 40)*16
        for y in range(16):
            for x in range(16):
                luma = blocks[(y//8)*2+x//8][(y%8)*8+x%8]
                ci = (y//2)*8+x//2
                result[(my+y)*640+mx+x] = rgb565(luma,blocks[4][ci],blocks[5][ci])
    return result
