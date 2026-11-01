#!/usr/bin/env python3
"""Init-once proof, full 7594-sector stream, and fault->reset causal checks.

Transaction SD models are used for byte streams; this is not pin/card validation.
"""
from pathlib import Path
import re,shutil,subprocess,sys
R=Path(__file__).resolve().parents[1];O=R/'out/reader_reset_audit'
def main():
    O.mkdir(parents=True,exist_ok=True)
    y=shutil.which('yosys') or '/workspace/.yingxu-env/yosys/usr/bin/yosys'
    flow='read_verilog src/user_source/hdl_source/media/sd/sd_stream_reader_core.v tb/formal/sd_init_once.v; prep -top init_once_formal -flatten; async2sync; opt_clean; sat -seq 4 -tempinduct -maxsteps 12 -set-init-zero -set rst 0 -set-at 1 rst 1 -prove safe 1 -verify'
    with (O/'init_once_formal.log').open('w')as f:
        subprocess.run([y,'-Q','-T','-p',flow],cwd=R,stdout=f,stderr=subprocess.STDOUT,check=True)
    log=(O/'init_once_formal.log').read_text()
    assert 'Induction step proven: SUCCESS!' in log
    print('INIT_ONCE_PROOF: PASS arbitrary start/count/ready/done; after initialization, no init_done drop or mode0 until reset',flush=True)
    subprocess.run([sys.executable,'tools/sd_restart_verify.py'],cwd=R,check=True)
    for block in (1,4,6,7):
        args=[sys.executable,'tools/yxv_preload_verify.py','--block',str(block)]
        if block!=1:args+=['--no-build']
        subprocess.run(args,cwd=R,check=True)
    subprocess.run([sys.executable,'tools/yxv_preload_verify.py','--no-recovery','--block','7'],cwd=R,check=True)
    before=(R/'out/mjpeg_d4f/preload_486_block7_norecovery.log').read_text()
    after=(R/'out/mjpeg_d4f/preload_486_block7.log').read_text()
    tick=lambda s:re.search(r'fault=(\d+)',s).group(1)
    assert tick(before)==tick(after),'Replay extended the original watchdog'
    print('REPLAY_BOUNDCHK: PASS persistent loss still faults at the same watchdog tick; at most one replay',flush=True)
    subprocess.run([sys.executable,'tools/yxv_preload_verify.py','--fast-card','--block','8'],cwd=R,check=True)
if __name__=='__main__':main()
