#!/usr/bin/env python3
"""Prepare independent D2 goldens and run complete RTL/transport regressions.

Python3 + numpy; Verilator5 + C++ compiler (or --sim iverilog, much slower).
No TD or board result is inferred from this tool. Outputs stay under out/.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time
import numpy as np

from mjpeg_ref.container import build_container
from mjpeg_ref.jpeg import inspect_jpeg, ProfileError
from mjpeg_ref.rtl import decode, table_images, choose_owner, mailbox_status
from mjpeg_ref.vectors import make_jpeg, Writer

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/mjpeg_d2'
RTL=sorted((ROOT/'src/user_source/hdl_source/media/mjpeg').glob('*.v'))


def write_hex(path, values, width):
    path.write_text(''.join(f'{int(x)&((1<<width)-1):0{(width+3)//4}x}\n'
                            for x in np.asarray(values).flat),encoding='ascii')


def export_core(prefix, data, decoded):
    jpeg,c,temp,samples,pixels=decoded
    for suffix, values, width in [('jpg',list(data),8),('coef',c,24),('temp',temp,27),
                                  ('samples',samples,8),('pixels',pixels,16)]:
        write_hex(Path(str(prefix)+'.'+suffix+'.hex'),values,width)
    for suffix,values,width in zip(('table','tablemask','desc','descmask'),
                                    table_images(jpeg),(8,1,16,1)):
        write_hex(Path(str(prefix)+'.'+suffix+'.hex'),values,width)


def valid_vectors():
    common=make_jpeg(7200,quantizer=3,dc_values=(-8,4,-2))
    tid=bytearray(common)
    tid[tid.index(b'\xff\xdb')+4]=1
    sof=tid.index(b'\xff\xc0')
    for i in (12,15,18): tid[sof+i]=1
    dht=tid.index(b'\xff\xc4');tid[dht+4]=1;tid[dht+33]=0x11
    sos=tid.index(b'\xff\xda')
    for i in (6,8,10): tid[sos+i]=0x11
    return [make_jpeg(7200,restart=n,quantizer=3,dc_values=(-8,4,-2)) for n in (1,3,40)]+[
        make_jpeg(7200,long_codes=True,quantizer=9,dc_values=(-8,4,-2)),bytes(tid),
        make_jpeg(7200,quantizer=255,dc_values=(1000,-600,300))]


def invalid_vectors():
    b=make_jpeg();dht=b.index(b'\xff\xc4');dqt=b.index(b'\xff\xdb');sof=b.index(b'\xff\xc0')
    def patch(offset,value):
        v=bytearray(b);v[offset]=value;return bytes(v)
    ns=int.from_bytes(b[dht+2:dht+4],'big')
    start=inspect_jpeg(b).header_bytes
    wr=Writer();wr.put(0,1)
    for _ in range(4): wr.put(6,3)
    wr.align()
    badrun=b[:start]+bytes(wr.out)+b'\xff\xd9'
    wr=Writer();wr.put(65535,16);wr.align()
    invalidcode=b[:start]+bytes(wr.out)+b'\xff\xd9'
    rst=make_jpeg(restart=1)
    return dict(
        bad_rst=(rst.replace(b'\xff\xd0',b'\xff\xd2',1),0x25),
        zero_quant=(patch(dqt+5,0),0x0a),
        non420=(patch(sof+11,0x11),0x10),
        progressive=(patch(sof+1,0xc2),0x04),
        missing_dht=(b[:dht]+b[dht+ns+2:],0x12),
        bad_run=(badrun,0x23),
        invalid_code=(invalidcode,0x21),
        trailing=(b+b'x',0x26),
        segment_extent=(b'\xff\xd8\xff\xdb\xff\xff',0x05),
        duplicate_symbol=(patch(dht+22,0),0x0e),
        quant_precision=(patch(dqt+4,0x10),0x09))


def prepare():
    OUT.mkdir(parents=True,exist_ok=True)
    manifest={'vectors':{},'negative':{},'positive':[]}
    for tag in ('budget','stress'):
        data=(ROOT/f'tb/testvectors/testvec_{tag}.yxv').read_bytes()
        count=struct.unpack_from('<I',data,12)[0]
        records=[]
        with (OUT/f'{tag}.rgb565be').open('wb') as fd:
            for f in range(count):
                off,size=struct.unpack_from('<II',data,32+8*f)
                jpg=data[off:off+size];decoded=decode(jpg)
                jpeg,c,temp,samples,pixels=decoded;fd.write(pixels.tobytes())
                records.append({'frame':f,'bytes':size,'sha256':hashlib.sha256(jpg).hexdigest(),
                                'stuffed':jpeg.stuffed_bytes,'coeff_min':int(c.min()),'coeff_max':int(c.max())})
                if f==0 or (tag=='stress' and f==1): export_core(OUT/f'{tag}_{f}',jpg,decoded)
                if f%6==0: print(f'REFERENCE {tag} {f}/{count}',flush=True)
        manifest['vectors'][tag]=records
    good=valid_vectors();container,_=build_container(good,bytes(len(good)*8000))
    (OUT/'synthetic.yxv').write_bytes(container)
    with (OUT/'synthetic.rgb565be').open('wb') as fd:
        for f,jpg in enumerate(good):
            decoded=decode(jpg);fd.write(decoded[-1].tobytes())
            manifest['positive'].append({'frame':f,'bytes':len(jpg),'restarts':decoded[0].restarts,
                                         'max_coefficient':int(abs(decoded[1]).max())})
            if f==5: export_core(OUT/'wide',jpg,decoded)
    flat=make_jpeg();flat_pixels=decode(flat)[-1].tobytes()
    # Invalid frames must fail in the independent parser, before running RTL.
    for name,(jpg,code) in invalid_vectors().items():
        try: inspect_jpeg(jpg,max_bytes=65535,coefficient_bits=24)
        except ProfileError as exc: model_code=exc.code
        else: raise AssertionError('negative vector accepted: '+name)
        payload,_=build_container([jpg,flat],bytes(16000))
        (OUT/f'{name}.yxv').write_bytes(payload)
        (OUT/f'{name}.rgb565be').write_bytes(flat_pixels*2)
        manifest['negative'][name]={'bytes':len(jpg),'rtl_code':code,'model_code':model_code}
    (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('REFERENCE: PASS 72 real frames, 6 synthetic, 11 malformed+recovery fixtures',flush=True)


def command(argv,log,env=None,timeout=600):
    t=time.monotonic()
    result=subprocess.run([str(v) for v in argv],cwd=ROOT,env=env,stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT,text=True,timeout=timeout)
    (OUT/log).write_text(result.stdout,encoding='utf-8')
    if result.returncode: raise RuntimeError(f'exit={result.returncode} {argv!r}\n'+result.stdout[-6000:])
    return {'argv':[str(v) for v in argv],'exit':result.returncode,'log':log,'seconds':time.monotonic()-t}


def simulator(kind):
    env=os.environ.copy()
    if kind=='verilator':
        binary=shutil.which('verilator')
        local=Path('/workspace/.yingxu-env/verilator/usr/bin/verilator')
        if not binary and local.exists():
            binary=str(local);env['VERILATOR_ROOT']='/workspace/.yingxu-env/verilator/usr/share/verilator'
        if not binary: raise RuntimeError('verilator not found; install or use --sim iverilog')
    else:
        binary=shutil.which('iverilog')
        if not binary: raise RuntimeError('iverilog not found')
    return binary,env


def run(sim='verilator',quick=False,jobs=2):
    manifest=json.loads((OUT/'manifest.json').read_text())
    binary,env=simulator(sim);records=[];executables={}
    for top,tb in [('tb_mjpeg_core','tb/tb_mjpeg_core.v'),('tb_mjpeg_sdram','tb/tb_mjpeg_sdram.v'),
                   ('tb_mjpeg_arbiter','tb/tb_mjpeg_bus.v'),('tb_mjpeg_mailbox','tb/tb_mjpeg_bus.v')]:
        if sim=='verilator':
            build=OUT/('build_'+top)
            argv=[binary,'--binary','--timing','-j','4','-Wno-fatal','--top-module',top,'--Mdir',build,tb,*RTL]
            records.append(command(argv,top+'.build.log',env))
            executables[top]=[build/('V'+top)]
        else:
            image=OUT/(top+'.vvp')
            records.append(command([binary,'-g2012','-s',top,'-o',image,tb,*RTL],top+'.build.log',env))
            executables[top]=['vvp',image]
    tasks=[]
    def add(name,top,*args): tasks.append((name,executables[top]+list(args)))
    for tag,f in [('budget',0),('stress',0),('stress',1)]:
        size=manifest['vectors'][tag][f]['bytes']
        add(f'{tag}_{f}_core','tb_mjpeg_core',f'+prefix=out/mjpeg_d2/{tag}_{f}',f'+length={size}','+stalls=1')
    add('wide_core','tb_mjpeg_core','+prefix=out/mjpeg_d2/wide',f'+length={manifest["positive"][5]["bytes"]}','+stalls=1')
    for tag in ('budget','stress'):
        add(tag+'36','tb_mjpeg_sdram',f'+file=tb/testvectors/testvec_{tag}.yxv',f'+gold=out/mjpeg_d2/{tag}.rgb565be',
            f'+limit={1 if quick else 36}','+pressure=1',f'+dump=out/mjpeg_d2/{tag}_f0_rtl.rgb565be')
    add('stress1','tb_mjpeg_sdram','+file=tb/testvectors/testvec_stress.yxv','+gold=out/mjpeg_d2/stress.rgb565be',
        '+first=1','+limit=1','+pressure=1','+dump=out/mjpeg_d2/stress_f1_rtl.rgb565be')
    add('synthetic','tb_mjpeg_sdram','+file=out/mjpeg_d2/synthetic.yxv','+gold=out/mjpeg_d2/synthetic.rgb565be','+limit=6','+pressure=1')
    for name,fault,code in [('truncated',1,0x20),('baddht',2,0x0c),('read_error',4,0x82),('write_error',5,0x82),('bad_rlast',6,0x81)]:
        add(name,'tb_mjpeg_sdram','+file=tb/testvectors/testvec_budget.yxv','+gold=out/mjpeg_d2/budget.rgb565be',
            '+limit=2','+pressure=1',f'+fault={fault}',f'+expect_code={code}')
    for name,info in manifest['negative'].items():
        add(name,'tb_mjpeg_sdram',f'+file=out/mjpeg_d2/{name}.yxv',f'+gold=out/mjpeg_d2/{name}.rgb565be',
            '+limit=2','+pressure=1','+fault=3',f'+expect_code={info["rtl_code"]}')
    for name in ('arbiter','mailbox'): add(name,'tb_mjpeg_'+name)
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures={pool.submit(command,argv,name+'.log',env):name for name,argv in tasks}
        for future in concurrent.futures.as_completed(futures):
            result=future.result();records.append(result);print(f'{futures[future]}: exit=0',flush=True)
    validate_bus_traces()
    report={'quick':quick,'commands':records,'psnr':measure_psnr(),
            'sources_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in RTL+[ROOT/'tb/tb_mjpeg_core.v',ROOT/'tb/tb_mjpeg_sdram.v',ROOT/'tb/tb_mjpeg_bus.v']}}
    (OUT/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print('D2 software verification complete; TD mapping/timing and physical SDRAM integration remain separate.')


def validate_bus_traces():
    grants=[int(x) for x in re.findall(r'GRANT_TRACE: owner=(\d+)',(OUT/'arbiter.log').read_text())]
    expected=[choose_owner(7),choose_owner(6),choose_owner(4),choose_owner(5,held=2),choose_owner(1)]
    if grants!=expected: raise AssertionError('arbiter Python/RTL trace mismatch')
    values=re.findall(r'MAILBOX_TRACE: payload=([0-9a-fA-F]+) status=([0-9a-fA-F]+)',(OUT/'mailbox.log').read_text())
    if len(values)!=16 or any(mailbox_status(int(p,16))!=int(s,16) for p,s in values):
        raise AssertionError('mailbox Python/RTL trace mismatch')
    print('TRANSPORT_REFCHK: PASS arbiter 5/5, mailbox 16/16',flush=True)


def measure_psnr():
    results=[]
    for tag,f in [('budget',0),('stress',0),('stress',1)]:
        pixels=np.frombuffer((OUT/f'{tag}_f{f}_rtl.rgb565be').read_bytes(),dtype='>u2').astype(np.int64)
        if pixels.size!=307200: raise AssertionError('incomplete RTL dump')
        r,g,b=(pixels>>11)&31,(pixels>>5)&63,pixels&31
        expanded=np.stack([(r<<3)|(r>>2),(g<<2)|(g>>4),(b<<3)|(b>>2)],axis=1)
        zero=np.stack([r<<3,g<<2,b<<3],axis=1)
        ref=np.frombuffer((ROOT/f'tb/testvectors/ref_{tag}_f{f:03d}.rgb').read_bytes(),np.uint8).reshape(-1,3).astype(np.int64)
        a=float(10*np.log10(255**2/((expanded-ref)**2).mean()))
        z=float(10*np.log10(255**2/((zero-ref)**2).mean()))
        if min(a,z)<35: raise AssertionError('PSNR below35dB')
        record={'vector':tag,'frame':f,'psnr_bitrep_db':a,'psnr_zeroextend_db':z}
        results.append(record);print('PSNRCHK',record,flush=True)
    return results


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--prepare-only',action='store_true');ap.add_argument('--run-only',action='store_true')
    ap.add_argument('--quick',action='store_true',help='only first real frames; never counts as 36-frame acceptance')
    ap.add_argument('--sim',choices=('verilator','iverilog'),default='verilator');ap.add_argument('--jobs',type=int,default=2)
    a=ap.parse_args()
    if not a.run_only: prepare()
    if not a.prepare_only: run(a.sim,a.quick,a.jobs)

if __name__=='__main__': main()
