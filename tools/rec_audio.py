# -*- coding: utf-8 -*-
# rec_audio.py — 稳定录音（Python subprocess 调用 ffmpeg，避免中文设备名引号问题）
# 用法: python rec_audio.py out\rec.wav 12
import subprocess, sys, os

FF = r'C:\Users\HXF\Desktop\YX\tools\ffmpeg\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe'
DEV = '数字音频接口 (USB3 Digital Audio)'

out = sys.argv[1] if len(sys.argv) > 1 else r'out\rec.wav'
dur = sys.argv[2] if len(sys.argv) > 2 else '12'

if os.path.exists(out):
    os.remove(out)

cmd = [FF, '-hide_banner', '-loglevel', 'error', '-y',
       '-f', 'dshow', '-rtbufsize', '128M',
       '-i', 'audio=' + DEV, '-t', dur, out]
print('recording', dur, 's ->', out)
r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
print('rc =', r.returncode)
if r.stderr.strip():
    print('stderr:', r.stderr.strip()[:400])
if os.path.exists(out):
    print('file bytes =', os.path.getsize(out))
else:
    print('NO FILE PRODUCED')
