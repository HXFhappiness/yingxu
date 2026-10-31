"""Inspect YXV/JPEG and optionally export point traces for later RTL comparison."""
import argparse
import hashlib
import json
from pathlib import Path
from .jpeg import inspect_jpeg, ProfileError
from .container import inspect_container
from .cycles import schedule
from .image import idct_int, decode_rgb565

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('input')
    ap.add_argument('--report')
    ap.add_argument('--trace-prefix',help='JPEG only: emit coefficient/IDCT JSONL and RGB565 binary')
    ap.add_argument('--allow-cycle-failure',action='store_true',help='diagnostic only; does not mark the frame accepted')
    a=ap.parse_args()
    try:
        data=Path(a.input).read_bytes()
        if data[:4] == b'YXV1':
            if a.trace_prefix:
                ap.error('--trace-prefix requires one JPEG')
            report=inspect_container(data,enforce_cycles=not a.allow_cycle_failure)
        else:
            jpeg=inspect_jpeg(data,collect_coefficients=bool(a.trace_prefix),collect_trace=bool(a.trace_prefix))
            report={'jpeg_bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),**schedule(jpeg)}
            if a.trace_prefix:
                prefix=Path(a.trace_prefix)
                prefix.parent.mkdir(parents=True,exist_ok=True)
                tables={'quant_zigzag':jpeg.quant_tables,'huffman':{}}
                for key,table in jpeg.huffman_tables.items():
                    tables['huffman'][f'{key[0]}:{key[1]}']={'descriptors':jpeg.huffman_descriptors[key],
                        'codes':[{'length':n,'code':code,'symbol':sym} for (n,code),sym in sorted(table.items())]}
                Path(str(prefix)+'.tables.json').write_text(json.dumps(tables,indent=2)+'\n',encoding='utf-8')
                with Path(str(prefix)+'.blocks.jsonl').open('w',encoding='utf-8') as out:
                    for index,b in enumerate(jpeg.blocks):
                        first,samples=idct_int(b.coefficients,intermediate=True)
                        out.write(json.dumps({'block':index,'mcu':b.mcu,'component':b.component,
                                              'subblock':b.subblock,'tokens':b.tokens,'coefficients':b.coefficients,
                                              'idct_first':first,'samples':samples})+'\n')
                pixels=decode_rgb565(jpeg)
                Path(str(prefix)+'.rgb565le').write_bytes(b''.join(p.to_bytes(2,'little') for p in pixels))
            if not report['accepted'] and not a.allow_cycle_failure:
                raise ProfileError('CORE_CYCLES',str(report['frame_cycles']))
        text=json.dumps(report,indent=2,ensure_ascii=False)+'\n'
        if a.report:
            Path(a.report).write_text(text,encoding='utf-8')
        else:
            print(text,end='')
    except (OSError,ProfileError) as e:
        ap.exit(1,f'{e}\n')

if __name__=='__main__':
    main()
