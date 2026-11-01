#!/usr/bin/env python3
"""Reproduce 486-frame first-header diagnosis and done/byte fault injection."""
from pathlib import Path
import os,shutil,subprocess
from mjpeg_ref.container import build_container
from mjpeg_ref.vectors import make_jpeg
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'out/mjpeg_d3'
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    fixture,_=build_container([make_jpeg()]*486,bytes(486*8000))
    (OUT/'diag486.yxv').write_bytes(fixture)
    v=shutil.which('verilator') or '/workspace/.yingxu-env/verilator/usr/bin/verilator'
    env=os.environ.copy()
    if '.yingxu-env' in v:env['VERILATOR_ROOT']='/workspace/.yingxu-env/verilator/usr/share/verilator'
    sources=sorted((ROOT/'src/user_source/hdl_source/media/mjpeg').glob('*.v'))
    def run(args,log):
        with (OUT/log).open('w')as f:rc=subprocess.call([str(x)for x in args],cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT)
        if rc:raise SystemExit((OUT/log).read_text()[-6000:])
    build=OUT/'vdiagnostics'
    run([v,'--binary','--timing','-j','4','-Wno-fatal','--top-module','tb_yxv_diagnostics','--Mdir',build,'tb/tb_yxv_diagnostics.v',*sources],'diagnostics_build.log')
    run([build/'Vtb_yxv_diagnostics'],'diagnostics.log')
    print((OUT/'diagnostics.log').read_text(),end='')
if __name__=='__main__':main()
