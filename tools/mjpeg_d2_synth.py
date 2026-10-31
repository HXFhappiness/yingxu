#!/usr/bin/env python3
"""Reproduce a structural Anlogic RAM map and a DSP-excluded LUT area proxy.

NOT TD synthesis, NOT placement/timing, NOT a functional netlist to flash.
The LUT proxy replaces 13 logical multipliers with black boxes; estimated
21 DSP18 blocks and their split-product adders are accounted for separately.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/mjpeg_d2'


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    binary=shutil.which('yosys')
    local=Path('/workspace/.yingxu-env/yosys/usr/bin/yosys')
    if not binary and local.exists(): binary=str(local)
    if not binary: raise SystemExit('yosys and yosys-abc required; TD is not run by this script')
    env=os.environ.copy();env['PATH']=str(Path(binary).parent)+os.pathsep+env.get('PATH','')
    files=sorted((ROOT/'src/user_source/hdl_source/media/mjpeg').glob('*.v'))
    flow='read_verilog -sv src/user_source/hdl_source/media/mjpeg/*.v; hierarchy -check -top yingxu_mjpeg_decoder; proc; flatten; opt; memory_dff; memory_share; memory_collect; opt_clean; check -assert; memory_libmap -lib +/anlogic/brams.txt -lib +/anlogic/lutrams.txt; techmap -map +/anlogic/brams_map.v -map +/anlogic/lutrams_map.v; stat; write_json out/mjpeg_d2/physical_ram.json'
    def run(args,name):
        proc=subprocess.run([binary,'-Q','-T',*args],cwd=ROOT,env=env,text=True,
                            stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=300)
        (OUT/name).write_text(proc.stdout,encoding='utf-8')
        if proc.returncode: raise RuntimeError(proc.stdout[-6000:])
    run(['-p',flow],'physical_ram.log')
    j=json.loads((OUT/'physical_ram.json').read_text())
    cells=j['modules']['yingxu_mjpeg_decoder']['cells']
    count=lambda typ:sum(c['type']==typ for c in cells.values())
    brams=count('EG_PHY_BRAM')
    if brams>6: raise AssertionError('structural BRAM map exceeds6')
    (OUT/'dsp_proxy.v').write_text("""// AREA PROXY ONLY. Not a functional FPGA netlist.
(* blackbox *) module MJPEG_DSP_PROXY #(parameter A_SIGNED=0,B_SIGNED=0,A_WIDTH=1,B_WIDTH=1,Y_WIDTH=1)
 (input [A_WIDTH-1:0] A,input [B_WIDTH-1:0] B,output [Y_WIDTH-1:0] Y);
endmodule
""")
    proxy="""read_json out/mjpeg_d2/physical_ram.json
read_verilog -lib +/anlogic/cells_sim.v +/anlogic/eagle_bb.v
read_verilog -lib out/mjpeg_d2/dsp_proxy.v
chtype -set MJPEG_DSP_PROXY t:$mul
hierarchy -check -top yingxu_mjpeg_decoder
synth_anlogic -top yingxu_mjpeg_decoder -run map_ffram:check
stat
write_json out/mjpeg_d2/lut_proxy.json
"""
    (OUT/'lut_proxy.ys').write_text(proxy)
    run(['-s','out/mjpeg_d2/lut_proxy.ys'],'lut_proxy.log')
    net=json.loads((OUT/'lut_proxy.json').read_text())['modules']['yingxu_mjpeg_decoder']['cells']
    kinds={c['type'] for c in net.values()}
    counts={k:sum(c['type']==k for c in net.values()) for k in sorted(kinds)}
    # Conservative LUT4 charging: 1..4-input LUT=1, LUT5=2, LUT6=4,
    # one per carry bit, four per 16x4 distributed-RAM macro; not TD accounting.
    charge=sum(counts.get('AL_MAP_LUT'+str(n),0) for n in range(1,5))
    charge+=2*counts.get('AL_MAP_LUT5',0)+4*counts.get('AL_MAP_LUT6',0)
    charge+=counts.get('AL_MAP_ADDER',0)+4*counts.get('EG_LOGIC_DRAM16X4',0)
    split_adders=8*43
    control_reserve=450
    estimate=charge+split_adders+control_reserve
    report={'td_measured':False,'scope':'decoder RAM map; DSP-blackboxed LUT proxy; mailbox/arbiter estimated separately',
            'bram_structural_map':brams,'lut_proxy_cell_counts':counts,
            'conservative_lut4_charge':charge,'wide_product_adder_estimate':split_adders,
            'mailbox_arbiter_reserve':control_reserve,'combined_lut_estimate':estimate,
            'dsp18_estimate':21,'td_timing_ns':None,
            'sources_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}
    if estimate>8000: raise AssertionError('LUT area proxy exceeds8K; redesign before claiming budget')
    (OUT/'resource_estimate.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__': main()
