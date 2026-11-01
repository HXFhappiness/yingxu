#!/usr/bin/env python3
"""D4f full 486/512 PCM preload via actual reader, pipeline and physical controller."""
from pathlib import Path
import argparse,os,shutil,subprocess
from mjpeg_ref.container import build_container
from mjpeg_ref.vectors import make_jpeg
R=Path(__file__).resolve().parents[1];O=R/'out/mjpeg_d4f';M=R/'src/user_source/hdl_source/media/mjpeg';S=R/'src/user_source/hdl_source/media/sd';H=R/'src/user_source/hdl_source'
def main():
    p=argparse.ArgumentParser();p.add_argument('--frames',type=int,default=486);p.add_argument('--block',type=int,default=0);p.add_argument('--no-build',action='store_true');a=p.parse_args()
    O.mkdir(parents=True,exist_ok=True)
    pcm=bytes(((i*37)^(i>>8)^(i>>16)^0xa7)&255 for i in range(a.frames*8000))
    fixture,_=build_container([make_jpeg()]*a.frames,pcm);f=O/f'pcm{a.frames}.yxv';f.write_bytes(fixture)
    model=(R/'tb/models/d3_board_models.v').read_text().split('module pll_hdmi1_4b')[0]
    model=model.replace('[0:2999999]','[0:8388607]')
    (O/'card_model.v').write_text(model)
    v=shutil.which('verilator') or '/workspace/.yingxu-env/verilator/usr/bin/verilator';env=os.environ.copy()
    if '.yingxu-env' in v:env['VERILATOR_ROOT']='/workspace/.yingxu-env/verilator/usr/share/verilator'
    build=O/'vpreload'
    sources=[R/'tb/tb_yxv_preload.v',O/'card_model.v',R/'tb/models/d3_sdram_models.v',H/'yingxu_sdram_control_4port.v',H/'media/bmp/bmp_header_parser.v',*[S/x for x in ('sd_stream_reader.v','sd_stream_reader_core.v','yingxu_sd_integration_probe.v','ram_dual_port_simple.v')],*sorted(M.glob('*.v')),*[R/'src/5640/sdram_ctrl_4p'/f'{x}.v' for x in ('command','control_interface','sdr_data_path')]]
    commands=[] if a.no_build else [([v,'--binary','--timing','-j','4','-Wno-fatal','--top-module','tb_yxv_preload','--Mdir',build,*sources],'preload_build.log')]
    commands.append(([build/'Vtb_yxv_preload',f'+file={f}',f'+block={a.block}'],f'preload_{a.frames}_block{a.block}.log'))
    for args,log in commands:
        with (O/log).open('w') as out:rc=subprocess.call([str(x) for x in args],cwd=R,env=env,stdout=out,stderr=subprocess.STDOUT)
        print(f'{log}: exit={rc}',flush=True)
        if rc:raise SystemExit((O/log).read_text()[-8000:])
    print((O/f'preload_{a.frames}_block{a.block}.log').read_text(),end='')
if __name__=='__main__':main()
