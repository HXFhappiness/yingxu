#!/usr/bin/env python3
"""Reproduce D3 physical/supply/scanout/PCM units, including 512-frame wrap."""
from pathlib import Path
import os,shutil,subprocess
from mjpeg_ref.container import build_container
from mjpeg_ref.vectors import make_jpeg
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'out/mjpeg_d3'
H='src/user_source/hdl_source/';M=H+'media/mjpeg/'
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    v=shutil.which('verilator') or '/workspace/.yingxu-env/verilator/usr/bin/verilator'
    env=os.environ.copy()
    if '.yingxu-env' in v:env['VERILATOR_ROOT']='/workspace/.yingxu-env/verilator/usr/share/verilator'
    fixture,_=build_container([make_jpeg()]*512,bytes(range(256))*16000)
    (OUT/'limit512.yxv').write_bytes(fixture)
    cases=[('physical','tb_mjpeg_physical',['tb/models/d3_sdram_models.v',H+'yingxu_sdram_control_4port.v',M+'yingxu_sdram_burst_port.v',*['src/5640/sdram_ctrl_4p/'+n+'.v'for n in ('command','control_interface','sdr_data_path')]]),
           ('loader','tb_yxv_loader',[M+'yingxu_yxv_loader.v']),
           ('scanout','tb_yxv_scanout',[M+'yingxu_yxv_scanout.v']),
           ('pcm','tb_yxv_pcm',[M+'yingxu_yxv_pcm_feed.v',M+'yingxu_media_async_fifo.v',H+'yingxu_wav_player.v',H+'media/sd/ram_dual_port_simple.v'])]
    def run(args,log):
        with (OUT/log).open('w')as f:rc=subprocess.call([str(a)for a in args],cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT)
        if rc:raise SystemExit((OUT/log).read_text()[-6000:])
    for label,top,src in cases:
        build=OUT/('v'+label)
        run([v,'--binary','--timing','-j','2','-Wno-fatal','--top-module',top,'--Mdir',build,'tb/'+top+'.v',*src],label+'_build.log')
        run([build/('V'+top)],label+'.log')
        print((OUT/(label+'.log')).read_text(),end='',flush=True)
        if label=='loader':
            run([build/('V'+top),'+file=out/mjpeg_d3/limit512.yxv'],'loader512.log')
            print((OUT/'loader512.log').read_text(),end='',flush=True)
if __name__=='__main__':main()
