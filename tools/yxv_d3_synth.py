#!/usr/bin/env python3
"""D3 structural BRAM count and conservative DSP-excluded LUT4 proxy, NOT TD.

Includes the complete YXV pipeline; physical adapter charged separately.
No pin timing, DSP packing or board acceptance is inferred.
"""
import json,os,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'out/mjpeg_d3'
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    binary=shutil.which('yosys') or '/workspace/.yingxu-env/yosys/usr/bin/yosys'
    env=os.environ.copy();env['PATH']=str(Path(binary).parent)+os.pathsep+env.get('PATH','')
    def run(flow,log):
        with (OUT/log).open('w')as f:rc=subprocess.call([binary,'-Q','-T','-p',flow],cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT)
        if rc:raise SystemExit((OUT/log).read_text()[-6000:])
    run('read_verilog -sv src/user_source/hdl_source/media/mjpeg/*.v; hierarchy -check -top yingxu_yxv_pipeline; proc; flatten; opt; wreduce; opt; memory_dff; memory_share; memory_collect; opt_clean; check -assert; memory_libmap -lib +/anlogic/brams.txt -lib +/anlogic/lutrams.txt; techmap -map +/anlogic/brams_map.v -map +/anlogic/lutrams_map.v; stat; write_json out/mjpeg_d3/physical_ram.json','resource_ram.log')
    proxy=OUT/'dsp_proxy.v'
    proxy.write_text('(* blackbox *) module MJPEG_DSP_PROXY #(parameter A_SIGNED=0,B_SIGNED=0,A_WIDTH=1,B_WIDTH=1,Y_WIDTH=1)(input [A_WIDTH-1:0] A,input [B_WIDTH-1:0] B,output [Y_WIDTH-1:0] Y);endmodule\n')
    # Fresh Yosys processes can reuse private auto IDs from a JSON snapshot.
    # Enumerating those IDs prevents techmap name collisions, without changes
    # to the graph, RAM mapping, logic costs or the RTL being estimated.
    run('read_json out/mjpeg_d3/physical_ram.json; rename -enumerate; read_verilog -lib +/anlogic/cells_sim.v +/anlogic/eagle_bb.v; read_verilog -lib out/mjpeg_d3/dsp_proxy.v; chtype -set MJPEG_DSP_PROXY t:$mul; hierarchy -check -top yingxu_yxv_pipeline; synth_anlogic -top yingxu_yxv_pipeline -run map_ffram:map_luts; abc -lut 4; clean; synth_anlogic -top yingxu_yxv_pipeline -run map_cells:edif; stat; write_json out/mjpeg_d3/lut_proxy.json','resource_lut.log')
    net=json.loads((OUT/'lut_proxy.json').read_text())['modules']['yingxu_yxv_pipeline']['cells']
    counts={k:sum(c['type']==k for c in net.values()) for k in sorted({c['type'] for c in net.values()})}
    charge=sum(counts.get('AL_MAP_LUT'+str(n),0)for n in range(1,5))+2*counts.get('AL_MAP_LUT5',0)+4*counts.get('AL_MAP_LUT6',0)+counts.get('AL_MAP_ADDER',0)+4*counts.get('EG_LOGIC_DRAM16X4',0)
    result={'TD_measured':False,'mapping':'native LUT4 ABC target, Yosys width reduction; not a TD netlist','scope':'entire pipeline including decoder, loader, two arbiters, CDC, PCM, scanout; excludes external physical adapter/controller delta','conservative_LUT4_charge':charge,'split_product_adders':344,'pipeline_LUT_estimate':charge+344,'BRAM_structural':counts.get('EG_PHY_BRAM',0),'DSP18_estimate':21,'cell_counts':counts}
    (OUT/'resource_estimate.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
