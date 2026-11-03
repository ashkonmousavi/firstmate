import os, sys, json, subprocess, pathlib, shutil, tempfile, shlex, time
R=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M6HNY28AVVTZX3TN7BH3NRPH')
BASE=dict(os.environ)
for k in list(BASE):
    if k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_', 'REX_')) or k in ('TMUX', 'CLAUDE_PROJECT_DIR'): BASE.pop(k,None)
BASE.update(TMPDIR=str(R/'.nm-test/tmp'),PYTHONDONTWRITEBYTECODE='1')
RESULT=json.loads((E/'live-results.json').read_text()) if len(sys.argv)>1 else []

def home(label):
    h=pathlib.Path(tempfile.mkdtemp(prefix=label+'-',dir=R/'.nm-test'))
    for d in ('state','data','config','projects'): (h/d).mkdir()
    return h

def env(h):
    return dict(BASE,FM_HOME=str(h),FM_ROOT_OVERRIDE=str(h),FM_BACKEND='tmux',TMUX=str(h/'isolated.sock')+',0,0')

def write(h,p,s):
    f=h/p; f.parent.mkdir(parents=True,exist_ok=True); f.write_text(s); return f

def run(log,cmd,en,expected=0,input=None):
    log.write('$ '+shlex.join(map(str,cmd))+'\n'); log.flush()
    p=subprocess.run(list(map(str,cmd)),env=en,input=input,text=True,capture_output=True,timeout=35)
    log.write(p.stdout+p.stderr+f'\n[exit={p.returncode}]\n'); log.flush()
    assert p.returncode==expected,(cmd,p.returncode,p.stderr)
    return p.stdout

def scenario(name,fn):
    try:
        with (E/(name+'.log')).open('w') as log: fn(log)
        RESULT[:]=[r for r in RESULT if r['name']!=name]
        RESULT.append(dict(name=name,result='pass'))
    except Exception as ex:
        RESULT.append(dict(name=name,result='fail',error=repr(ex)))
    (E/'live-results.json').write_text(json.dumps(RESULT,indent=2)+'\n')
    print(RESULT[-1],flush=True)

def owl(log):
    h=home('owl'); en=env(h)
    records={'valid':'owner 2026-11-03\n','invalid':'not owner\n','bad-date':'owner 2026-02-30\n','extra':'owner 2026-11-03\nextra\n','empty':''}
    originals={}
    for task,record in records.items():
        originals[task]=write(h,f'state/{task}.status',f'needs-decision [key=choice]: {task} decision remains open\n').read_bytes()
        write(h,f'config/secondmate-parked/{task}',record)
    originals['symlink']=write(h,'state/symlink.status','needs-decision [key=choice]: symlink decision remains open\n').read_bytes()
    (h/'config/secondmate-parked/symlink').symlink_to(h/'config/secondmate-parked/valid')
    for n in range(2):
        out=run(log,['bash',R/'bin/fm-wake-drain.sh'],en)
        section=out.split('OPEN DECISIONS',1)[1]
        assert not any(line.startswith('valid [key=choice]') for line in section.splitlines())
        for task in ('invalid','bad-date','extra','empty','symlink'): assert task+' [key=choice]' in section,(task,out)
    for task,raw in originals.items(): assert (h/f'state/{task}.status').read_bytes()==raw
    log.write('Durable decisions unchanged after repeated filtering.\n')
    (h/'config/secondmate-parked/valid').unlink()
    out=run(log,['bash',R/'bin/fm-wake-drain.sh'],en)
    assert any(line.startswith('valid [key=choice]') for line in out.split('OPEN DECISIONS',1)[1].splitlines())
    write(h,'config/secondmate-parked/valid','owner 2026-11-03\n')
    out=run(log,['bash',R/'bin/fm-wake-drain.sh'],dict(en,FM_CONFIG_OVERRIDE=''))
    assert any(line.startswith('valid [key=choice]') for line in out.split('OPEN DECISIONS',1)[1].splitlines())
    log.write('Unpark and empty config override both leave the decision visible.\n')


