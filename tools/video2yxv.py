# -*- coding: utf-8 -*-
# video2yxv.py — 任意视频 → YXV（映序视频卡带格式：MJPEG + PCM 48kHz）
#
# 用法:
#   python tools/video2yxv.py --in 片源.mp4 --out out/clip.yxv \
#        [--width 640 --height 480 --fps 24 --quality 4 --gain 1.0]
#   python tools/video2yxv.py --write out/clip.yxv --drive E [--slot 0]
#
# YXV v1 布局（全扇区对齐，帧区/音频区分离，硬件双轨消费）:
#   [0 :32]   头: 'YXV1' ver ch=2 W(H16) H(H16) fps(H16) frames(u32)
#             audio_rate(u32) audio_bytes(u32) table_off(u32)=32 frames_off(u32)
#   [32:  ]   帧表: 每帧 {u32 offset, u32 len}（offset 从文件头起，扇区对齐）
#   [    ]    帧区: 逐帧 JPEG（FFD8..FFD9），扇区对齐填充
#   [    ]    音频区: s16le 立体声 PCM
import argparse, os, re, struct, subprocess, sys, tempfile

HDR = 32
ENTRY = 8

def find_ffmpeg():
    p = r'C:\Users\HXF\Desktop\YX\tools\ffmpeg\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe'
    if os.path.exists(p):
        return p
    for c in __import__('glob').glob(r'C:\Users\HXF\Desktop\YX\tools\ffmpeg*\**\bin\ffmpeg.exe', recursive=True):
        return c
    return 'ffmpeg'


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    if r.returncode != 0:
        print('ffmpeg 失败:', (r.stderr or '')[-600:])
        sys.exit(1)
    return r


def transcode(src, tmp, width, height, fps, quality, gain):
    ff = find_ffmpeg()
    vid = os.path.join(tmp, 'v.mjpeg')
    aud = os.path.join(tmp, 'a.pcm')
    run([ff, '-y', '-i', src, '-an', '-vf', 'scale=%d:%d,fps=%d' % (width, height, fps),
         '-c:v', 'mjpeg', '-q:v', str(quality), '-f', 'mjpeg', vid])
    cmd2 = [ff, '-y', '-i', src, '-vn', '-ar', '48000', '-ac', '2',
            '-sample_fmt', 's16', '-f', 's16le', aud]
    if gain != 1.0:
        cmd2[7:7] = ['-af', 'volume=%g' % gain]
    run(cmd2)
    return vid, aud


def split_frames(blob):
    """扫描连续 MJPEG 流 → 单帧列表（FFD8FF 起，FFD9 止）"""
    frames, i, n = [], 0, len(blob)
    while True:
        s = blob.find(b'\xff\xd8\xff', i)
        if s < 0:
            break
        e = blob.find(b'\xff\xd9', s + 3)
        if e < 0:
            e = n - 2
        frames.append(blob[s:e + 2])
        i = e + 2
    return frames


def build_yxv(frames, pcm, width, height, fps):
    # 帧区从表之后开始，整体扇区对齐；每帧扇区对齐
    table_bytes = len(frames) * ENTRY
    off = (HDR + table_bytes + 511) // 512 * 512   # 帧区起点（扇区对齐）
    frames_off = off                                # 头字段 = 对齐后的帧区起点
    table, body = b'', b''
    for f in frames:
        table += struct.pack('<II', off, len(f))
        body += f
        pad = (-len(f)) % 512
        body += b'\x00' * pad
        off += len(f) + pad
    audio_off = off
    audio_bytes = len(pcm)
    hdr = bytearray(HDR)
    hdr[0:4] = b'YXV1'
    hdr[4] = 1
    hdr[5] = 2
    struct.pack_into('<H', hdr, 6, width)
    struct.pack_into('<H', hdr, 8, height)
    struct.pack_into('<H', hdr, 10, fps)
    struct.pack_into('<I', hdr, 12, len(frames))
    struct.pack_into('<I', hdr, 16, 48000)
    struct.pack_into('<I', hdr, 20, audio_bytes)
    struct.pack_into('<I', hdr, 24, HDR)
    struct.pack_into('<I', hdr, 28, frames_off)
    gap = frames_off - (HDR + table_bytes)          # 表尾→帧区的对齐间隙，必须真的填进文件
    yxv = bytes(hdr) + table + b'\x00' * gap + body + pcm
    assert len(table) == table_bytes
    assert frames_off + len(table) <= (HDR + table_bytes + 511) // 512 * 512 + len(body)
    return yxv, audio_off


