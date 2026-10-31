"""Reproduce exact-40KiB high-entropy cycle measurements, including rejected frames."""
import argparse
import hashlib
import json
import platform
from pathlib import Path
from mjpeg_ref.jpeg import inspect_jpeg
from mjpeg_ref.cycles import schedule
from mjpeg_ref.vectors import boundary_frame, make_jpeg

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',default='out/mjpeg_d1')
    a=ap.parse_args()
    out=Path(a.out); out.mkdir(parents=True,exist_ok=True)
    cases=[('dc_only',make_jpeg()),('custom_rst40',make_jpeg(7200,restart=40,quantizer=3)),
           ('40k_short_balanced',boundary_frame()),
           ('40k_short_frontloaded',boundary_frame(style='frontloaded')),
           ('40k_short_backloaded',boundary_frame(style='backloaded')),
           ('40k_16bit_codes',boundary_frame(long_codes=True))]
    results=[]
    for name,data in cases:
        jpeg=inspect_jpeg(data)
        r={'name':name,'jpeg_bytes':len(data),'header_bytes':jpeg.header_bytes,
           'entropy_bytes':jpeg.entropy_bytes,'sha256':hashlib.sha256(data).hexdigest(),
           'restarts':jpeg.restarts,**schedule(jpeg)}
        (out/(name+'.jpg')).write_bytes(data)
        results.append(r)
        print(f'{name}: {len(data)} bytes, {r["frame_cycles"]} cycles, {r["frame_ms"]:.5f} ms, accepted={r["accepted"]}')
    boundary=[r for r in results if r['jpeg_bytes']==40960]
    if len(boundary) != 4 or not any(r['accepted'] for r in boundary) or not any(not r['accepted'] for r in boundary):
        raise RuntimeError('Boundary corpus must include four exact-40KiB frames and both accepted/rejected cases')
    report={'python':platform.python_version(),'kind':'Python-model measurements, NOT RTL/hardware',
            'cases':results,'worst_40k_case':max(boundary,key=lambda r:r['frame_cycles'])['name'],
            'max_40k_cycles':max(r['frame_cycles'] for r in boundary),
            'scope':'maximum across this explicitly generated corpus, not exhaustive maximum over all legal JPEGs'}
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')

if __name__=='__main__':
    main()
