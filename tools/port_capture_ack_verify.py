#!/usr/bin/env python3
"""Prove receiver capture precedes acknowledgement with arbitrary valid loss."""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/d8_video'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    yosys = shutil.which('yosys') or '/workspace/.yingxu-env/yosys/usr/bin/yosys'
    script = ('read_verilog src/user_source/hdl_source/media/mjpeg/yingxu_sdram_burst_port.v '
              'tb/formal/port_capture_ack.v; prep -top port_capture_ack -flatten; '
              'memory_map; opt; '
              'sat -seq 6 -tempinduct -maxsteps 16 -set-init-zero -set rst 0 '
              '-set-at 1 rst 1 -prove safe 1 -verify')
    with (OUT / 'capture_ack_formal.log').open('w') as log:
        subprocess.run([yosys, '-Q', '-T', '-p', script], cwd=ROOT,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    assert 'Induction step proven: SUCCESS!' in (OUT / 'capture_ack_formal.log').read_text()
    print('CAPTURE_ACK_FORMAL PASS arbitrary valid omission/reset/enable/payload; '
          'capture before ack; latched fields select COLLECT/WAIT/error next cycle')


if __name__ == '__main__':
    main()
