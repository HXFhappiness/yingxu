#!/usr/bin/env python3
"""Reproducible telemetry area proxy, never a TD utilization claim."""
from pathlib import Path
import collections,hashlib,json,os,shutil,subprocess
R=Path(__file__).resolve().parents[1];O=R/'out/d11/area'

def main():
    O.mkdir(parents=True,exist_ok=True)
    baseline=O/'baseline_uart.v';baseline.write_bytes(subprocess.check_output(['git','show','4a26c65:src/user_source/hdl_source/yx8_uart_telem.v'],cwd=R))
    y=shutil.which('yosys')or '/workspace/.yingxu-env/yosys/usr/bin/yosys';env=os.environ.copy();env['PATH']=str(Path(y).parent)+os.pathsep+env.get('PATH','')
    rows=[]
    for label,p in [('baseline',baseline),('compact',R/'src/user_source/hdl_source/yx8_uart_telem.v')]:
        flow=f'read_verilog {p}; synth_anlogic -top yx8_uart_telem; stat; write_json {O}/{label}.json'
        with(O/(label+'.log')).open('w')as f:subprocess.run([y,'-Q','-T','-p',flow],cwd=R,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
        cells=json.loads((O/(label+'.json')).read_text())['modules']['yx8_uart_telem']['cells'];c=collections.Counter(x['type']for x in cells.values())
        raw=sum(c['AL_MAP_LUT'+str(i)]for i in range(1,7))
        charge=sum(c['AL_MAP_LUT'+str(i)]for i in range(1,5))+2*c['AL_MAP_LUT5']+4*c['AL_MAP_LUT6']+c['AL_MAP_ADDER']
        rows.append({'label':label,'LUT_cells':raw,'conservative_LUT4_carry_charge':charge,'BRAM':c['EG_PHY_BRAM'],'cells':dict(sorted(c.items())),'source_sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
    assert rows[1]['LUT_cells']<=400 and rows[1]['BRAM']==1,rows[1]
    assert rows[0]['LUT_cells']-rows[1]['LUT_cells']>=900,rows
    # Inspect initialized mapped ROM data, rather than counting an empty BRAM.
    bram=next(c for c in json.loads((O/'compact.json').read_text())['modules']['yx8_uart_telem']['cells'].values()if c['type']=='EG_PHY_BRAM')
    init={k:v for k,v in bram['parameters'].items()if 'INIT' in k}
    assert init and any('1'in v for v in init.values()),'mapped format ROM has no initialized data'
    projected_uart=round(1298*rows[1]['LUT_cells']/rows[0]['LUT_cells'])
    physical_projection=18537-740-366-1298+projected_uart
    result={'TD_measured':False,'baseline_commit':'4a26c65','method':'same Yosys native Anlogic mapping, all telemetry inputs retained; LUT5/6 are raw cells in the first metric and charged 2/4 in the second',
            'telemetry':rows,'mapped_ROM_initialization_fields':len(init),
            'user_reported_TD':{'D10_syn_LUT':18250,'D10_phy_LUT':18537,'capacity':19600,'old_uart':1298,'hardware_invaders':740,'hardware_breakout':366},
            'calibrated_projection_only':{'uart_LUT':projected_uart,'physical_total_LUT':physical_projection,'percent':physical_projection*100/19600,'excludes_additional_top_music_diagnostic_savings':True},
            'actual_TD_below_85_percent_verified':False,'tile_layer_removed':False}
    (O/'resource_estimate.json').write_text(json.dumps(result,indent=2)+'\n')
    for row in rows:print(f"UART_AREA_PROXY {row['label']}: {row['LUT_cells']} LUT cells, {row['conservative_LUT4_carry_charge']} conservative LUT4/carry charge, {row['BRAM']} BRAM")
    print(f'CALIBRATED_ESTIMATE_ONLY total={physical_projection}/19600 ({physical_projection*100/19600:.2f}%); TD not executed; actual <85% remains a local gate')
if __name__=='__main__':main()
