#!/usr/bin/env python3
"""Inductive command stability and exclusive-owner checks on production RTL."""
from pathlib import Path
import shutil
import subprocess

R=Path(__file__).resolve().parents[1]
O=R/'out/d9'

def main():
    O.mkdir(parents=True,exist_ok=True)
    yosys=shutil.which('yosys') or '/workspace/.yingxu-env/yosys/usr/bin/yosys'
    script=('read_verilog src/user_source/hdl_source/media/mjpeg/yingxu_mjpeg_arbiter.v '
            'tb/formal/registered_arbiter.v; prep -top registered_arbiter -flatten; opt; '
            'sat -seq 5 -tempinduct -maxsteps 16 -set-init-zero -set rst 0 -set-at 1 rst 1 -prove safe 1 -verify')
    with(O/'registered_arbiter_formal.log').open('w')as log:
        subprocess.run([yosys,'-Q','-T','-p',script],cwd=R,stdout=log,stderr=subprocess.STDOUT,check=True)
    print('REGISTERED_ARB_FORMAL PASS stable command under arbitrary stalls, exclusive acknowledgement and owner-until-done')

if __name__=='__main__':main()
