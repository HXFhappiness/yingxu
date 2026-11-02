#!/usr/bin/env python3
"""Verify ownership and real 100ms key timing on the extracted production FSM."""
from pathlib import Path
import os,re,shutil,subprocess
R=Path(__file__).resolve().parents[1];O=R/'out/d10/menu_keys'

def main():
    O.mkdir(parents=True,exist_ok=True)
    source=(R/'hardware_test_P0_UART_V5_CRC32.v').read_text()
    reset=source.index('            menu_override <= (BOOT_MENU != 0);')
    start=source.rfind('    always @(posedge clk or negedge rst_n) begin',0,reset)
    body=source[start:source.index('    always @(*) begin',reset)]
    params='\n'.join(line for line in source.splitlines()if re.match(r'\s*localparam.*(?:MENU_PAT_|KEY_LOCK_CYCLES|CAROUSEL_MAX)',line))
    ui=next(line.strip().replace('wire menu_ui =','assign menu_ui =',1)for line in source.splitlines()if line.strip().startswith('wire menu_ui ='))
    shell='''`default_nettype none
module menu_key_fsm #(parameter integer BOOT_MENU=1,parameter integer IMG_COUNT=9)(
 input wire clk,rst_n,key_0,key_1,menu_return,game_mode,video_requested,video_owned,sd_dbg_busy,
 input wire[7:0]sw_eff,output reg menu_override,menu_page,output reg[7:0]menu_pattern,
 output reg[2:0]menu_sel,output reg[3:0]img_idx,output reg img_restart,
 output reg[23:0]key_lock,output wire menu_ui);
 reg menu_return_page;reg[2:0]menu_return_sel;reg key0_p,key1_p,sw6_p;
 reg[1:0]sw6_sync;reg[27:0]carousel_cnt;
'''+params+'\n'+ui+'\n'+body+'endmodule\n`default_nettype wire\n'
    generated=O/'production_menu_keys.v';generated.write_text(shell)
    formal=O/'ownership.v';formal.write_text('''module menu_ownership_formal #(parameter integer BOOT_MENU=1)(
 input wire clk,rst_n,key_0,key_1,menu_return,game_mode,video_requested,video_owned,sd_dbg_busy,
 input wire[7:0]sw_eff,output wire safe);
 wire owner;reg acquired;
 menu_key_fsm #(.BOOT_MENU(BOOT_MENU)) dut(.clk(clk),.rst_n(rst_n),.key_0(key_0),.key_1(key_1),
 .menu_return(menu_return),.game_mode(game_mode),.video_requested(video_requested),.video_owned(video_owned),
 .sd_dbg_busy(sd_dbg_busy),.sw_eff(sw_eff),.menu_override(owner));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)acquired<=0;else if(owner)acquired<=1;
 end
 assign safe=!rst_n || !acquired || owner;
endmodule
''')
    yosys=shutil.which('yosys')or '/workspace/.yingxu-env/yosys/usr/bin/yosys'
    for boot in (0,1):
        script=f'read_verilog {generated} {formal}; chparam -set BOOT_MENU {boot} menu_ownership_formal; prep -top menu_ownership_formal -flatten; async2sync; opt; sat -seq 4 -tempinduct -maxsteps 12 -set-init-zero -set rst_n 1 -set-at 1 rst_n 0 -prove safe 1 -verify'
        log=O/f'ownership_boot{boot}.log'
        with log.open('w')as f:subprocess.run([yosys,'-Q','-T','-p',script],cwd=R,stdout=f,stderr=subprocess.STDOUT,check=True)
        assert 'Induction step proven: SUCCESS!'in log.read_text()
        print(f'MENU_OWNER_FORMAL PASS BOOT_MENU={boot}: once acquired, ownership persists for arbitrary keys, switches and mode/return inputs',flush=True)
    v=shutil.which('verilator')or '/workspace/.yingxu-env/verilator/usr/bin/verilator';env=os.environ.copy()
    if '.yingxu-env' in v:env['VERILATOR_ROOT']='/workspace/.yingxu-env/verilator/usr/share/verilator'
    build=O/'vkeys'
    for cmd,log in [([v,'--binary','--timing','-j','4','-Wno-fatal','--top-module','tb_menu_key_lock','--Mdir',build,generated,R/'tb/tb_menu_key_lock.v'],'key_build.log'),([build/'Vtb_menu_key_lock'],'key_timing.log')]:
        with(O/log).open('w')as f:subprocess.run([str(x)for x in cmd],cwd=R,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
    print((O/'key_timing.log').read_text(),end='')
if __name__=='__main__':main()
