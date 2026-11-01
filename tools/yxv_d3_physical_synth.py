#!/usr/bin/env python3
"""Reproduce physical-side native-LUT4 increment, not TD or a usable netlist."""
from pathlib import Path
import os,subprocess,json,shutil
r=Path(__file__).resolve().parents[1];out=r/'out/mjpeg_d3';out.mkdir(parents=True,exist_ok=True)
stub='''(* blackbox *) module Sdram_PLL(input reset,refclk,output clk0_out,clk1_out);endmodule
(* blackbox *) module Sdram_RD_FIFO(input rst,input [31:0] di,input clkw,we,clkr,re,output [31:0] \\do ,output empty_flag,full_flag,afull_flag);endmodule
(* blackbox *) module Sdram_WR_FIFO(input rst,input [31:0] di,input clkw,we,clkr,re,output [31:0] \\do ,output afull_flag,aempty_flag);endmodule
'''
(out/'physical_prims.v').write_text(stub)
# The inherited Verilog declares CS_N scalar at the port and vector[1:0]
# internally. Icarus/TD accept the internal width, while Yosys rejects it.
# This analysis copy makes that implicit internal width explicit; the parent
# framebuffer still consumes only bit 0 in both configurations.
ctrl=(r/'src/user_source/hdl_source/yingxu_sdram_control_4port.v').read_text()
ctrl=ctrl.replace('output                          CS_N;', 'output [1:0]                    CS_N;')
(out/'controller_proxy.v').write_text(ctrl)
binary=shutil.which('yosys') or '/workspace/.yingxu-env/yosys/usr/bin/yosys';env=os.environ.copy();env['PATH']=str(Path(binary).parent)+os.pathsep+env.get('PATH','')
reports=[]
for flag in (0,1):
    prefix=f'physical_{flag}'
    flow=f'''read_verilog -lib +/anlogic/cells_sim.v +/anlogic/eagle_bb.v out/mjpeg_d3/physical_prims.v;
read_verilog -sv src/5640/sdram_ctrl_4p/command.v src/5640/sdram_ctrl_4p/control_interface.v src/5640/sdram_ctrl_4p/sdr_data_path.v src/5640/sdram_ctrl_4p/sdram_ip.v out/mjpeg_d3/controller_proxy.v src/user_source/hdl_source/yingxu_sdram_framebuffer.v src/user_source/hdl_source/media/mjpeg/yingxu_sdram_burst_port.v;
hierarchy -check -top yingxu_sdram_framebuffer -chparam ENABLE_MJPEG {flag};
proc; flatten; tribuf -logic; opt; wreduce; opt; memory_dff; memory_share; memory_collect; opt_clean;
synth_anlogic -top yingxu_sdram_framebuffer -run map_ram:map_luts;
abc -lut 4; clean;
synth_anlogic -top yingxu_sdram_framebuffer -run map_cells:edif;
write_json out/mjpeg_d3/{prefix}.json
'''
    with (out/(prefix+'.log')).open('w')as f:rc=subprocess.call([binary,'-Q','-T','-p',flow],cwd=r,env=env,stdout=f,stderr=subprocess.STDOUT)
    if rc:raise SystemExit((out/(prefix+'.log')).read_text()[-6000:])
    net=json.loads((out/(prefix+'.json')).read_text())['modules']['yingxu_sdram_framebuffer']['cells'];c={k:sum(x['type']==k for x in net.values())for k in {x['type']for x in net.values()}}
    reports.append({'ENABLE_MJPEG':flag,'cells':c,'LUT4_charge':sum(c.get('AL_MAP_LUT'+str(i),0)for i in range(1,5))+c.get('AL_MAP_ADDER',0)+4*c.get('EG_LOGIC_DRAM16X4',0)})
result={'TD_measured':False,'model':'same four-port+framebuffer both configurations; vendor PLL/FIFO/SDRAM macros black boxes','configurations':reports,'physical_LUT_delta':reports[1]['LUT4_charge']-reports[0]['LUT4_charge']}
(out/'physical_delta.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
