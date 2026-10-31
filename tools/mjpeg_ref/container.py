"""Strict YXV1 layout/profile checks; no writes to physical media."""
import hashlib
import struct
from .jpeg import require, inspect_jpeg
from .cycles import schedule

SLOT_BYTES = 256*1024*1024

def align512(n):
    return (n+511)//512*512

def build_container(frames, pcm, width=640, height=480, fps=24):
    count = len(frames)
    require((width,height,fps) == (640,480,24), 'YXV_PROFILE','default profile is 640x480@24')
    require(1 <= count <= 512, 'FRAME_COUNT','1..512 frames required')
    frames_off = align512(32+count*8)
    data = bytearray(frames_off)
    for index, frame in enumerate(frames):
        struct.pack_into('<II',data,32+index*8,len(data),len(frame))
        data.extend(frame)
        data.extend(bytes((-len(data)) % 512))
    audio_off = len(data)
    data.extend(pcm)
    require(len(data) <= SLOT_BYTES, 'SLOT_SIZE','container exceeds video slot')
    struct.pack_into('<4sBBHHHIIIII',data,0,b'YXV1',1,2,width,height,fps,count,48000,len(pcm),32,frames_off)
    return bytes(data), audio_off

def inspect_container(data, *, enforce_cycles=True):
    require(32 <= len(data) <= SLOT_BYTES, 'YXV_SIZE','header/slot length')
    magic, version, ch, width, height, fps, count, rate, abytes, toff, foff = struct.unpack_from('<4sBBHHHIIIII',data)
    require((magic,version,ch,rate) == (b'YXV1',1,2,48000), 'YXV_HEADER','magic/version/channels/rate')
    require((width,height,fps) == (640,480,24), 'YXV_PROFILE','default profile is 640x480@24')
    require(1 <= count <= 512, 'FRAME_COUNT','1..512 frames required')
    require(toff == 32 and foff >= align512(32+8*count) and foff % 512 == 0 and foff <= len(data),
            'YXV_TABLE','table offset/extent/alignment')
    previous, end, reports = -1, foff, []
    for index in range(count):
        offset, size = struct.unpack_from('<II',data,toff+8*index)
        require(index != 0 or offset == foff, 'YXV_TABLE','first frame must start at frames_off')
        require(offset % 512 == 0 and offset > previous and offset >= end,
                'YXV_OVERLAP',f'frame {index} offset overlaps previous/table')
        require(0 < size <= 40960 and offset+align512(size) <= len(data),
                'YXV_FRAME_RANGE',f'frame {index} size/extent')
        jpeg = inspect_jpeg(data[offset:offset+size])
        timing = schedule(jpeg)
        if enforce_cycles:
            require(timing['accepted'], 'CORE_CYCLES', f'frame {index}: {timing["frame_cycles"]} cycles')
        reports.append({'index':index,'jpeg_bytes':size,'header_bytes':jpeg.header_bytes,
                        'entropy_bytes':jpeg.entropy_bytes,'stuffed_bytes':jpeg.stuffed_bytes,
                        'sha256':hashlib.sha256(data[offset:offset+size]).hexdigest(), **timing})
        previous, end = offset, offset+align512(size)
    require(abytes > 0 and abytes % 4 == 0 and end+abytes == len(data), 'YXV_AUDIO','audio length/alignment or trailing bytes')
    require(abs(count/fps-abytes/192000) < 0.1, 'AV_DURATION','audio/video differ by >=0.1s')
    worst = max(reports,key=lambda r:r['frame_cycles'])
    return {'width':width,'height':height,'fps':fps,'frames':count,'audio_rate':rate,
            'audio_bytes':abytes,'audio_off':end,'duration_seconds':count/fps,
            'container_sha256':hashlib.sha256(data).hexdigest(),
            'max_jpeg_bytes':max(r['jpeg_bytes'] for r in reports),
            'worst_frame_index':worst['index'],'worst_frame_cycles':worst['frame_cycles'],
            'worst_frame_ms':worst['frame_ms'],'frame_reports':reports}