def persona(log):
    h=home('persona'); en=env(h)
    write(h,'.tasks.toml','backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n')
    write(h,'data/backlog.md','## In flight\n## Queued\n- [ ] candidate - inspect prep (repo: NOT_Q) (kind: ship)\n## Done\n')
    (h/'projects/NOT_Q').mkdir()
    write(h,'data/candidate/brief.md','Task: change labels.\n')
    write(h,'data/candidate/autolaunch-prep','project=NOT_Q\nkind=ship\nmode=direct-PR\nyolo=off\n')
    good='PERSONA: researcher; surfaces=pages,chat; usage=beginner,experienced; same outcome.\nDOCTOR: no Doctor change; because only labels change.\nXAI-SURFACE: none; because only labels change.\n'
    cases=[('complete endpoints',good,True),('middle missing endpoints',good.replace('beginner,experienced','middle'),False),('missing Doctor',good.replace('DOCTOR: no Doctor change; because only labels change.\n',''),False),('reasonless Doctor',good.replace('no Doctor change; because only labels change.','no Doctor change'),False),('reasonless surface',good.replace('none; because only labels change.','none'),False),('surface suffix',good.replace('pages,chat','pages/chat'),False),('usage suffix',good.replace('beginner,experienced','beginner/experienced'),False),('single-page experienced',good.replace('pages,chat','pages').replace('beginner,experienced','experienced'),True),('single-chat beginner',good.replace('pages,chat','chat').replace('beginner,experienced','beginner'),True)]
    for label,text,admitted in cases:
        log.write('\nCASE '+label+'\n'+text)
        f=write(h,'data/candidate/prep.md',text); os.utime(f,(1793692800,1793692800))
        out=run(log,['bash',R/'bin/fm-autolaunch.sh','--list-prepared'],en)
        assert ('candidate' in out)==admitted,(label,out)
    f=write(h,'data/candidate/prep.md','old prep\n'); os.utime(f,(1793692799,1793692799))
    log.write('\nCASE legacy prep before fixed cutoff\n')
    assert 'candidate' in run(log,['bash',R/'bin/fm-autolaunch.sh','--list-prepared'],en)
    os.utime(f,(1793692800,1793692800))
    log.write('\nCASE legacy revised at cutoff\n')
    assert 'candidate' not in run(log,['bash',R/'bin/fm-autolaunch.sh','--list-prepared'],en)


def reply(log):
    h=home('reply'); en=env(h)
    write(h,'AGENTS.md','isolated primary\n'); (h/'bin').symlink_to(R/'bin',target_is_directory=True)
    # The registered hook uses git primary scope; initialize only this disposable home.
    run(log,['git','init','-q',h],en)
    en['CLAUDE_PROJECT_DIR']=str(h)
    transcript=write(h,'transcript.jsonl',json.dumps({'type':'user','message':{'role':'user','content':'Report.'}})+'\n')
    command=['bash',R/'bin/fm-turnend-guard.sh','--claude','--state-claims']
    def check(label,text,expected,active=False):
        log.write('\nCASE '+label+'\nMESSAGE '+text+'\n')
        payload=dict(hook_event_name='Stop',session_id='manual-reply',stop_hook_active=active,transcript_path=str(transcript),last_assistant_message=text)
        start=time.perf_counter(); run(log,command,en,expected,json.dumps(payload)); elapsed=(time.perf_counter()-start)*1000
        log.write(f'Elapsed {elapsed:.1f} ms\n'); assert elapsed<200,(label,elapsed)
    check('optional policy absent','Please choose A or B.',0)
    write(h,'config/reply-shape','ask-first\npacific-times\npr-urls\n')
    late='Report ready.\n👉 **Choose** A) proceed or B) wait?'
    check('late marked ask refuses',late,2)
    check('identical continuation allowed once',late,0,True)
    check('no unlimited continuation exemption',late,2,True)
    check('first-line marked bold options','👉 **Choose** A) proceed or B) wait?\nReport ready.',0)
    check('lexical limit plain late question','Report ready.\nAny objections?',0)
    check('phrase-list request refuses','Report ready.\nCan you approve this?',2)
    check('UTC clock refuses','Meet at six pm UTC.',2)
    check('Pacific clock accepted','Meet at 10:00 PT.',0)
    check('named PR without HTTPS link','PR 9 needs review.',2)
    check('matching HTTPS PR link','PR 9 needs review. https://example.test/repo/pull/9',0)
    check('unrelated link cannot cover reference','MR !9 needs review. https://example.test/repo/-/merge_requests/10',2)
    check('specific URL disclosure','MR !9: URL unavailable in ready metadata.',0)
    check('disclosure cannot leak to other reference','PR 9 needs review; PR 10: URL unavailable. https://example.test/repo/pull/10',2)
    check('quoted evidence excluded','The log says “Meet at six pm UTC. PR 9 needs review.”',0)
    check('current prose after quoted record still checked','The log says “Meet at six pm UTC.” Meet at 18:00 UTC.',2)