def verify(yxv):
    """写卡前自检：头字段、表单调性、每帧 FFD8/FFD9、音频区长度"""
    assert yxv[0:4] == b'YXV1'
    width, height, fps = struct.unpack_from('<HHH', yxv, 6)
    frames, arate, abytes, toff, foff = struct.unpack_from('<IIIII', yxv, 12)
    prev = 0
    mx = avg = 0
    for i in range(frames):
        o, l = struct.unpack_from('<II', yxv, toff + i * ENTRY)
        assert o % 512 == 0, '帧 %d 未扇区对齐' % i
        assert o >= foff and o > prev, '帧 %d 表序错误' % i
        assert yxv[o:o+2] == b'\xff\xd8', '帧 %d 缺 SOI' % i
        assert yxv[o+l-2:o+l] == b'\xff\xd9', '帧 %d 缺 EOI' % i
        mx = max(mx, l); avg += l
        prev = o
    if frames:
        avg //= frames
    assert len(yxv) - (prev + mx) >= 0
    if frames:
        lo, ll = struct.unpack_from('<II', yxv, toff + (frames - 1) * ENTRY)
        a = len(yxv) - (lo + (ll + 511) // 512 * 512)   # 音频区起点 = 末帧扇区对齐后
        assert abytes == a, '音频区长度与表不一致 (%d != %d)' % (abytes, a)
    return width, height, fps, frames, arate, abytes, mx, avg


def write_card(path, drive, slot=0):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from write_cart import Vol
    VIDEO_BASE = 3_000_000          # 板子视角 LBA（视频槽基址）
    PART_OFF = 2_048
    SPAN = 512 * 1024               # 视频槽 256MB（扇区数按此上限校验）
    data = open(path, 'rb').read()
    nsec = (len(data) + 511) // 512
    assert nsec <= SPAN, '视频 %d MB 超过视频槽 256MB' % (len(data) >> 20)
    base = VIDEO_BASE + slot * SPAN - PART_OFF
    padded = data + b'\x00' * (nsec * 512 - len(data))
    v = Vol(drive)
    try:
        v.lock()
        v.seek(base)
        v.write(padded)
        v.seek(base)
        assert v.read(nsec * 512) == padded, '回读校验失败'
        print('已写入视频槽 %d（卷内扇区 %d），%d B，回读校验一致' % (slot, base, len(data)))
    finally:
        v.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--in', dest='src')
    ap.add_argument('--out')
    ap.add_argument('--write')
    ap.add_argument('--drive', default='E')
    ap.add_argument('--slot', type=int, default=0)
    ap.add_argument('--width', type=int, default=640)
    ap.add_argument('--height', type=int, default=480)
    ap.add_argument('--fps', type=int, default=24)
    ap.add_argument('--quality', type=int, default=4, help='ffmpeg -q:v，越小质量越高')
    ap.add_argument('--gain', type=float, default=1.0)
    a = ap.parse_args()

    if a.write:
        write_card(a.write, a.drive, a.slot)
        return
    if not a.src or not a.out:
        print('需要 --in/--out 或 --write'); sys.exit(1)

    with tempfile.TemporaryDirectory() as tmp:
        vid, aud = transcode(a.src, tmp, a.width, a.height, a.fps, a.quality, a.gain)
        frames = split_frames(open(vid, 'rb').read())
        pcm = open(aud, 'rb').read()
    if not frames:
        print('没有解出任何帧'); sys.exit(1)

    yxv, audio_off = build_yxv(frames, pcm, a.width, a.height, a.fps)
    W, H, F, N, AR, AB, MX, AVG = verify(yxv)
    with open(a.out, 'wb') as f:
        f.write(yxv)

    dur_v = N / F
    print('=' * 56)
    print('YXV: %s' % a.out)
    print('  %dx%d @%dfps, %d 帧, %.1f 秒' % (W, H, F, N, dur_v))
    print('  帧: 平均 %.1f KB, 最大 %.1f KB' % (AVG / 1024, MX / 1024))
    print('  音频: %d Hz, %.1f 秒, %d KB (offset %d)' % (AR, AB / 192000.0, AB // 1024, audio_off))
    print('  视频码率 %.2f MB/s, 总大小 %.1f MB' % (AVG * F / 1e6, len(yxv) / 1e6))
    print('  SD 带宽需求(含音频): %.2f MB/s' % ((AVG * F + 192000) / 1e6))
    print('  硬件要点: 帧表 %d B (%d BRAM), 帧区扇区对齐 ✓' % (N * ENTRY, (N * ENTRY + 10239) // 10240))


if __name__ == '__main__':
    main()
