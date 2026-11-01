#!/usr/bin/env python3
"""Prepare a TD project bound to this checkout and record its exact sources.

Does not invoke TD or generate a bitstream. Run in the Windows checkout used
for the unified build; the tracked project is left untouched.
"""
from pathlib import Path
import hashlib,json,re,subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/unified'
PROJECT='AC201_AL_board_test.al'

def git(*args):
    return subprocess.check_output(['git',*args],cwd=ROOT,text=True).strip()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def tcl_quote(value):
    for old,new in [('\\','\\\\'),('"','\\"'),('$','\\$'),('[','\\['),(']','\\]'),('\n','\\n'),('\r','\\r')]:
        value=value.replace(old,new)
    return '"'+value+'"'

def main():
    original=ROOT/PROJECT
    raw=original.read_bytes()
    root_name=ROOT.as_posix()
    if any(c in root_name for c in ('"','\n','\r')):
        raise SystemExit('Checkout path cannot be represented by the TD project format')
    paths=re.findall(r'<File Path="([^"]+)"',raw.decode('utf-8'))
    if not paths:
        raise SystemExit('No registered TD inputs found')
    files={}
    for name in paths:
        path=(ROOT/name.replace('\\','/')).resolve()
        if not path.is_relative_to(ROOT) or not path.is_file():
            raise SystemExit(f'Missing or external project input: {name}')
        files[path.relative_to(ROOT).as_posix()]=digest(path)
    # Include checked-in HDL/IP dependencies even when reached via includes.
    for name in git('ls-files','--','src','al_ip').splitlines():
        path=ROOT/name
        if path.is_file():
            if not path.resolve().is_relative_to(ROOT):
                raise SystemExit(f'External HDL/IP dependency: {name}')
            files[name]=digest(path)
    prepared,count=re.subn(rb'(<Project\b[^>\r\n]*\bPath=")[^"]*(")',
        lambda m:m[1]+root_name.encode('utf-8')+m[2],raw,count=1)
    if count!=1:
        raise SystemExit('Expected one Project Path field')
    OUT.mkdir(parents=True,exist_ok=True)
    target=OUT/PROJECT
    target.write_bytes(prepared)
    opening=['import_device eagle_s20.db -package EG4S20BG256',
             'open_project '+tcl_quote(target.as_posix()),'set_seed_param -disable']
    full=opening+['reset_runs phy_1','reset_runs syn_1',
        'launch_runs syn_1 phy_1 -jobs 2','wait_run syn_1 -quiet','wait_run phy_1 -quiet','save_best_bits','exit']
    phy=opening+['reset_runs phy_1','launch_runs phy_1 -jobs 1','wait_run phy_1 -quiet','save_best_bits','exit']
    (OUT/'build_full.tcl').write_text('\n'.join(full)+'\n',encoding='utf-8')
    (OUT/'build_phy_only.tcl').write_text('\n'.join(phy)+'\n',encoding='utf-8')
    manifest={'git_head':git('rev-parse','HEAD'),'branch':git('branch','--show-current'),
        'working_tree_status':git('status','--porcelain=v1').splitlines(),
        'checkout_root':root_name,'tracked_project':PROJECT,
        'tracked_project_sha256':digest(original),'prepared_project':target.relative_to(ROOT).as_posix(),
        'prepared_project_sha256':digest(target),'registered_inputs':len(paths),
        'source_sha256':dict(sorted(files.items())),
        'expected_bit':(ROOT/'AC201_AL_board_test_Runs/best_result/AC201_AL_board_test.bit').as_posix(),
        'td_executed':False,'bitstream_generated':False}
    (OUT/'source_manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    assert re.search(rb'<Project\b[^>]*\bPath="([^"]+)"',target.read_bytes())[1].decode()==root_name
    assert original.read_bytes()==raw
    print(f'Prepared {target}')
    print(f'Checked {len(paths)} registered inputs; source manifest: {OUT/"source_manifest.json"}')
    print('TD was not executed; no bitstream was generated.')

if __name__=='__main__':
    main()

