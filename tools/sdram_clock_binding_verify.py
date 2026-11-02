#!/usr/bin/env python3
"""Cross-frontend regression for the production controller's generate clock scope."""
from pathlib import Path
import argparse,re,shutil,subprocess
R=Path(__file__).resolve().parents[1];O=R/'out/d10/clock_binding'
H=R/'src/user_source/hdl_source';P=R/'src/5640/sdram_ctrl_4p'

def main():
    p=argparse.ArgumentParser();p.add_argument('--baseline-ref',default='1ef7a52');a=p.parse_args()
    O.mkdir(parents=True,exist_ok=True)
    iv=shutil.which('iverilog') or '/workspace/.yingxu-env/toolchain/usr/bin/iverilog'
    vv=shutil.which('vvp') or '/workspace/.yingxu-env/toolchain/usr/bin/vvp'
    current=H/'yingxu_sdram_control_4port.v'
    baseline=O/'baseline_controller.v';baseline.write_bytes(subprocess.check_output(['git','show',a.baseline_ref+':'+str(current.relative_to(R))],cwd=R))
    deps=[R/'tb/tb_sdram_clock_binding.v',R/'tb/models/d3_sdram_models.v',H/'media/mjpeg/yingxu_sdram_burst_port.v',*[P/(s+'.v')for s in ('command','control_interface','sdr_data_path')]]
    for label,source,shadow in [('baseline',baseline,1),('fixed',current,0)]:
        binary=O/(label+'.vvp')
        args=[iv,*(['-B','/workspace/.yingxu-env/toolchain/usr/lib/x86_64-linux-gnu/ivl']if '.yingxu-env' in iv else []),'-g2012','-gno-io-range-error','-Wall','-s','tb_sdram_clock_binding','-Ptb_sdram_clock_binding.EXPECT_SHADOW='+str(shadow),'-o',binary,*deps,source]
        with(O/(label+'_compile.log')).open('w')as f:subprocess.run([str(x)for x in args],cwd=R,stdout=f,stderr=subprocess.STDOUT,check=True)
        warnings=(O/(label+'_compile.log')).read_text()
        implicit=re.findall(r"implicit definition of wire '([^']+)'",warnings)
        if shadow:assert implicit==['CLK'],implicit
        else:assert not implicit,implicit
        with(O/(label+'.log')).open('w')as f:subprocess.run([vv,str(binary)],cwd=R,stdout=f,stderr=subprocess.STDOUT,check=True)
        print((O/(label+'.log')).read_text(),end='',flush=True)
    print('CLOCK_SCOPECHK PASS baseline creates an undriven generate-local CLK; fixed production RTL uses the PLL output',flush=True)
    # Elaborate the actual project too: fail on every implicit net, including
    # harmless-looking module-level forward references that other readers may
    # resolve differently. The legacy vendor CS_N width warning is permitted.
    sources=[]
    for path in re.findall(r'<File Path="([^\"]+\.v)">',(R/'AC201_AL_board_test.al').read_text()):
        if any(x in path for x in ('Sdram_PLL.v','Sdram_RD_FIFO.v','Sdram_WR_FIFO.v','.enc.v','hdmi_phy_warpper.v','lane_lvds_10_1.v')):continue
        if '/media/sd/'in path and Path(path).name not in ('sd_stream_reader.v','sd_stream_reader_core.v','ram_dual_port_simple.v','yingxu_sd_integration_probe.v'):continue
        sources.append(path)
    sources+=['tb/models/d3_sdram_models.v','tb/models/d3_board_models.v']
    args=[iv,*(['-B','/workspace/.yingxu-env/toolchain/usr/lib/x86_64-linux-gnu/ivl']if '.yingxu-env'in iv else []),'-g2012','-gno-io-range-error','-Wall','-s','hardware_test','-o',O/'top.vvp',*sources]
    with(O/'top_compile.log').open('w')as f:subprocess.run([str(x)for x in args],cwd=R,stdout=f,stderr=subprocess.STDOUT,check=True)
    assert 'implicit definition' not in (O/'top_compile.log').read_text()
    print('IVERILOG_TOP_ELAB PASS actual board top; zero implicit-net warnings')
if __name__=='__main__':main()
