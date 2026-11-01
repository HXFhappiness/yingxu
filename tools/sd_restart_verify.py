#!/usr/bin/env python3
"""Check restart semantics without editing vendor RTL; raw logs in out/mjpeg_d3."""
from pathlib import Path
import argparse,os,shutil,subprocess
R=Path(__file__).resolve().parents[1];O=R/'out/mjpeg_d3';S=R/'src/user_source/hdl_source/media/sd'
def main():
    p=argparse.ArgumentParser();p.add_argument('--vendor-only',action='store_true');a=p.parse_args()
    O.mkdir(parents=True,exist_ok=True)
    iv='/workspace/.yingxu-env/bin/iverilog';vvp='/workspace/.yingxu-env/bin/vvp'
    cases=[('restart_semantics','tb_sd_restart_semantics',[R/'tb/tb_sd_restart_semantics.v',R/'tb/models/sd_restart_service.v',S/'yingxu_sd_integration_probe.v',S/'sd_stream_reader.v',S/'sd_stream_reader_core.v',R/'src/user_source/hdl_source/media/bmp/bmp_header_parser.v'])]
    if a.vendor_only:cases=[]
    for label,top,src in cases:
        image=O/(label+'.vvp')
        for args,log in [([iv,'-g2012','-s',top,'-o',image,*src],label+'_build.log'),([vvp,image],label+'.log')]:
            with (O/log).open('w') as f:rc=subprocess.call([str(x) for x in args],cwd=R,stdout=f,stderr=subprocess.STDOUT)
            if rc:raise SystemExit((O/log).read_text()[-6000:])
        print((O/(label+'.log')).read_text(),end='',flush=True)
    # Keep vendor Verilog-2005 unchanged: parameter 'var' is a legacy keyword
    # conflict in SystemVerilog; Icarus also rejects its unsized concat math.
    v=shutil.which('verilator') or '/workspace/.yingxu-env/verilator/usr/bin/verilator'
    env=os.environ.copy()
    if '.yingxu-env' in v:env['VERILATOR_ROOT']='/workspace/.yingxu-env/verilator/usr/share/verilator'
    build=O/'vvendor_idle'
    commands=[([v,'--binary','--timing','--language','1800-2017','+1364-2005ext+v','-j','2','-Wno-fatal','--top-module','tb_sd_vendor_idle','--Mdir',build,R/'tb/tb_sd_vendor_idle.sv',*sorted(S.glob('*.v'))],'vendor_idle_build.log'),([build/'Vtb_sd_vendor_idle'],'vendor_idle.log')]
    for args,log in commands:
        with (O/log).open('w') as f:rc=subprocess.call([str(x) for x in args],cwd=R,env=env,stdout=f,stderr=subprocess.STDOUT)
        if rc:raise SystemExit((O/log).read_text()[-6000:])
    print((O/'vendor_idle.log').read_text(),end='',flush=True)
if __name__=='__main__':main()
