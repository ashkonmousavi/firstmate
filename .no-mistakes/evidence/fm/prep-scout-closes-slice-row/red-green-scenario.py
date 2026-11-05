import os, sys, json, subprocess, pathlib, shutil, re, traceback
ROOT = pathlib.Path.cwd()
EVID = pathlib.Path('~/.no-mistakes/evidence/01M6N7VHPCAPP5324ZXXW0YMRS')
SCRATCH = ROOT / '.test-phase-baseline'
SCRATCH.mkdir(exist_ok=False)
(SCRATCH/'tmp').mkdir()
base = os.environ.copy()
for key in list(base):
    if key.startswith(('FM_', 'TASKS_AXI_', 'HERDR_', 'XDG_')) or key in ('TMUX','ZELLIJ','NO_MISTAKES_GATE'):
        base.pop(key, None)
base['TMPDIR'] = str(SCRATCH/'tmp')
base['GIT_CONFIG_NOSYSTEM']='1'
base['GIT_CONFIG_GLOBAL']='/dev/null'
transcript = (EVID/'red-green-cli-transcript.log').open('w')
results=[]

def run(args, home=None, check=True):
    env=base.copy()
    if home:
        env.update(FM_HOME=str(home), HOME=str(home/'user-home'), XDG_CONFIG_HOME=str(home/'user-home/.config'), XDG_CACHE_HOME=str(home/'user-home/.cache'))
    transcript.write('$ '+ ' '.join(map(str,args))+'\n'); transcript.flush()
    p=subprocess.run(list(map(str,args)), cwd=home or ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90)
    transcript.write(p.stdout+p.stderr+f'\n[exit {p.returncode}]\n'); transcript.flush()
    if check and p.returncode: raise AssertionError(f'{args}: exit {p.returncode}\n{p.stdout}{p.stderr}')
    return p

def cli(home,*args): return run(['bash',ROOT/'bin/fm-tasks-axi.sh',*args],home).stdout

def new_home(name):
    h=SCRATCH/name
    run(['bash',ROOT/'bin/fm-lab-home.sh','create',h])
    (h/'user-home').mkdir()
    (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    (h/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    (h/'state/.last-watcher-beat').touch()
    return h

def seed(h, ident, kind='ship', body='', state='queued', meta=True):
    cli(h,'add',ident,'Preparation exercise','--kind',kind,'--repo','phase')
    if body: cli(h,'update',ident,'--body',body)
    if state=='in_flight': cli(h,'start',ident)
    if state=='done': cli(h,'done',ident)
    d=h/'data'/ident; d.mkdir()
    (d/'report.md').write_text('Preparation results and recommendations.\n')
    (d/'prep.md').write_text('Durable prep evidence.\n')
    if meta:
        (h/'state'/f'{ident}.meta').write_text(f'window=fm-lab-validation:fm-{ident}\nendpoint_task_id={ident}\nworktree={h}/absent-worktree\nproject={h}/absent-project\nharness=codex\nkind=scout\nmode=no-mistakes\nyolo=off\nspawn_gen=s1.1.1\ndecisions_reviewed=1\n')
    return d

def shown(h,ident): return cli(h,'show',ident,'--full')
def state_of(text): return re.search(r'^  state: (\S+)',text,re.M).group(1)
def keep_snapshot(h,name): shutil.copyfile(h/'data/backlog.md',EVID/f'{name}-backlog.md')
def scenario(name, fn):
    try:
        fn(); results.append(dict(name=name,result='pass',live=True,evidence='red-green-cli-transcript.log',reason=''))
        print('PASS '+name,flush=True)
    except Exception as exc:
        traceback.print_exc(file=transcript);transcript.flush()
        results.append(dict(name=name,result='fail',live=True,evidence='red-green-cli-transcript.log',reason=str(exc)))
        print('FAIL '+name+': '+str(exc),flush=True)

def completion():
    h=new_home('completion')
    kinds={'ship':('ship',''),'owner':('scout','SLICE: main/example role=owner'),'bold':('scout','**SLICE**: main/example role=owner')}
    for label,(kind,body) in kinds.items():
        for state in ['queued','in_flight','done']:
            for verb in ['done','close','library']:
                ident=f'{label}-{state}-{verb}'
                seed(h,ident,kind,body,state)
                if verb=='library':
                    run(['bash','-c','. "$1/bin/fm-tasks-axi-lib.sh"; . "$1/bin/fm-backlog-transition-lib.sh"; fm_backlog_done "$2/data" "$3" --report "data/$3/report.md"', '_',ROOT,h,ident],h)
                else: cli(h,verb,ident,'--report',f'data/{ident}/report.md')
                out=shown(h,ident)
                assert state_of(out)==state, out
                assert 'scout phase finished' in out and f'data/{ident}/report.md' in out,out
    keep_snapshot(h,'completion')

def ordinary():
    h=new_home('ordinary')
    bodies=['','```text\nSLICE: main/example role=owner\n```','~~~text\n**SLICE**: main/example role=owner\n~~~','SLICE: main/example role=tester\nSLICE: main/example role=owner']
    for i,body in enumerate(bodies):
        for verb in ['done','close']:
            ident=f'ordinary-{i}-{verb}'
            seed(h,ident,'scout',body,'in_flight')
            cli(h,verb,ident,'--report',f'data/{ident}/report.md')
            assert state_of(shown(h,ident))=='done'
    # Ordinary ship acceptance without scout metadata remains native.
    seed(h,'accepted-ship','ship',state='in_flight',meta=False)
    cli(h,'done','accepted-ship','--note','green walk accepted')
    assert state_of(shown(h,'accepted-ship'))=='done'
    keep_snapshot(h,'ordinary')

def json_completion():
    h=new_home('json')
    for state in ['queued','in_flight','done']:
        for verb in ['done','close']:
            ident=f'json-{state}-{verb}'
            seed(h,ident,'scout','**SLICE**: main/example role=owner',state)
            for repeat in range(2):
                response=cli(h,verb,ident,'--report',f'data/{ident}/report.md','--json')
                obj=json.loads(response)
                assert obj['ok'] is True and obj['task']['id']==ident and obj['task']['state']==state,obj
                assert 'scout phase finished' in obj['task']['body'],obj
                assert [{'kind':'report','url':f'data/{ident}/report.md'}]==[{k:l[k] for k in ('kind','url')} for l in obj['task']['links'] if l['kind']=='report'],obj
                (EVID/f'{ident}-result.json').write_text(response)
    keep_snapshot(h,'json')


try:
    before=run(['git','show','c2d2fd2df0fc964f5cd47557efb4d4333083df9b:bin/fm-backlog-transition-lib.sh']).stdout
    lib=SCRATCH/'baseline-transition.sh';lib.write_text(before)
    for phase in ['before','after']:
        h=new_home(phase)
        seed(h,'prep-parent','ship',state='queued')
        script='. "$1/bin/fm-tasks-axi-lib.sh"; . "$2"; fm_backlog_done "$3/data" prep-parent --report data/prep-parent/report.md'
        run(['bash','-c',script,'_',ROOT,lib if phase=='before' else ROOT/'bin/fm-backlog-transition-lib.sh',h],h)
        actual=state_of(shown(h,'prep-parent'))
        assert actual==('done' if phase=='before' else 'queued'),actual
        keep_snapshot(h,'red-green-'+phase)
        transcript.write(f'Observed {phase}: {actual}; required parent state: queued\n')
    print('Baseline reproduces incorrect Done; target retains Queued',flush=True)
finally:
    transcript.close();shutil.rmtree(SCRATCH)
