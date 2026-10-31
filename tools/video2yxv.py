# -*- coding: utf-8 -*-
"""YXV1 converter: explicit 4:2:0 baseline profile and per-frame admission gates.

Python 3.10+, standard library; ffmpeg is the only external conversion tool.
    python tools/video2yxv.py --in clip.mp4 --out out/clip.yxv --report out/clip.json
    python tools/video2yxv.py --verify out/clip.yxv
    python tools/video2yxv.py --write out/clip.yxv --drive E --slot 0
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from mjpeg_ref import ProfileError, inspect_jpeg, split_mjpeg
from mjpeg_ref.container import build_container, inspect_container
from mjpeg_ref.cycles import schedule

HDR, ENTRY = 32, 8

def find_ffmpeg():
    candidate = shutil.which('ffmpeg')
    if candidate:
        return candidate
    # Repository-local portable tools; do not depend on a historical second checkout.
    for candidate in sorted((Path(__file__).parent/'ffmpeg').glob('**/ffmpeg.exe')):
        return str(candidate)
    raise ProfileError('FFMPEG_MISSING','put ffmpeg on PATH or in tools/ffmpeg/')

def run(cmd):
    result = subprocess.run(cmd,capture_output=True,text=True,encoding='utf-8',errors='replace')
    if result.returncode:
        raise ProfileError('FFMPEG',result.stderr[-1200:])
    return result

def transcode(src,tmp,width,height,fps,quality,gain):
    ff = find_ffmpeg()
    video, audio = str(Path(tmp)/'v.mjpeg'), str(Path(tmp)/'a.pcm')
    # BT.601 full-range YCbCr, fixed sampling; encoder emits its DQT/DHT each frame.
    vf = f'scale={width}:{height}:out_range=full:out_color_matrix=bt601,fps={fps},setsar=1,format=yuvj420p'
    run([ff,'-hide_banner','-loglevel','error','-y','-i',src,'-map','0:v:0','-an',
         '-vf',vf,'-pix_fmt','yuvj420p','-color_range','pc','-colorspace','smpte170m',
         '-c:v','mjpeg','-huffman','default','-q:v',str(quality),'-threads','1','-f','mjpeg',video])
    cmd=[ff,'-hide_banner','-loglevel','error','-y','-i',src,'-map','0:a:0','-vn',
         '-ar','48000','-ac','2']
    if gain != 1:
        cmd += ['-af',f'volume={gain:g}']
    run(cmd+['-sample_fmt','s16','-f','s16le',audio])
    return video,audio

def split_frames(blob):
    return split_mjpeg(blob)

def build_yxv(frames,pcm,width,height,fps):
    return build_container(frames,pcm,width,height,fps)

def verify(yxv):
    """Preserve the original tuple API while performing full profile/entropy checks."""
    r=inspect_container(yxv)
    lengths=[frame['jpeg_bytes'] for frame in r['frame_reports']]
    return (r['width'],r['height'],r['fps'],r['frames'],r['audio_rate'],
            r['audio_bytes'],max(lengths),sum(lengths)//len(lengths))

def convert(src,out_path, *, quality=4,gain=1.0,width=640,height=480,fps=24):
    if (width,height,fps) != (640,480,24):
        raise ProfileError('YXV_PROFILE','D1 emits 640x480@24 only; fallback needs a separately approved profile')
    if not 2 <= quality <= 31 or not 0 <= gain <= 4:
        raise ProfileError('ARGUMENT','quality=2..31, gain=0..4 required')
    attempts=[]
    candidates=list(dict.fromkeys([quality]+list(range(quality+2,32,2))+[31]))
    with tempfile.TemporaryDirectory() as tmp:
        for q in candidates:
            video,audio=transcode(src,tmp,width,height,fps,q,gain)
            frames=split_mjpeg(Path(video).read_bytes())
            if not 1 <= len(frames) <= 504:
                raise ProfileError('DEMO_DURATION',f'{len(frames)} frames; demo must be <=21 seconds/504 frames')
            pcm=Path(audio).read_bytes()
            target=len(frames)*2000*4
            if abs(len(pcm)-target) >= 19200:
                raise ProfileError('AV_DURATION','source audio/video differ by >=0.1s')
            # Small codec/endpoint differences are normalized to exactly N*2000 stereo frames.
            pcm=pcm[:target]+bytes(max(0,target-len(pcm)))
            try:
                for index,frame in enumerate(frames):
                    jpeg=inspect_jpeg(frame)
                    timing=schedule(jpeg)
                    if not timing['accepted']:
                        raise ProfileError('CORE_CYCLES',f'frame {index}: {timing["frame_cycles"]}')
                data,_=build_container(frames,pcm)
                report=inspect_container(data)
            except ProfileError as e:
                attempts.append({'quality':q,'accepted':False,'error_code':e.code,'detail':str(e)})
                if e.code not in ('FRAME_SIZE','CORE_CYCLES') or q == 31:
                    raise
                print(f'q={q} rejected: {e}; trying higher compression',file=sys.stderr)
                continue
            attempts.append({'quality':q,'accepted':True})
            report.update({'quality':q,'gain':gain,'attempts':attempts,
                           'measurement_kind':'Python finite-bank model; not measured RTL/hardware',
                           'ffmpeg_version':run([find_ffmpeg(),'-version']).stdout.splitlines()[0]})
            # No partial output or unverified file is written on rejection.
            Path(out_path).write_bytes(data)
            return report
    raise ProfileError('CONVERSION','no admissible encoding')

def write_card(path,drive,slot=0):
    if slot not in range(4):
        raise ProfileError('SLOT','slot must be 0..3')
    data=Path(path).read_bytes()
    inspect_container(data)  # Validate before importing/opening the raw-volume writer.
    from write_cart import Vol
    nsec=(len(data)+511)//512
    base=3_000_000+slot*524_288-2048
    padded=data+bytes(nsec*512-len(data))
    volume=Vol(drive)
    try:
        volume.lock()
        volume.seek(base); volume.write(padded)
        volume.seek(base)
        if volume.read(nsec*512) != padded:
            raise ProfileError('CARD_READBACK','readback mismatch')
        print(f'已写入视频槽 {slot}，{len(data)} B，回读校验一致')
    finally:
        volume.close()

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    mode=ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--in',dest='src')
    mode.add_argument('--verify')
    mode.add_argument('--write')
    ap.add_argument('--out'); ap.add_argument('--report')
    ap.add_argument('--drive',default='E'); ap.add_argument('--slot',type=int,choices=range(4),default=0)
    ap.add_argument('--width',type=int,default=640); ap.add_argument('--height',type=int,default=480)
    ap.add_argument('--fps',type=int,default=24); ap.add_argument('--quality',type=int,default=4)
    ap.add_argument('--gain',type=float,default=1.0)
    a=ap.parse_args()
    try:
        if a.write:
            write_card(a.write,a.drive,a.slot)
            return
        if a.verify:
            report=inspect_container(Path(a.verify).read_bytes())
        else:
            if not a.out:
                ap.error('--in requires --out')
            report=convert(a.src,a.out,quality=a.quality,gain=a.gain,width=a.width,height=a.height,fps=a.fps)
        if a.report:
            Path(a.report).write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
        print(f'YXV: {report["frames"]} frames, {report["duration_seconds"]:.3f}s, '
              f'max JPEG={report["max_jpeg_bytes"]} B; worst frame #{report["worst_frame_index"]} '
              f'={report["worst_frame_cycles"]} model cycles ({report["worst_frame_ms"]:.5f} ms)')
    except (ProfileError,OSError) as e:
        ap.exit(1,f'{e}\n')

if __name__=='__main__':
    main()
