# -*- coding: utf-8 -*-
"""yxv_extract.py — YXV 容器解析/帧提取/参考 RGB 生成

用法:
  python yxv_extract.py in.yxv --dump-jpeg outdir            # 导出全部 JPEG 帧
  python yxv_extract.py in.yxv --ref-rgb outdir --frames 0,1 # 参考解码 RGB (ffmpeg)
  python yxv_extract.py in.yxv --info                        # 只打印结构

YXV 布局 (v1): 32B 头 + 帧表(8B/帧: <II offset,len) + 帧区(每帧512B对齐) + PCM音轨
头: YXV1 | ver=1 prof=2 | W H fps | nframes | 48000 | audio_bytes | table_off=32 | frames_off
"""
import io, os, re, struct, subprocess, sys, glob


def find_ffmpeg():
    p = r'C:\Users\HXF\Desktop\YX\tools\ffmpeg\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe'
    if os.path.exists(p):
        return p
    for c in glob.glob(r'C:\Users\HXF\Desktop\YX\tools\ffmpeg*\**\bin\ffmpeg.exe', recursive=True):
        return c
    return 'ffmpeg'


def parse(path):
    b = io.open(path, 'rb').read(32)
    assert b[0:4] == b'YXV1', 'magic 不对: %r' % b[0:4]
    ver, prof = b[4], b[5]
    w, h, fps = struct.unpack_from('<HHH', b, 6)
    nf, ar, ab, toff, foff = struct.unpack_from('<III I I'.replace(' ', ''), b, 12)
    return dict(ver=ver, prof=prof, w=w, h=h, fps=fps, nf=nf, ar=ar, ab=ab,
                table_off=toff, frames_off=foff)


def frames(path, inf):
    data = io.open(path, 'rb')
    data.seek(inf['table_off'])
    tab = data.read(inf['nf'] * 8)
    out = []
    for i in range(inf['nf']):
        off, ln = struct.unpack_from('<II', tab, i * 8)
        data.seek(off)
        jpg = data.read(ln)
        assert jpg[0:3] == b'\xff\xd8\xff', '帧 %d 不是 JPEG: %r' % (i, jpg[0:4])
        assert jpg[-2:] == b'\xff\xd9', '帧 %d 结尾不是 EOI' % i
        out.append((off, ln, jpg))
    return out


def main():
    path = sys.argv[1]
    inf = parse(path)
    print('%s: v%d.p%d %dx%d@%d %d帧 audio %dHz %dB table@%d frames@%d'
          % (os.path.basename(path), inf['ver'], inf['prof'], inf['w'], inf['h'],
             inf['fps'], inf['nf'], inf['ar'], inf['ab'], inf['table_off'], inf['frames_off']))
    fs = frames(path, inf)
    print('帧表校验: %d/%d OK, 尺寸 %d~%d B, 平均 %.1f KB'
          % (len(fs), inf['nf'], min(l for _, l, _ in fs), max(l for _, l, _ in fs),
             sum(l for _, l, _ in fs) / 1024.0 / len(fs)))

    args = sys.argv[2:]
    if '--info' in args:
        return
    if '--dump-jpeg' in args:
        d = args[args.index('--dump-jpeg') + 1]
        os.makedirs(d, exist_ok=True)
        for i, (off, ln, jpg) in enumerate(fs):
            io.open(os.path.join(d, 'frame_%03d.jpg' % i), 'wb').write(jpg)
        print('JPEG 导出 -> %s (%d 帧)' % (d, len(fs)))
    if '--ref-rgb' in args:
        d = args[args.index('--ref-rgb') + 1]
        sel = [int(x) for x in args[args.index('--frames') + 1].split(',')] if '--frames' in args else [0]
        os.makedirs(d, exist_ok=True)
        tmp = os.path.join(d, '_tmp.jpg')
        ff = find_ffmpeg()
        for i in sel:
            io.open(tmp, 'wb').write(fs[i][2])
            o = os.path.join(d, 'ref_f%03d.rgb' % i)
            r = subprocess.run([ff, '-y', '-i', tmp, '-f', 'rawvideo', '-pix_fmt', 'rgb24', o],
                               capture_output=True, text=True)
            assert os.path.exists(o) and os.path.getsize(o) == inf['w'] * inf['h'] * 3, \
                '参考解码失败: %s' % (r.stderr or '')[-300:]
            print('参考帧 %d -> %s (%d B)' % (i, o, os.path.getsize(o)))
        os.remove(tmp)
        # 音轨校验
        f = io.open(path, 'rb')
        f.seek(inf['frames_off'])
        pass


if __name__ == '__main__':
    main()
