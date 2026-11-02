#!/usr/bin/env python3
"""D7 full-raster golden pixels, actual sprite composition, and RTL checks."""
from pathlib import Path
import os
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/d7_menu'
HDL = ROOT / 'src/user_source/hdl_source'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    font = (HDL / 'yingxu_cn_font.v').read_text()
    words = []
    for index, block in enumerate(re.split(r"5'd\d+: begin //", font)[1:]):
        rows = re.findall(r"5'd(\d+): bits = 32'h([0-9A-Fa-f]+);", block)
        assert [int(r) for r, _ in rows] == list(range(32)), index
        words += [int(v, 16) for _, v in rows]
    assert len(words) == 17 * 32
    (OUT / 'font.hex').write_text(''.join(f'{word:08x}\n' for word in words))
    verilator = shutil.which('verilator') or '/workspace/.yingxu-env/verilator/usr/bin/verilator'
    yosys = shutil.which('yosys') or '/workspace/.yingxu-env/yosys/usr/bin/yosys'
    env = os.environ.copy()
    if '.yingxu-env' in verilator:
        env['VERILATOR_ROOT'] = '/workspace/.yingxu-env/verilator/usr/share/verilator'
    sources = [HDL / name for name in ('yingxu_cn_font.v', 'yingxu_menu_ui.v', 'yingxu_sprite_engine.v')]
    sources += [ROOT / 'tb/tb_d7_menu_pixels.v']
    build = OUT / 'vpixels'
    jobs = [([verilator, '--binary', '--timing', '-j', '4', '-Wno-fatal',
              '--top-module', 'tb_d7_menu_pixels', '--Mdir', build, *sources], 'build.log'),
            ([build / 'Vtb_d7_menu_pixels', '+font=' + str(OUT / 'font.hex'),
              '+out=' + str(OUT)], 'pixels.log'),
            ([yosys, '-Q', '-T', '-p',
              'read_verilog ' + ' '.join(str(f) for f in sources[:2]) +
              '; hierarchy -check -top yingxu_menu_ui; proc; opt; check -assert; stat'], 'read_check.log')]
    for cmd, name in jobs:
        with (OUT / name).open('w') as log:
            rc = subprocess.call(list(map(str, cmd)), cwd=ROOT, env=env,
                                 stdout=log, stderr=subprocess.STDOUT)
        if rc:
            raise SystemExit((OUT / name).read_text()[-7000:])
    print((OUT / 'pixels.log').read_text(), end='')
    print('Yosys read/proc/opt/check: PASS')


if __name__ == '__main__':
    main()
