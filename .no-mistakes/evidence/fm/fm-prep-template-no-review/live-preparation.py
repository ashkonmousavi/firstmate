import os, pathlib, subprocess, tempfile, shutil, re, json, hashlib
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M42JD1EGCXV3KJW39JC23GXS')
LAB=pathlib.Path(tempfile.mkdtemp(prefix='.live-preparation-',dir=ROOT))
env=dict(os.environ)
for k in list(env):
    if (k.startswith('FM_') and (k.endswith('_OVERRIDE') or k in ['FM_GATE_REFUSE_BYPASS','FM_HOME','FM_BACKEND','FM_TEST_SEAM','FM_TASK_ID'])) or k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX']:
        env.pop(k,None)
env.update(FM_HOME=str(LAB),FM_BACKEND='tmux',FM_SPAWN_NO_GUARD='1')
transcript=[]
def run(args,input=None):
    p=subprocess.run(args,cwd=ROOT,env=env,text=True,input=input,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
    transcript.append('$ '+subprocess.list2cmdline(args)+'\n'+p.stdout+'[exit '+str(p.returncode)+']\n')
    return p

def gate(p):
    return run(['bash','-c','. bin/fm-dod-lib.sh; fm_prep_unfilled_reason "$1"','_',str(p)])
def complete(p):
    r=gate(p); assert r.returncode==1 and not r.stdout,(p,r.stdout)
def refused(p,label):
    r=gate(p); assert r.returncode==0 and label in r.stdout,(label,r.stdout)
def section(text,heading,body):
    pattern=r'(?m)^'+re.escape(heading)+r'\n[\s\S]*?(?=^## |\Z)'
    return re.sub(pattern,lambda _:heading+'\n'+body+'\n\n',text)
fields=['Captain rulings','Screen and region','Red-first proof','Fixture arithmetic','Data path reachability','Scope only as asked','Author gate check']
values={'CAPTAIN_RULINGS':'Ruling: omit separate preparation review; source: supplied intent. Exercise isolated preparation admission only.',
'SCREEN_AND_REGION':'n/a: CLI preparation has no product screen.',
'RED_FIRST_PROOF':'Remove Scope only as asked; invoke the public gate and require raw exit 0 naming that field. Capture before restoration.',
'FIXTURE_ARITHMETIC':'n/a: this check does not calculate a result.',
'DATA_PATH_REACHABILITY':'fm-brief --prep writes data/task/prep.md; fm-spawn renders launch-brief.md from that file; compare the emitted acceptance bytes.',
'SCOPE_ONLY_AS_ASKED':'Exercise preparation and generated handoff only; worker execution and fleet rollout are excluded.',
'AUTHOR_GATE_CHECK':'bash -c \'. bin/fm-dod-lib.sh; fm_prep_unfilled_reason "$1"\' _ prep.md; run against final bytes and retain empty output/raw exit 1 in the transcript.',
'OUTCOME':'Marker selection','OBSERVABLE_RESULT':'Only the marker line is selected','WHERE_AND_HOW':"`grep -F '<!-- marker -->' output.html`",'EXPECTED_VALUE':r'\<!-- marker -->',
'INTENT_AND_BOXES':'Verify marker selection and exact preparation handoff in a disposable home.',
'BEHAVIOUR_SPEC':"### Marker check\n    grep -F '<!-- marker -->' output.html",'DEFINITION_OF_DONE':"### Marker check\n\tgrep -F '<!-- marker -->' output.html",'Q1_REASON':'This fixture changes only isolated acceptance output.','Q2_REASON':'No shared module is changed by the fixture.'}
results={}
try:
    assert run(['bash','bin/fm-lab-home.sh','create',str(LAB)]).returncode==0
    proj=LAB/'projects'/'proj';proj.mkdir()
    assert run(['git','-C',str(proj),'init','-q']).returncode==0
    records={}
    for name,q1,q2,surgical in [('all-no','no','no',False),('tier1','no','yes',False),('tier2','yes','no',False),('surgical','no','no',True)]:
        args=['bash','bin/fm-brief.sh',name,'--prep']+(['--surgical'] if surgical else [])
        assert run(args).returncode==0
        prep=LAB/'data'/name/'prep.md'
        fresh=prep.read_text(); (E/('scaffold-'+name+'.md')).write_text(fresh)
        assert gate(prep).returncode==0
        replacements=dict(values,Q1=q1,Q2=q2,UI_WIRING='no, isolated CLI checks only.')
        for i in range(1,6):replacements['C'+str(i)]='yes';replacements['C'+str(i)+'_EVIDENCE']='Public CLI fixture at inspected head; change limited to one private preparation record; no production path is modified.'
        filled=re.sub(r'\{([A-Z0-9_]+)\}',lambda m:replacements.get(m[1],'n/a: no additional behavior applies to this disposable check.'),fresh)
        prep.write_text(filled);complete(prep);records[name]=filled
    results['scaffolds']='Both executable scaffold formats refuse fresh bytes and admit concrete common checks with reasoned conditional n/a.'
    base=records['tier2']; p=LAB/'data'/'tier2'/'prep.md'
    for field in fields:
        for v in ['', '{UNFILLED}', 'TODO', '<reason>', 'n/a: TBD']:
            p.write_text(re.sub(r'(?m)^- '+re.escape(field)+r':.*$',lambda _:'- '+field+': '+v,base));refused(p,field)
        p.write_text(re.sub(r'(?m)^- '+re.escape(field)+r':.*\n','',base));refused(p,field)
        for indent in [' ','    ','\t']:
            p.write_text(re.sub(r'(?m)^- '+re.escape(field)+r':.*$',lambda _:'- '+field+':\n'+indent+'Exercise the isolated marker fixture.',base));complete(p)
    p.write_text(base)
    for h in re.findall(r'(?m)^## [0-9]+\..*$',base):
        p.write_text(re.sub(r'(?m)^'+re.escape(h)+r'\n[\s\S]*?(?=^## |\Z)','',base));refused(p,h)
    row="| Marker selection | Only the marker line is selected | `grep -F '<!-- marker -->' output.html` | \\<!-- marker --> |"
    assert row in base
    for i in range(4):
        cells=['Marker selection','Only the marker line is selected',"`grep -F '<!-- marker -->' output.html`",r'\<!-- marker -->'];cells[i]='{UNFILLED}'
        p.write_text(base.replace(row,'| '+' | '.join(cells)+' |'));refused(p,'Expected outcomes')
    p.write_text(section(base,'## Expected outcomes and how to check each','    | Outcome | Exact observable result | Where and how to check | Expected value |\n    | --- | --- | --- | --- |\n    '+row));refused(p,'Expected outcomes')
    p.write_text(base)
    results['incomplete']='Missing/empty/placeheld common fields, numbered sections, malformed outcome cells and indented example tables produce named refusals; all seven author continuations pass at one-space/four-space/tab indentation.'
    surgery=LAB/'data'/'surgical'/'prep.md'
    for i in range(1,6):
        surgery.write_text(re.sub(r'(?m)^(- C'+str(i)+r' .*): yes$',r'\1: unsure',records['surgical']));refused(surgery,'C'+str(i))
    surgery.write_text(records['surgical'])
    p.write_text(base.replace('## Tier\n','## Tier\n- Server install: yes\n- Reviewed prep: yes\n'));complete(p);p.write_text(base)
    results['certainty']='C1-C5 unsure mutations refuse; valid compact preparation and legacy install/review declarations preserve admission.'
    table='## Expected outcomes and how to check each\n| Outcome | Exact observable result | Where and how to check | Expected value |\n| --- | --- | --- | --- |\n'+row
    expected=table+'\n\n## 2. Behaviour spec\n'+values['BEHAVIOUR_SPEC']+'\n\n## 11. Definition of done\n'+values['DEFINITION_OF_DONE']
    accepted=run(['bash','-c','. bin/fm-dod-lib.sh; fm_prep_accepted_spec "$1"','_',str(p)]).stdout.rstrip('\n')
    assert accepted==expected,(accepted,expected)
    (E/'accepted-specification.md').write_text(accepted+'\n')
    commands=[line.strip() for line in accepted.splitlines() if line.startswith(('    grep','\tgrep'))]
    for command in commands:
        for content,code,output in [('unrelated\n<!-- marker -->\n',0,'<!-- marker -->\n'),('unrelated\n',1,''),('unrelated\n<!-- marker -->\n',0,'<!-- marker -->\n')]:
            (LAB/'output.html').write_text(content)
            r=run(['bash','-c','cd "$1"; '+command,'_',str(LAB)])
            assert (r.returncode,r.stdout)==(code,output)
    results['literal']='The public accepted specification preserves escaped expected values and heading-following space/tab commands exactly; both emitted commands select only the marker, fail with marker absent, and pass after restoration.'
    for name in records:
        for mode in ['no-mistakes','direct-PR','local-only']:
            task=LAB/'data'/name
            brief="# Task\n## Captain's intent\nCheck the marker only.\n\n## Firstmate spec\nKeep the exact marker result.\n\n# Definition of done\nDelivery contract: mode="+mode+'\nShip branch: fm/safety-stop\n'
            (task/'brief.md').write_text(brief)
            r=run(['bash','bin/fm-spawn.sh',name,str(proj),'claude','--mode',mode,'--yolo','off'])
            assert r.returncode!=0 and 'branch mismatch' in r.stdout,r.stdout
            launch=(task/'launch-brief.md').read_text()
            assert 'cannot ship without' not in r.stdout and 'cannot ship before a separate' not in r.stdout
            assert not (task/'prep-review').exists() and not (LAB/'state'/(name+'.meta')).exists()
            assert '`## Expected outcomes and how to check each` as the same explicit acceptance list' in launch
            if mode=='no-mistakes' and name=='tier2':
                start=launch.split('## Accepted specification for --intent (preparation record, not the captain\'s words)\n',1)[1]
                spec,tail=start.split('\n## Captain intent authorized for --intent\n',1)
                assert spec.strip()==expected and tail.strip()=='Check the marker only.'
            (E/('launch-'+name+'-'+mode+'.md')).write_text(launch)
    p.write_text(re.sub(r'(?m)^- Scope only as asked:.*$','- Scope only as asked:',base))
    launch=p.parent/'launch-brief.md';launch.unlink()
    r=run(['bash','bin/fm-spawn.sh','tier2',str(proj),'claude','--mode','local-only','--yolo','off'])
    assert 'Scope only as asked' in r.stdout and not launch.exists();p.write_text(base)
    results['admission']='All four preparation formats render through real spawn in all three modes without review receipts; a deliberate branch mismatch then stops before backend creation. Incomplete preparation stops before rendering.'
    for mode in ['no-mistakes','direct-PR','local-only']:
        id='promotion-'+mode.lower();task=LAB/'data'/id;task.mkdir()
        (task/'prep.md').write_text(base)
        (task/'brief.md').write_text("# Task\n## Captain's intent\nCheck the marker only.\n\n## Firstmate spec\nInvestigate the isolated marker.\n")
        (LAB/'state'/(id+'.meta')).write_text('window=fm-'+id+'\nkind=scout\nworktree='+str(proj)+'\n')
        r=run(['bash','bin/fm-promote.sh',id,'--mode',mode,'--yolo','off']);assert r.returncode==0,r.stdout
        for artifact in ['ship-instructions.md','brief.md']:
            txt=(task/artifact).read_text()
            assert '`## Expected outcomes and how to check each` as the same explicit acceptance list' in txt
            if mode=='no-mistakes':
                spec,tail=txt.split('## Accepted specification for --intent (preparation record, not the captain\'s words)\n',1)[1].split('\n## Captain intent authorized for --intent\n',1)
                assert spec.strip()==expected and tail.strip()=='Check the marker only.'
            (E/(id+'-'+artifact)).write_text(txt)
    results['promotion']='Real promotion publishes both immediate and durable artifacts in every mode; no-mistakes includes exact accepted bytes followed by separate final captain words.'
    nav=LAB/'nav'/'data'/'nav-preps';nav.mkdir(parents=True)
    (LAB/'data'/'secondmates.md').write_text('- nav - navigation (home: '+str(LAB/'nav')+'; scope: wayfinding; projects: firstmate; added 2026-10-03)\n')
    src=nav/'installed.md';src.write_text(base);before=hashlib.sha256(src.read_bytes()).hexdigest()
    r=run(['bash','bin/fm-prep-install.sh','installed']);assert r.returncode==0,r.stdout
    dst=LAB/'data'/'installed'/'prep.md';assert src.read_bytes()==dst.read_bytes()
    transcript.append('source/destination SHA-256: '+before+' (byte-identical)\n')
    src=nav/'invalid-nav.md';src.write_text(re.sub(r'(?m)^- Scope only as asked:.*$','- Scope only as asked:',base));before=src.read_bytes()
    r=run(['bash','bin/fm-prep-install.sh','invalid-nav']);assert r.returncode!=0 and 'no filled nav-prep' in r.stdout
    assert src.read_bytes()==before and not (LAB/'data'/'invalid-nav'/'prep.md').exists()
    results['navigation']='Real nav-prep install copies valid bytes exactly and refuses incomplete input without rewriting source or creating destination.'
    print(json.dumps(results,indent=2))
finally:
    shutil.rmtree(LAB)
    transcript.append('Disposable home removed: '+str(LAB)+'\n')
    (E/'live-preparation-transcript.log').write_text('\n'.join(transcript))
    (E/'live-preparation-results.json').write_text(json.dumps(results,indent=2)+'\n')
