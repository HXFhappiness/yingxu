# -*- coding: utf-8 -*-
"""grab.py — 用 ffmpeg 从采集卡（UVC）抓帧，供 screen_probe.py 分析

用法：
  python tools/grab.py --list                列出可用视频设备
  python tools/grab.py out\\snap.png          抓 1 帧
  python tools/grab.py out\\a.png --burst 5   连抓 5 帧（a_0.png..a_4.png）
  python tools/grab.py out\\s.png --device "USB Video" --size 1920x1080 --fps 60

说明：OBS 不是必需的；采集卡在 Windows 上就是 DirectShow 摄像头设备，
     ffmpeg -f dshow -i video="设备名" 即可抓帧。
"""
import argparse, subprocess, sys, os, glob

FF = r'C:\Users\HXF\Desktop\YX\tools\ffmpeg\bin\ffmpeg.exe'


def find_ffmpeg():
    if os.path.exists(FF):
        return FF
    for p in glob.glob(r'C:\Users\HXF\Desktop\YX\tools\ffmpeg*\**\bin\ffmpeg.exe', recursive=True):
        return p
    return 'ffmpeg'


def list_devices():
    ff = find_ffmpeg()
    print('ffmpeg:', ff)
    r = subprocess.run([ff, '-hide_banner', '-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'],
                       capture_output=True, text=True, encoding='utf-8', errors='replace')
    for ln in (r.stderr or '').splitlines():
        if 'video' in ln.lower() or 'DirectShow' in ln:
            print(' ', ln.strip())


def grab(out, device, size, fps, frames):
    ff = find_ffmpeg()
    src = f'video={device}'
    cmd = [ff, '-hide_banner', '-loglevel', 'error', '-y',
           '-f', 'dshow', '-rtbufsize', '256M',
           '-framerate', str(fps), '-video_size', size,
           '-i', src, '-frames:v', str(frames), out]
    print(' '.join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    if r.returncode != 0:
        print('抓帧失败:', (r.stderr or '')[-800:])
        print('提示：先 `python tools/grab.py --list` 看设备名，或省略 --size/--fps 让驱动自协商')
        return False
    print('已保存', out, os.path.getsize(out), 'bytes')
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out', nargs='?', default=r'out\snap.png')
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--device', default='USB Video')
    ap.add_argument('--size', default='1920x1080')
    ap.add_argument('--fps', default='60')
    ap.add_argument('--burst', type=int, default=1)
    a = ap.parse_args()

    if a.list:
        list_devices()
        return

    if a.burst <= 1:
        grab(a.out, a.device, a.size, a.fps, 1)
    else:
        base, ext = os.path.splitext(a.out)
        for i in range(a.burst):
            grab(f'{base}_{i}{ext}', a.device, a.size, a.fps, 1)


if __name__ == '__main__':
    main()
