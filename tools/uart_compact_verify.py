#!/usr/bin/env python3
"""Prove byte-format equality and compare real UART wires against D10."""
from pathlib import Path
import os,re,shutil,subprocess
R=Path(__file__).resolve().parents[1];O=R/'out/d11/uart'

def main():
    O.mkdir(parents=True,exist_ok=True)
    old=subprocess.check_output(['git','show','4a26c65:src/user_source/hdl_source/yx8_uart_telem.v'],cwd=R,text=True)
    new=(R/'src/user_source/hdl_source/yx8_uart_telem.v').read_text()
    (O/'reference.v').write_text(old.replace('module yx8_uart_telem (','module yx8_uart_telem_ref (',1))
    header=old[:old.index('    localparam')]
    names=re.findall(r'\bi_\w+\b',header);assert len(names)==len(set(names))
    # Compare all 512 character addresses and arbitrary data/counter values.
    probe=header.replace('module yx8_uart_telem (','module NAME (',1).replace('    output wire        o_tx','    input wire [8:0] probe_pos,\n    input wire [15:0] test_sst,test_snx,test_sdn,\n    output wire [7:0] probe_char')
    counters='    wire [15:0] c_sst=test_sst,c_snx=test_snx,c_sdn=test_sdn;\n'
    for label,s in [('reference_format',old),('compact_format',new)]:
        pads=s[s.index('    wire [3:0] pad_seen'):s.index('    function [7:0] hx;')]
        funcs=s[s.index('    function [7:0] hx;'):s.index('    reg [24:0] tick;')]
        if label=='reference_format':tail='    assign probe_char=char_at(probe_pos);\n'
        else:
            rom=s[s.index('    (* ram_style='):s.index('    assign o_tx')]
            rom=re.sub(r'    always @\(posedge i_clk\) format_token<=format_rom\[pos\+9\'d1\];\n','',rom)
            tail=rom+"    wire [7:0] token=format_rom[probe_pos];\n    assign probe_char=token[7] ? hx(nibble_at(token[6:0])):token;\n"
        (O/(label+'.v')).write_text(probe.replace('NAME',label)+counters+pads+funcs+tail+'endmodule\n')
    extra=['probe_pos','test_sst','test_snx','test_sdn'];conns=','.join(f'.{n}({n})'for n in names+extra)
    top=probe.replace('NAME','uart_format_equiv').replace('output wire [7:0] probe_char','output wire safe')
    (O/'equiv.v').write_text(top+f'wire[7:0] a,b; reference_format a0({conns},.probe_char(a));compact_format b0({conns},.probe_char(b));assign safe=a==b;endmodule\n')
    y=shutil.which('yosys')or '/workspace/.yingxu-env/yosys/usr/bin/yosys'
    script=f'read_verilog {O}/reference_format.v {O}/compact_format.v {O}/equiv.v; prep -top uart_format_equiv -flatten; memory_map; opt; sat -prove safe 1 -verify'
    with(O/'format_equiv.log').open('w')as f:subprocess.run([y,'-Q','-T','-p',script],cwd=R,stdout=f,stderr=subprocess.STDOUT,check=True)
    print('UART_FORMAT_PROOF PASS all 512 positions and arbitrary input/counter values',flush=True)
    # Instantiate the complete old/new transmitters at actual 50MHz/115200.
    # Drive every data port through changing bits, not a constant report.
    signals=[];wires=[];offset=0
    for line in header.splitlines():
        if not line.strip().startswith('input'):continue
        width=re.search(r'\[(\d+):(\d+)\]',line);width=(int(width[1])-int(width[2])+1)if width else 1
        for name in re.findall(r'\bi_\w+\b',line):
            if name in ('i_clk','i_rst_n'):signals.append(f'.{name}('+('clk)'if name=='i_clk'else 'rst_n)'));continue
            wires.append(f'wire[{width-1}:0] {name}=stim[{offset+width-1}:{offset}];');signals.append(f'.{name}({name})');offset+=width
    tb='''`timescale 1ns/1ps
module tb_uart_compact;
reg clk=0;always #10 clk=~clk;
reg rst_n=0;reg[1023:0]stim=1024'h123456789abcdef;
wire tx,ref_tx;integer frames=0,chars=0,b,k,fd;reg[7:0]byte_value;
always @(negedge clk)if(rst_n)begin
 stim<={stim[1022:0],stim[1023]^stim[1008]^stim[1007]^stim[1002]};
 if(tx!==ref_tx)$fatal(1,"UART wire mismatch at char %0d",chars);
end
'''+ '\n'.join(wires)+'\n'+f'yx8_uart_telem dut({",".join(signals)},.o_tx(tx));\nyx8_uart_telem_ref reference({",".join(signals)},.o_tx(ref_tx));\n'+'''
initial begin
 repeat(5)@(negedge clk);rst_n=1;
 fd=$fopen("out/d11/uart/wire_reports.txt","w");
 repeat(2)begin
  for(k=0;k<347;k=k+1)begin
   @(negedge tx);#4340;if(tx!==0)$fatal(1,"start bit");
   for(b=0;b<8;b=b+1)begin #8680;byte_value[b]=tx;end
   #8680;if(tx!==1)$fatal(1,"stop bit");
   $fwrite(fd,"%c",byte_value);chars=chars+1;
   if(k==0 && byte_value!="A")$fatal(1,"first literal/prefetch");
  end
  frames=frames+1;
 end
 $fclose(fd);
 if(chars!=694)$fatal(1,"vacuous UART coverage");
 $display("UART_WIRE_EQUIV PASS reports=%0d bytes=%0d actual 50MHz/115200; every TX bit equal under changing inputs",frames,chars);
 $finish;
end
initial begin #500000000;$fatal(1,"UART timeout");end
endmodule
'''
    (O/'tb_uart_compact.v').write_text(tb)
    v=shutil.which('verilator')or '/workspace/.yingxu-env/verilator/usr/bin/verilator';env=os.environ.copy()
    if '.yingxu-env'in v:env['VERILATOR_ROOT']='/workspace/.yingxu-env/verilator/usr/share/verilator'
    for cmd,log in [([v,'--binary','--timing','-j','4','-Wno-fatal','--top-module','tb_uart_compact','--Mdir',O/'vwire',O/'tb_uart_compact.v',O/'reference.v',R/'src/user_source/hdl_source/yx8_uart_telem.v'],'wire_build.log'),([O/'vwire/Vtb_uart_compact'],'wire.log')]:
        with(O/log).open('w')as f:subprocess.run([str(x)for x in cmd],cwd=R,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
    print((O/'wire.log').read_text(),end='')
if __name__=='__main__':main()
