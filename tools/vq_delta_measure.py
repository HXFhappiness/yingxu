# -*- coding: utf-8 -*-
"""vq_delta_measure.py — 差分 VQ 真实码率测量

对源视频逐帧计算 VQ 索引，比较相邻帧变化块数，输出：
  每帧 delta 码率（bitmap + changed indices）
  全帧码率（对照）
  场景切换检测（>80% 变化）
  分布直方图

用法:
  python vq_delta_measure.py --src xinji_src.mp4 --w 1280 --h 720 --fps 24 --cbsize 1024
  python vq_delta_measure.py --src xinji_src.mp4 --w 1280 --h 720 --fps 30 --cbsize 256
"""
import argparse, os, struct, subprocess, sys, time

import numpy as np

FFM = r'C:\ffmpeg\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe'


def to565(rgb):
    r = (rgb[..., 0].astype(np.uint16) >> 3) << 11
    g = (rgb[..., 1].astype(np.uint16) >> 2) << 5
    b = (rgb[..., 2].astype(np.uint16) >> 3)
    return r | g | b


def from565(v):
    v = v.astype(np.uint16)
    r = (((v >> 11) & 0x1F).astype(np.uint16) * 255 // 31).astype(np.uint8)
    g = (((v >> 5) & 0x3F).astype(np.uint16) * 255 // 63).astype(np.uint8)
    b = ((v & 0x1F).astype(np.uint16) * 255 // 31).astype(np.uint8)
    return np.stack([r, g, b], axis=-1)


def blocks_of(frame):
    h, w, _ = frame.shape
    b = frame.reshape(h // 4, 4, w // 4, 4, 3)
    b = b.transpose(0, 2, 1, 3, 4).reshape(-1, 16, 3)
    return b.reshape(-1, 48).astype(np.float32)


def frame_iter(ffargs, w, h):
    p = subprocess.Popen(ffargs, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    nbytes = w * h * 3
    while True:
        buf = p.stdout.read(nbytes)
        if len(buf) < nbytes:
            break
        yield np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 3)
    p.stdout.close()
    p.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', required=True)
    ap.add_argument('--w', type=int, default=1280)
    ap.add_argument('--h', type=int, default=720)
    ap.add_argument('--fps', type=int, default=24)
    ap.add_argument('--cbsize', type=int, default=1024)
    ap.add_argument('--ss', type=float, default=0.0)
    ap.add_argument('--dur', type=float, default=0.0)
    ap.add_argument('--maxframes', type=int, default=600)
    a = ap.parse_args()
    if a.w % 4 or a.h % 4:
        raise SystemExit('宽高必须是 4 的倍数')

    t0 = time.time()
    base = []
    if a.ss:
        base += ['-ss', str(a.ss)]
    base += ['-i', a.src]
    if a.dur:
        base += ['-t', str(a.dur)]

    total_blocks = (a.w // 4) * (a.h // 4)
    bitmap_bytes = (total_blocks + 7) // 8
    idx_bytes = 2 if a.cbsize > 256 else 1

    print('=== 差分 VQ 码率测量 ===')
    print('分辨率: %dx%d  fps=%d  codebook=%d' % (a.w, a.h, a.fps, a.cbsize))
    print('块数: %d  bitmap: %d B  index: %d B/块' % (total_blocks, bitmap_bytes, idx_bytes))
    print('全帧码率: %.2f MB/s (%d B/帧)' % (
        total_blocks * idx_bytes * a.fps / 1e6, total_blocks * idx_bytes))
    print()

    # ---- 1) 训练 ----
    train_args = [FFM] + base + ['-vf', 'scale=%d:%d:flags=lanczos,fps=%d' % (a.w, a.h, max(1, a.fps // 6)),
                  '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    sample = []
    ntrain = 0
    for fr in frame_iter(train_args, a.w, a.h):
        blk = blocks_of(fr)
        step = max(1, len(blk) // 2000)
        sample.append(blk[::step])
        ntrain += 1
        if ntrain >= 200:
            break
    sample = np.concatenate(sample, 0)

    from sklearn.cluster import MiniBatchKMeans
    km = MiniBatchKMeans(n_clusters=min(a.cbsize, len(sample)), batch_size=8192, n_init=3,
                         max_iter=300, random_state=0, verbose=0)
    km.fit(sample)
    cent = km.cluster_centers_.reshape(-1, 48).astype(np.float32)
    cn = (cent ** 2).sum(1)[None, :]
    print('codebook %d 训练完成 (%.1fs)' % (a.cbsize, time.time() - t0))
    print()

    # ---- 2) 流式编码 + 差分测量 ----
    enc_args = [FFM] + base + ['-vf', 'scale=%d:%d:flags=lanczos' % (a.w, a.h),
                '-r', str(a.fps), '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    chunk = 8192

    prev_idx = None
    frame_stats = []       # (frame_no, changed, changed_frac, delta_bytes, full_bytes, is_key)
    key_interval = 30      # 每 30 帧强制一个 KEY 帧

    n = 0
    for fr in frame_iter(enc_args, a.w, a.h):
        blk = blocks_of(fr)
        idx = np.empty(len(blk), dtype=np.int32)
        for s in range(0, len(blk), chunk):
            e = min(s + chunk, len(blk))
            b = blk[s:e]
            d = (b ** 2).sum(1)[:, None] + cn - 2.0 * (b @ cent.T)
            idx[s:e] = d.argmin(1)

        if prev_idx is None:
            # 第一帧 = KEY 帧
            changed = total_blocks
            is_key = True
        else:
            diff_mask = (idx != prev_idx)
            changed = int(diff_mask.sum())
            frac = changed / total_blocks
            is_key = frac > 0.80 or (n % key_interval == 0)

        if is_key:
            delta_bytes = total_blocks * idx_bytes
        else:
            delta_bytes = bitmap_bytes + changed * idx_bytes

        frame_stats.append((n, changed, changed / total_blocks, delta_bytes,
                            total_blocks * idx_bytes, is_key))
        prev_idx = idx.copy()
        n += 1
        if n >= a.maxframes:
            break
        if n % 120 == 0:
            print('  %d frames (%.0fs)' % (n, time.time() - t0), flush=True)

    # ---- 3) 统计 ----
    print()
    print('=== 结果 (%d 帧, %.1f 秒) ===' % (n, n / a.fps))

    delta_bps = [s[3] * a.fps for s in frame_stats if not s[5]]
    full_bps = [s[4] * a.fps for s in frame_stats]

    avg_delta = np.mean(delta_bps) if delta_bps else 0
    worst_delta = np.max(delta_bps) if delta_bps else 0
    p95_delta = np.percentile(delta_bps, 95) if delta_bps else 0

    key_frames = sum(1 for s in frame_stats if s[5])
    delta_frames = n - key_frames
    total_delta_bytes = sum(s[3] for s in frame_stats)
    total_full_bytes = sum(s[4] for s in frame_stats)

    avg_full = total_full_bytes / n * a.fps / 1e6
    avg_delta_all = total_delta_bytes / n * a.fps / 1e6

    print('全帧码率:   %.2f MB/s (对照)' % avg_full)
    print('差分码率:   平均 %.2f MB/s  P95 %.2f  最差 %.2f MB/s' % (avg_delta_all, p95_delta / 1e6, worst_delta / 1e6))
    print('KEY 帧: %d  DELTA 帧: %d  (KEY 间隔 %d)' % (key_frames, delta_frames, key_interval))

    # 变化率分布
    fracs = [s[2] for s in frame_stats if not s[5]]
    if fracs:
        print('变化率分布: P25 %.1f%%  P50 %.1f%%  P75 %.1f%%  P95 %.1f%%' % (
            np.percentile(fracs, 25) * 100, np.percentile(fracs, 50) * 100,
            np.percentile(fracs, 75) * 100, np.percentile(fracs, 95) * 100))

    # 场景切换（>80% 变化的帧）
    cuts = [(s[0], s[2]) for s in frame_stats if s[2] > 0.80]
    print('场景切换 (>80%%): %d 帧' % len(cuts))
    if cuts:
        print('  最差帧: #%d (%.1f%%)' % (cuts[0][0] if cuts else 0,
              max((f for _, f in cuts), default=0) * 100))

    # 每种 SD 速率的可行性
    print()
    print('=== SD 速率匹配 ===')
    for label, rate in [('12.5 MHz SPI (1.3 MB/s)', 1.3e6),
                        ('25 MHz SPI (2.8 MB/s)', 2.8e6)]:
        fit = '✓' if avg_delta_all <= rate / 1e6 else '✗'
        fit_worst = '✓' if worst_delta / 1e6 <= rate / 1e6 else '✗'
        print('%s: 差分平均 %s  最差 %s  (平均 %.2f  最差 %.2f MB/s)' % (
            label, fit, fit_worst, avg_delta_all, worst_delta / 1e6))

    # 逐帧明细（前 20 帧 + 最差 5 帧）
    print()
    print('=== 逐帧明细（前 20 帧）===')
    for s in frame_stats[:20]:
        tag = 'KEY ' if s[5] else 'DELTA'
        print('  #%4d  %s  changed=%5d (%.1f%%)  delta=%6d B  %.2f MB/s' % (
            s[0], tag, s[1], s[2] * 100, s[3], s[3] * a.fps / 1e6))

    # 最差帧
    if delta_bps:
        worst_idx = np.argmax(delta_bps)
        s = frame_stats[worst_idx] if worst_idx < len(frame_stats) else None
        if s:
            print('  最差帧 #%d: %.2f MB/s (%.1f%% changed)' % (s[0], s[3] * a.fps / 1e6, s[2] * 100))

    print()
    print('耗时 %.1fs' % (time.time() - t0))


if __name__ == '__main__':
    main()
