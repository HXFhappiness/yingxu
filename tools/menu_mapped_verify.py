#!/usr/bin/env python3
"""Check font/logo pixels survive generic mapped LUT synthesis (not TD)."""
from pathlib import Path
import hashlib,json,re,shutil,subprocess
R=Path(__file__).resolve().parents[1];H=R/'src/user_source/hdl_source';O=R/'out/d11/menu_mapped'

def main():
    O.mkdir(parents=True,exist_ok=True)
    font=[]
    for block in re.split(r"5'd\d+: begin //",(H/'yingxu_cn_font.v').read_text())[1:]:
        font += [int(v,16)for _,v in re.findall(r"5'd(\d+): bits = 32'h([0-9a-fA-F]+);",block)]
    logo=[]
    for block in re.split(r"8'd\d+: case \(byte_idx\)",(H/'yingxu_logo.v').read_text())[1:]:
        logo += [int(v,16)for _,v in re.findall(r"5'd(\d+): bits = 8'h([0-9a-fA-F]+);",block)]
    assert len(font)==544 and len(logo)==3200
    probes=[];palette=[0x0a1030,0x0b1838,0x0f2040,0x14284c,0x1a3055,0x31415e,0x4a5570,0x6b7280,0x8a9099,0xb0b4b8]
    for glyph in range(17):
        row=next(i for i,v in enumerate(font[glyph*32:glyph*32+32])if v not in (0,0xffffffff))
        bits=font[glyph*32+row]
        page=0 if glyph<10 else 1
        line,column=(glyph//2,glyph%2)if glyph<10 else (0,glyph-10)if glyph<13 else (1,glyph-13)
        for ink in (0,1):
            col=next(i for i in range(32)if ((bits>>(31-i))&1)==ink)
            probes.append({'kind':'glyph','glyph':glyph,'page':page,'x':950+column*32+col,'y':280+line*87+row,'rgb':0 if ink else 0xc8b45a})
    for row in range(160):
        for ink in (0,1):
            cols=[x for x in range(160)if ((logo[row*20+x//8]>>(7-x%8))&1)==ink]
            if not cols:continue
            x=40+cols[0];y=28+row
            probes.append({'kind':'logo','page':0,'x':x,'y':y,'rgb':0xffffff if ink else palette[(x+y)//200]})
    assert any(p['kind']=='logo'and p['rgb']==0xffffff for p in probes)
    sources=[H/n for n in ('yingxu_cn_font.v','yingxu_logo.v','yingxu_menu_ui.v')]
    commands=['read_verilog '+' '.join(str(p)for p in sources),'synth -top yingxu_menu_ui -flatten -lut 4',f'write_json {O}/mapped.json']
    for p in probes:
        commands.append(f"eval -set clk 0 -set rst 0 -set menu_visible 1 -set pixel_active 1 -set sel 0 -set page {p['page']} -set pixel_x {p['x']} -set pixel_y {p['y']} -show menu_rgb")
    y=shutil.which('yosys')or '/workspace/.yingxu-env/yosys/usr/bin/yosys'
    with(O/'mapped_pixels.log').open('w')as f:subprocess.run([y,'-Q','-T','-p','; '.join(commands)],cwd=R,stdout=f,stderr=subprocess.STDOUT,check=True)
    values=re.findall(r"Eval result: \\menu_rgb = 24'([01x]+)", (O/'mapped_pixels.log').read_text())
    assert len(values)==len(probes),(len(values),len(probes))
    for p,v in zip(probes,values):assert 'x'not in v and int(v,2)==p['rgb'],(p,v)
    report={'TD_executed':False,'method':'generic flattened LUT4 netlist evaluated after synthesis','probes':probes,
            'glyphs_checked':17,'logo_rows_checked':160,'font_ones':sum(x.bit_count()for x in font),'logo_ones':sum(x.bit_count()for x in logo),
            'source_sha256':{str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest()for p in sources}}
    (O/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'MAPPED_MENU_PIXELS PASS {len(probes)} post-synthesis probes; all 17 glyphs and 160 logo rows retain ink/background pixels')
if __name__=='__main__':main()
