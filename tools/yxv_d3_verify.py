#!/usr/bin/env python3
"""Build the ACTUAL board top against media primitives; run 3s at true clocks.

No board or TD result is inferred. Generate D2 goldens first with
python tools/mjpeg_d2_verify.py --prepare-only.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/mjpeg_d3'

def main():
    p=argparse.ArgumentParser();p.add_argument('--build-only',action='store_true');p.add_argument('--no-build',action='store_true')
    p.add_argument('--sw',type=lambda x:int(x,0),default=0x77);p.add_argument('--frames',type=int,default=72);p.add_argument('--bad',type=int,default=0);p.add_argument('--noinit',action='store_true')
    a=p.parse_args();OUT.mkdir(parents=True,exist_ok=True)
    binary=shutil.which('verilator') or '/workspace/.yingxu-env/verilator/usr/bin/verilator'
    env=os.environ.copy()
    if '.yingxu-env' in binary:env['VERILATOR_ROOT']='/workspace/.yingxu-env/verilator/usr/share/verilator'
    sources=[]
    for s in re.findall(r'<File Path="([^"]+\.v)">',(ROOT/'AC201_AL_board_test.al').read_text()):
        if any(x in s for x in ('Sdram_PLL.v','Sdram_RD_FIFO.v','Sdram_WR_FIFO.v','.enc.v','hdmi_phy_warpper.v','lane_lvds_10_1.v')):continue
        if '/media/sd/' in s and Path(s).name not in ('sd_stream_reader.v','sd_stream_reader_core.v','ram_dual_port_simple.v','yingxu_sd_integration_probe.v'):continue
        sources.append(s)
    sources+=list(str(f.relative_to(ROOT)) for f in sorted((ROOT/'src/user_source/hdl_source/media/mjpeg').glob('*.v')))
    sources=list(dict.fromkeys(sources))
    sources+=['tb/models/d3_sdram_models.v','tb/models/d3_board_models.v','tb/tb_yxv_top.v']
    (OUT/'top_sources.f').write_text('\n'.join(sources)+'\n')
    def run(cmd,log):
        t=time.monotonic()
        with (OUT/log).open('w') as f:rc=subprocess.call([str(v) for v in cmd],cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT)
        print(f'{log}: exit={rc} seconds={time.monotonic()-t:.2f}',flush=True)
        if rc:raise SystemExit((OUT/log).read_text()[-10000:])
    build=OUT/('vtop_noinit' if a.noinit else 'vtop')
    if not a.no_build:run([binary,'--binary','--timing','-j','4','-Wno-fatal','--top-module','tb_yxv_top','--Mdir',build,*(['-GACQUIRE_LIMIT_TEST=750000']if a.noinit else []),'-f',OUT/'top_sources.f'],'top_noinit_build.log'if a.noinit else 'top_build.log')
    label=f'top_sw{a.sw:02x}_{a.frames}_bad{a.bad}'+('_noinit'if a.noinit else '')
    if not a.build_only:
        uart=OUT/(label+'.uart.txt')
        run([build/'Vtb_yxv_top','+file=tb/testvectors/testvec_budget.yxv','+gold=out/mjpeg_d2/budget.rgb565be',f'+sw={a.sw:02x}',f'+frames={a.frames}',f'+bad={a.bad}',f'+noinit={int(a.noinit)}',f'+uart={uart}'],label+'.log')
        if not a.bad and not a.noinit and a.frames>=72:
            rows=[{k:int(v,16)for k,v in re.findall(r'(\w+)=([0-9A-F]+)',line)}for line in uart.read_text().splitlines()if line.startswith('D ')]
            owned=[d for d in rows if d.get('I0',0)&0x800000]
            assert len(owned)>=12 and all(d['DW']==0 and d['SP']==48000 and d['SW']==a.sw for d in owned),owned
            assert max(d['RC']for d in owned)>=60 and max(d['MISE']for d in owned)>=60,owned
            print(f'TELEMCHK: PASS wire UART D-lines={len(owned)} decoded/display/drop/SD fields visible',flush=True)

if __name__=='__main__':main()
