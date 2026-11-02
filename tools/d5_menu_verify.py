#!/usr/bin/env python3
"""D5 actual top/menu regression plus isolated synthesis-reader check (not TD)."""
from pathlib import Path
import os, re, shutil, subprocess
from mjpeg_ref.container import build_container
from mjpeg_ref.vectors import make_jpeg
R=Path(__file__).resolve().parents[1]
O=R/'out/d5_menu'
def main():
    O.mkdir(parents=True,exist_ok=True)
    fixture,_=build_container([make_jpeg()],bytes(8000))
    (O/'smoke.yxv').write_bytes(fixture)
    v=shutil.which('verilator') or '/workspace/.yingxu-env/verilator/usr/bin/verilator'
    y=shutil.which('yosys') or '/workspace/.yingxu-env/yosys/usr/bin/yosys'
    env=os.environ.copy()
    if '.yingxu-env' in v:
        env['VERILATOR_ROOT']='/workspace/.yingxu-env/verilator/usr/share/verilator'
    sources=[]
    for s in re.findall(r'<File Path="([^"]+\.v)">',(R/'AC201_AL_board_test.al').read_text()):
        if any(x in s for x in ('Sdram_PLL.v','Sdram_RD_FIFO.v','Sdram_WR_FIFO.v','.enc.v','hdmi_phy_warpper.v','lane_lvds_10_1.v')):
            continue
        if '/media/sd/' in s and Path(s).name not in ('sd_stream_reader.v','sd_stream_reader_core.v','ram_dual_port_simple.v','yingxu_sd_integration_probe.v'):
            continue
        sources.append(s)
    sources += [str(p.relative_to(R)) for p in sorted((R/'src/user_source/hdl_source/media/mjpeg').glob('*.v'))]
    sources=list(dict.fromkeys(sources))+['tb/models/d3_sdram_models.v','tb/models/d3_board_models.v','tb/tb_d5_menu.v']
    def run(args,log):
        with (O/log).open('w') as f:
            subprocess.run([str(a) for a in args],cwd=R,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
    # Extract the unchanged production process, not a handwritten substitute.
    s=(R/'src/user_source/hdl_source/design_top_wrapper.v').read_text()
    body=s[s.index('    reg menu_ctx_q'):s.index('    wire        menu_spr_we')]
    port='module menu_bar(S_pixel_clk,S_rst_pix,I_menu_ctx,I_menu_sel,I_menu_page,clr_active,bar_we_q,bar_y_q,sel_menu);\ninput S_pixel_clk,S_rst_pix,I_menu_ctx,I_menu_page,clr_active;input [2:0] I_menu_sel;\noutput bar_we_q,sel_menu;output [9:0] bar_y_q;\n'
    (O/'menu_bar.v').write_text(port+body+'endmodule\n')
    run([y,'-Q','-T','-p',f'read_verilog {O}/menu_bar.v; hierarchy -check -top menu_bar; proc; opt; check -assert; stat'],'reader.log')
    run([v,'--binary','--timing','-j','4','-Wno-fatal','--top-module','tb_d5_menu','--Mdir',O/'vmenu',*sources],'build.log')
    run([O/'vmenu/Vtb_d5_menu',f'+file={O}/smoke.yxv'],'menu.log')
    print((O/'menu.log').read_text(),end='')
    print('D5_READERCHK: PASS Yosys read/proc/check on production bar process; TD not executed')
if __name__=='__main__':main()

