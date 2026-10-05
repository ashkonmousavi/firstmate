import json, os, pathlib, re, shutil, subprocess, tempfile
root=pathlib.Path.cwd(); evidence=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M45A310MS8SHF58HQB9BSH73')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.prep-compatibility-',dir=root)); prep=lab/'prep.md'; results=[]
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') and key.endswith('_OVERRIDE'): env.pop(key,None)
env['FM_HOME']=str(lab)
def check(name,text,expected,reason=None):
    prep.write_text(text)
    p=subprocess.run(['bash','-c','. bin/fm-dod-lib.sh; fm_prep_unfilled_reason "$1"','_',str(prep)],cwd=root,env=env,capture_output=True,text=True)
    result={'case':name,'exit':p.returncode,'reason':p.stdout.strip(),'expected_exit':expected,'expected_reason':reason,'pass':p.returncode==expected and (reason is None or reason in p.stdout)}
    results.append(result)
    assert result['pass'],result
try:
    full=(evidence/'full-answered-prep.md').read_text(); surgical=(evidence/'surgical-answered-prep.md').read_text()
    check('all-no tier-1 complete control',full,1)
    check('Q2 shared-contract tier-1 control',full.replace('- Q2 does this change touch a shared module or a contract: no','- Q2 does this change touch a shared module or a contract: yes'),1)
    section_pattern=r'(?m)^## 2\. Behaviour spec\n[\s\S]*?(?=^## 3\.)'
    no_spec=re.sub(section_pattern,'',full)
    check('tier 1 may omit section 2',no_spec,1)
    check('Q1 yes must carry section 2',no_spec.replace('- Q1 does this change alter what a user sees or can do: no','- Q1 does this change alter what a user sees or can do: yes'),0,'Behaviour spec')
    check('UI wiring yes requires concrete screen evidence',full.replace('- UI wiring: no, operator-facing document admission only.','- UI wiring: yes, Settings control.').replace('- Screen and region: n/a: command and Markdown output only.','- Screen and region: n/a: no screen.'),0,'Screen and region')
    for c in range(1,6):
        for answer in ('no','unsure',''):
            changed=re.sub(r'(?m)^(- C'+str(c)+r'[^\n]*): yes$',lambda m:m[1]+': '+answer,surgical)
            assert changed != surgical
            check('surgical C'+str(c)+' '+repr(answer)+' refused',changed,0,'C'+str(c))
    check('surgical complete certificate control',surgical,1)
    for fmt,text in [('full',full),('surgical',surgical)]:
        for name,row in [('missing outcome',''),('blank outcome cell','| O1 | | local CLI, test owner | saved record |')]:
            changed=re.sub(r'(?m)^\| O1:.*$',row,text)
            check(fmt+' '+name+' refused',changed,0)
finally:
    (evidence/'compatibility-results.json').write_text(json.dumps(results,indent=2)+'\n')
    (evidence/'compatibility-transcript.txt').write_text('\n'.join(f"{r['case']}: raw exit={r['exit']}; reason={r['reason']!r}; expected exit={r['expected_exit']}; result={'PASS' if r['pass'] else 'FAIL'}" for r in results)+'\n')
    shutil.rmtree(lab)
print(f'{len(results)} real gate compatibility outcomes; disposable home removed.')
