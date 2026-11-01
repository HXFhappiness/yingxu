#!/usr/bin/env python3
"""D4h previous_end CE cone and loader area proxy; not TD or routing timing."""
from pathlib import Path
import json,os,shutil,subprocess
R=Path(__file__).resolve().parents[1];O=R/'out/mjpeg_d4h';P='src/user_source/hdl_source/media/mjpeg/yingxu_yxv_loader.v'
def main():
    O.mkdir(parents=True,exist_ok=True)
    (O/'loader_before.v').write_bytes(subprocess.check_output(['git','show','8eb0151:'+P],cwd=R))
    y=shutil.which('yosys') or '/workspace/.yingxu-env/yosys/usr/bin/yosys';env=os.environ.copy();env['PATH']=str(Path(y).parent)+os.pathsep+env.get('PATH','')
    report={'TD_measured':False,'scope':'loader only; native LUT4/carry charge and CE/data cones, not ns slack','configurations':{}}
    for label,path in [('before',O/'loader_before.v'),('after',R/P)]:
        flow=f'read_verilog -lib +/anlogic/cells_sim.v +/anlogic/eagle_bb.v; read_verilog -sv {path}; hierarchy -check -top yingxu_yxv_loader; proc; opt; wreduce; opt; memory_dff; memory_share; memory_collect; opt_clean; synth_anlogic -top yingxu_yxv_loader -run map_ram:map_luts; abc -lut 4; clean; synth_anlogic -top yingxu_yxv_loader -run map_cells:edif; write_json {O}/{label}_area.json;'
        (O/('area_'+label+'.ys')).write_text(flow)
        with (O/('area_'+label+'.log')).open('w') as f:rc=subprocess.call([y,'-Q','-T','-s',str(O/('area_'+label+'.ys'))],cwd=R,env=env,stdout=f,stderr=subprocess.STDOUT)
        if rc:raise SystemExit((O/('area_'+label+'.log')).read_text()[-6000:])
        print('area_'+label+': PASS',flush=True)
        net=json.loads((O/(label+'_area.json')).read_text())['modules']['yingxu_yxv_loader'];cells=net['cells']
        counts={t:sum(c['type']==t for c in cells.values())for t in sorted({c['type']for c in cells.values()})}
        charge=sum(counts.get('AL_MAP_LUT'+str(i),0)for i in range(1,5))+counts.get('AL_MAP_ADDER',0)+4*counts.get('EG_LOGIC_DRAM16X4',0)
        sources={b for n in ('assembly','sd_byte') for b in net['netnames'][n]['bits'] if isinstance(b,int)}
        target=set(net['netnames']['previous_end']['bits']);bit0=net['netnames']['previous_end']['bits'][0]
        edges={};ce=set();d=set();ce0=set();nff=0;witness=[]
        for name,c in cells.items():
            typ=c['type'];ports=c['connections'];dirs=c['port_directions']
            outs={b for k,v in ports.items() if dirs[k]=='output' for b in v if isinstance(b,int)}
            if 'DFF' in typ.upper() or typ=='AL_MAP_SEQ' or 'BRAM' in typ.upper() or 'DRAM' in typ.upper():
                if ('DFF' in typ.upper() or typ=='AL_MAP_SEQ') and outs & target:
                    nff+=1
                    en={b for k,v in ports.items() if k.lower() in ('ce','en','enable','e') for b in v if isinstance(b,int)}
                    ce.update(en);d.update(b for k,v in ports.items() if k.lower()=='d' for b in v if isinstance(b,int))
                    if bit0 in outs:ce0.update(en);witness.append({'cell':name,'type':typ,'ports':ports})
                continue
            ins={b for k,v in ports.items() if dirs[k]=='input' for b in v if isinstance(b,int)}
            for b in ins:edges.setdefault(b,set()).update(outs)
        reached=set(sources);todo=list(sources)
        while todo:
            for b in edges.get(todo.pop(),()):
                if b not in reached:reached.add(b);todo.append(b)
        assert nff and witness,'previous_end flop/bit0 missing'
        report['configurations'][label]={'LUT4_charge':charge,'FF_cells':sum(v for k,v in counts.items()if k=='AL_MAP_SEQ' or 'DFF' in k.upper()),'BRAM':counts.get('EG_PHY_BRAM',0),'previous_end_flops':nff,'raw_data_reaches_previous_end_CE':bool(reached&ce),'raw_data_reaches_previous_end_bit0_CE':bool(reached&ce0),'raw_data_reaches_previous_end_D':bool(reached&d),'bit0_witness':witness,'word_index_ports_all_zero':all(b=='0'for n in ('debug_word','debug_index')for b in net['netnames'][n]['bits']),'cell_counts':counts}
    b=report['configurations']['before'];a=report['configurations']['after']
    assert not a['raw_data_reaches_previous_end_CE'],'Raw table data still gates previous_end CE'
    assert a['word_index_ports_all_zero'],'D4g snapshot removal regressed'
    report['delta']={k:a[k]-b[k]for k in ('LUT4_charge','FF_cells','BRAM')}
    (O/'ce_structure.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
