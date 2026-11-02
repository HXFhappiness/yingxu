#!/usr/bin/env python3
"""Compare production photo replay with a disposable blanking-flush candidate.

The candidate is written under out/ only; production RTL is never modified.
Actual replay/controller RTL runs against functional FIFO/SDRAM/PLL models.
"""
from pathlib import Path
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
HDL = ROOT / 'src/user_source/hdl_source'
OUT = ROOT / 'out/photo_phase_check'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    player = (HDL / 'yingxu_sdram_video_player.v').read_text()
    controller = (HDL / 'yingxu_sdram_control_4port.v').read_text()
    replacements = {
        'reg [2:0]  load_cnt;': 'reg [7:0]  load_cnt;',
        "load_cnt == 3'd7": "load_cnt == 8'd255",
        "load_cnt + 3'd1": "load_cnt + 8'd1",
    }
    for old, new in replacements.items():
        if player.count(old) != 1:
            raise SystemExit(f'Expected exactly one replay fragment: {old}')
        player = player.replace(old, new)
    old = '(MJPEG_PORT && MJ_ACTIVE && RD2_LOAD)'
    if controller.count(old) != 1:
        raise SystemExit('Production FIFO reset has changed; review candidate')
    controller = controller.replace(old, 'RD2_LOAD')
    (OUT / 'player_flush.v').write_text(player)
    (OUT / 'controller_flush.v').write_text(controller)
    verilator = shutil.which('verilator') or '/workspace/.yingxu-env/verilator/usr/bin/verilator'
    env = os.environ.copy()
    if '.yingxu-env' in verilator:
        env['VERILATOR_ROOT'] = '/workspace/.yingxu-env/verilator/usr/share/verilator'
    common = [ROOT / 'tb/tb_photo_phase.v', ROOT / 'tb/models/d3_sdram_models.v',
              HDL / 'media/mjpeg/yingxu_sdram_burst_port.v']
    common += [ROOT / f'src/5640/sdram_ctrl_4p/{name}.v'
               for name in ('command', 'control_interface', 'sdr_data_path')]
    for candidate in (False, True):
        tag = 'flush_candidate' if candidate else 'production'
        build = OUT / ('v_' + tag)
        sources = common + ([OUT / 'player_flush.v', OUT / 'controller_flush.v'] if candidate else
                            [HDL / 'yingxu_sdram_video_player.v', HDL / 'yingxu_sdram_control_4port.v'])
        cmd = [verilator, '--binary', '--timing', '-j', '4', '-Wno-fatal',
               '--top-module', 'tb_photo_phase', '--Mdir', build, *sources]
        with (OUT / (tag + '_build.log')).open('w') as log:
            rc = subprocess.call(list(map(str, cmd)), cwd=ROOT, env=env,
                                 stdout=log, stderr=subprocess.STDOUT)
        if rc:
            raise SystemExit((OUT / (tag + '_build.log')).read_text()[-6000:])
        cmd = [str(build / 'Vtb_photo_phase'), f'+expect_stable={int(candidate)}']
        with (OUT / (tag + '.log')).open('w') as log:
            rc = subprocess.call(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        result = (OUT / (tag + '.log')).read_text()
        print(tag + ':\n' + result, end='', flush=True)
        if rc:
            raise SystemExit(rc)


if __name__ == '__main__':
    main()
