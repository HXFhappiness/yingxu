#!/usr/bin/env python3
"""D4f diagnostic register-cone break and native LUT area proxy, NOT TD timing."""
import json,os,shutil,subprocess
from pathlib import Path
R=Path(__file__).resolve().parents[1];O=R/'out/mjpeg_d4f';P='src/user_source/hdl_source/media/mjpeg/yingxu_yxv_loader.v'
def main():
    O.mkdir(parents=True,exist_ok=True)
    (O/'loader_before.v').write_bytes(subprocess.check_output(['git','show','0018a81:'+P],cwd=R))
    y=shutil.which('yosys') or '/workspace/.yingxu-env/yosys/usr/bin/yosys';env=os.environ.copy();env['PATH']=str(Path(y).parent)+os.pathsep+env.get('PATH','')
    def run(flow,name):
        (O/(name+'.ys')).write_text(flow)
        with (O/(name+'.log')).open('w') as f:rc=subprocess.call([y,'-Q','-T','-s',str(O/(name+'.ys'))],cwd=R,env=env,stdout=f,stderr=subprocess.STDOUT)
        if rc:raise SystemExit((O/(name+'.log')).read_text()[-6000:])
        print(name+': PASS',flush=True)
    report={'TD_measured':False,'scope':'loader including diagnostics; native LUT4/carry charge, not board area or timing','configurations':{}}
    for label,path in [('before',O/'loader_before.v'),('after',R/P)]:
        run(f'read_verilog -lib +/anlogic/cells_sim.v +/anlogic/eagle_bb.v; read_verilog -sv {path}; hierarchy -check -top yingxu_yxv_loader; proc; opt; wreduce; opt; memory_dff; memory_share; memory_collect; opt_clean; synth_anlogic -top yingxu_yxv_loader -run map_ram:map_luts; abc -lut 4; clean; synth_anlogic -top yingxu_yxv_loader -run map_cells:edif; write_json {O}/{label}_area.json;','area_'+label)
        net=json.loads((O/(label+'_area.json')).read_text())['modules']['yingxu_yxv_loader'];cells=net['cells']
        counts={t:sum(c['type']==t for c in cells.values()) for t in sorted({c['type'] for c in cells.values()})}
        charge=sum(counts.get('AL_MAP_LUT'+str(i),0)for i in range(1,5))+counts.get('AL_MAP_ADDER',0)+4*counts.get('EG_LOGIC_DRAM16X4',0)
        # Traverse combinational cell edges only. DFF/RAM outputs are timing
        # boundaries. This checks that the original direct assembly-to-final
        # diagnostic cone is broken, not that all new paths meet 10ns in TD.
        assembly=set(net['netnames']['assembly']['bits']);targets=set(sum([net['netnames'][n]['bits'] for n in ('debug_reason','debug_word','debug_index')],[]))
        edges={};sink_inputs=set();ff_types=set()
        for cell in cells.values():
            typ=cell['type'];ports=cell['connections'];dirs=cell['port_directions']
            outs=set(sum([v for k,v in ports.items() if dirs[k]=='output'],[]))
            if ('DFF' in typ.upper() or typ=='AL_MAP_SEQ') or 'BRAM' in typ.upper() or 'DRAM' in typ.upper():
                if 'DFF' in typ.upper() or typ=='AL_MAP_SEQ':
                    ff_types.add(typ)
                    if outs & targets:
                        sink_inputs.update(sum([v for k,v in ports.items() if dirs[k]=='input' and k.lower() not in ('clk','clock','c','rst','reset','sr','s','r')],[]))
                continue
            ins=set(sum([v for k,v in ports.items() if dirs[k]=='input'],[]))
            for bit in ins:edges.setdefault(bit,set()).update(outs)
        reached=set(assembly);todo=list(assembly)
        while todo:
            for bit in edges.get(todo.pop(),()):
                if bit not in reached:reached.add(bit);todo.append(bit)
        assert sink_inputs,'No diagnostic flop inputs found'
        direct=bool(sink_inputs & reached)
        report['configurations'][label]={'LUT4_charge':charge,'BRAM':counts.get('EG_PHY_BRAM',0),'FF_cells':sum(n for t,n in counts.items() if 'DFF' in t.upper() or t=='AL_MAP_SEQ'),'assembly_reaches_final_debug_flop_without_register':direct,'cell_counts':counts}
    b=report['configurations']['before'];f=report['configurations']['after']
    report['delta']={k:f[k]-b[k] for k in ('LUT4_charge','BRAM','FF_cells')}
    assert b['assembly_reaches_final_debug_flop_without_register'] and not f['assembly_reaches_final_debug_flop_without_register'],'Original timing cone not broken'
    (O/'diagnostic_structure.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
