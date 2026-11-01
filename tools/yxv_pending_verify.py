#!/usr/bin/env python3
"""D4e pending-fault visibility; abstract SD, actual pipeline and arbiters."""
from pathlib import Path
import os,shutil,subprocess
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'out/mjpeg_d3'
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    v=shutil.which('verilator') or '/workspace/.yingxu-env/verilator/usr/bin/verilator'
    env=os.environ.copy()
    if '.yingxu-env' in v:env['VERILATOR_ROOT']='/workspace/.yingxu-env/verilator/usr/share/verilator'
    build=OUT/'vpending';sources=sorted((ROOT/'src/user_source/hdl_source/media/mjpeg').glob('*.v'))
    for args,log in [([v,'--binary','--timing','-j','4','-Wno-fatal','--top-module','tb_yxv_fault_pending','--Mdir',build,'tb/tb_yxv_fault_pending.v',*sources],'pending_build.log'),([build/'Vtb_yxv_fault_pending'],'pending.log')]:
        with (OUT/log).open('w') as f:rc=subprocess.call([str(a) for a in args],cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT)
        if rc:raise SystemExit((OUT/log).read_text()[-6000:])
    print((OUT/'pending.log').read_text(),end='')
if __name__=='__main__':main()
