#!/usr/bin/env python3
"""Actual top control paths; generated valid YXV permits real video release."""
from pathlib import Path
import argparse,os,re,shutil,subprocess
from mjpeg_ref.container import build_container
from mjpeg_ref.vectors import make_jpeg
R=Path(__file__).resolve().parents[1];O=R/'out/unified_menu'
def main():
    global O
    p=argparse.ArgumentParser();p.add_argument('--baseline-ref');a=p.parse_args()
    if a.baseline_ref:O=O/('baseline_'+re.sub(r'[^a-zA-Z0-9_.-]','_',a.baseline_ref))
    O.mkdir(parents=True,exist_ok=True)
    fixture,_=build_container([make_jpeg()],bytes(8000))
    (O/'control.yxv').write_bytes(fixture)
    # Check the exact production DIP filter as a standalone synchronous block.
    text=(subprocess.check_output(['git','show',a.baseline_ref+':hardware_test_P0_UART_V5_CRC32.v'],cwd=R,text=True) if a.baseline_ref else (R/'hardware_test_P0_UART_V5_CRC32.v').read_text())
    if not a.baseline_ref:
        start=text.index('    // Only a stable physical DIP move')
        b=text.index('    wire menu_real_change =',start)
        b=text.index('\n',b)+1
        header='module menu_dip_filter(clk,rst_n,menu_override,sw,menu_real_change,sw_real_q,sw_real_valid);\ninput clk,rst_n,menu_override;input [7:0]sw;output menu_real_change;output [7:0]sw_real_q;output sw_real_valid;reg[7:0]sw_real_q;reg sw_real_valid;\n'
        (O/'dip_filter.v').write_text(header+text[start:b]+'endmodule\n')
        y=shutil.which('yosys') or '/workspace/.yingxu-env/yosys/usr/bin/yosys'
        with (O/'dip_filter_check.log').open('w')as f:
            subprocess.run([y,'-Q','-T','-p',f'read_verilog {O}/dip_filter.v; hierarchy -check -top menu_dip_filter; proc; opt; check -assert; stat'],cwd=R,stdout=f,stderr=subprocess.STDOUT,check=True)
    sources=[]
    for s in re.findall(r'<File Path="([^"]+\.v)">',(R/'AC201_AL_board_test.al').read_text()):
        if any(x in s for x in ('Sdram_PLL.v','Sdram_RD_FIFO.v','Sdram_WR_FIFO.v','.enc.v','hdmi_phy_warpper.v','lane_lvds_10_1.v')):continue
        if '/media/sd/' in s and Path(s).name not in ('sd_stream_reader.v','sd_stream_reader_core.v','ram_dual_port_simple.v','yingxu_sd_integration_probe.v'):continue
        sources.append(s)
    if a.baseline_ref:
        historical=O/'hardware_test_baseline.v';historical.write_text(text)
        sources=[str(historical)if f=='hardware_test_P0_UART_V5_CRC32.v'else f for f in sources]
    sources += [str(p.relative_to(R)) for p in sorted((R/'src/user_source/hdl_source/media/mjpeg').glob('*.v'))]
    sources=list(dict.fromkeys(sources))+['tb/models/d3_sdram_models.v','tb/models/d3_board_models.v','tb/tb_menu_mode_paths.v']
    v=shutil.which('verilator') or '/workspace/.yingxu-env/verilator/usr/bin/verilator'
    env=os.environ.copy()
    if '.yingxu-env' in v:env['VERILATOR_ROOT']='/workspace/.yingxu-env/verilator/usr/share/verilator'
    for cmd,log in [([v,'--binary','--timing','-j','4','-Wno-fatal','--top-module','tb_menu_mode_paths','--Mdir',O/'vpaths',*sources],'build.log'),([O/'vpaths/Vtb_menu_mode_paths',f'+file={O}/control.yxv'],'paths.log')]:
        with (O/log).open('w')as f:rc=subprocess.call([str(x)for x in cmd],cwd=R,env=env,stdout=f,stderr=subprocess.STDOUT)
        if rc:raise SystemExit((O/log).read_text()[-6000:])
    print((O/'paths.log').read_text(),end='')
if __name__=='__main__':main()