def timer(log):
    h=home('timer home%z'); en=env(h)
    write(h,'.tasks.toml','backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    write(h,'data/backlog.md','## In flight\n- [ ] timer-owner - held (kind: ship) (hold: parked: fixture) (hold-kind: external) (hold-until: 2099-01-01)\n## Queued\n## Done\n')
    write(h,'config/autolaunch-steps','act timer-owner\n')
    tools=h/'tool space%z'; tools.mkdir()
    for name in ('bash','sh','python3','tasks-axi','node'):
        executable=shutil.which(name); assert executable,name; (tools/name).symlink_to(executable)
    en['PATH']=str(tools)+':/usr/bin:/bin'; en['HOME']=str(h)
    for flags in ([],['--steps-only']):
        recipe=run(log,['bash',R/'bin/fm-autolaunch.sh','--print-timer',*flags],en)
        assert list((h/'state').iterdir())==[]
        emitted=dict(BASE,HOME=str(h),PATH='/usr/bin:/bin')
        for line in recipe.splitlines():
            if line.startswith('Environment='):
                key,value=shlex.split(line.partition('=')[2])[0].split('=',1); emitted[key]=value.replace('%%','%')
            if line.startswith('ExecStart='): cmd=shlex.split(line.partition('=')[2].replace('%%','%'))
        assert emitted['FM_HOME']==str(h) and emitted['PATH']==en['PATH']
        assert cmd==[str(R/'bin/fm-autolaunch.sh'),*flags]
        if flags:
            run(log,cmd,emitted)
            stamp=h/'state/autolaunch-steps.pass'; log.write(stamp.read_text()+'\n'); assert json.loads(stamp.read_text())['owners']==['timer-owner']; stamp.unlink()
        else: run(log,['bash',R/'bin/fm-tasks-axi.sh','show','timer-owner','--full'],emitted)
        cron=next(line.split(' ',5)[5] for line in recipe.splitlines() if line.startswith('*/5 '))
        cron=cron.removesuffix(' >/dev/null 2>&1').replace(r'\%','%')
        if flags:
            run(log,['sh','-c',cron],dict(BASE,HOME=str(h),PATH='/usr/bin:/bin'))
            stamp=h/'state/autolaunch-steps.pass'; assert json.loads(stamp.read_text())['owners']==['timer-owner']; stamp.unlink()
    for flags in (['--dry-run'],['--steps-only','--dry-run']): run(log,['bash',R/'bin/fm-autolaunch.sh','--print-timer',*flags],en,2)
    (tools/'tasks-axi').unlink()
    run(log,cmd,emitted,1)
    assert not (h/'state/autolaunch-steps.pass').exists()


def c4(log):
    h=home('c4'); en=env(h)
    write(h,'.tasks.toml','backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    write(h,'data/backlog.md','## In flight\n- [ ] owner - slice (repo: proj) (kind: ship)\n  SLICE: id=demo role=owner\n  TESTER TASK: special-tester\n  TESTER RULE: new\n  TESTER PATHS: tests/risk.py\n- [ ] special-tester - tester (repo: proj) (kind: scout)\n  SLICE: id=demo role=tester owner=main:owner\n## Queued\n## Done\n')
    write(h,'config/autolaunch-steps','act owner\n')
    write(h,'config/crew-dispatch.json','{"shared_quota":true,"default":[{"harness":"codex","model":"gpt-5.5"},{"harness":"claude","model":"opus"}]}')
    write(h,'data/owner/brief.md','Delivery contract: mode=direct-PR\nShip branch: fm/owner\n')
    write(h,'data/owner/autolaunch-prep','project=proj\nkind=ship\nmode=direct-PR\nyolo=off\n')
    write(h,'data/owner/prep.md','REVISION: r1\nCUT: 1\nWALK ID: demo\nWALK LIST: screen-a,screen-b\nTESTER RULE: new\nTESTER PATHS: tests/risk.py\n')
    for task,model,harness in [('owner','gpt-5.5','codex'),('special-tester','opus','claude')]:
        write(h,f'state/{task}.meta',f'kind=ship\nharness={harness}\nmodel={model}\nspawn_gen=s1.1.1\nmode=direct-PR\nbranch=fm/owner\nworktree={h}/projects/proj\nproject={h}/projects/proj\n')
    for cut in (False,True):
        for form,accepted in [('commit=none',True),('none',True),('commit=abcdef1',True),('commit=none-extra',False),('none-extra',False),('commit=abcdefg',False)]:
            key='cut:owner@1:r1:tester' if cut else 'prep:r1'
            write(h,'data/owner/slice-steps.log',json.dumps(dict(at=1,generation=1,step='tests',owner='owner',trigger=key,receipt='completed',revision='r1',tester='special-tester'))+'\n')
            write(h,'state/owner.status','working [at=2]: cut ready data/owner/prep.md r1 walk_changed=yes risk_changed=no\n' if cut else '')
            receipt=f'done [at=3]: tests-ready {form} revision=r1 walk-list=screen-a,screen-b checks=existing\n'
            write(h,'state/special-tester.status',receipt)
            log.write(f'\nCASE cut={cut} {receipt}')
            out=run(log,['bash',R/'bin/fm-autolaunch.sh','--steps-only','--dry-run'],en)
            trigger='cut:owner@1:r1' if cut else 'tests-ready:'
            assert (trigger in out)==accepted,(cut,form,out)
    write(h,'data/owner/slice-steps.log',json.dumps(dict(at=1,generation=1,step='tests',owner='owner',trigger='prep:r1',receipt='completed',revision='r1',tester='special-tester'))+'\n')
    write(h,'state/owner.status','')
    good='done [at=3]: tests-ready commit=none revision=r1 walk-list=screen-a,screen-b checks=existing\n'
    for label,receipt in [('stale revision',good.replace('revision=r1','revision=r0')),('incomplete walk',good.replace('screen-a,screen-b','screen-a')),('missing checks',good.replace(' checks=existing',''))]:
        log.write('\nCASE '+label+'\n'); write(h,'state/special-tester.status',receipt)
        assert not run(log,['bash',R/'bin/fm-autolaunch.sh','--steps-only','--dry-run'],en).strip()
    write(h,'state/special-tester.status',good)
    meta=(h/'state/special-tester.meta').read_text()
    for model in ('gpt-5.5','default',''):
        write(h,'state/special-tester.meta',meta.replace('model=opus','model='+model))
        log.write('\nCASE unadmitted tester model '+repr(model)+'\n')
        assert not run(log,['bash',R/'bin/fm-autolaunch.sh','--steps-only','--dry-run'],en).strip()
    log.write('Dry-run proposals use the real step engine, task store, model admission and backend lookup. No agent delivery is claimed here.\n')

(R/'.nm-test/tmp').mkdir(parents=True,exist_ok=True)
for name,fn in [('live-owl',owl),('live-persona',persona),('live-reply',reply),('live-timer',timer),('live-c4-preview',c4)]:
    if len(sys.argv)==1 or name in sys.argv[1:]: scenario(name,fn)
sys.exit(any(x['result']=='fail' for x in RESULT))
