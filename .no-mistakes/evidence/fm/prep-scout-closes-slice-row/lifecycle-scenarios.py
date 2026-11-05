import os, sys, json, subprocess, pathlib, shutil, re, traceback
ROOT = pathlib.Path.cwd()
EVID = pathlib.Path('~/.no-mistakes/evidence/01M6N7VHPCAPP5324ZXXW0YMRS')
SCRATCH = ROOT / '.test-phase-lifecycle'
SCRATCH.mkdir(exist_ok=False)
(SCRATCH/'tmp').mkdir()
base = os.environ.copy()
for key in list(base):
    if key.startswith(('FM_', 'TASKS_AXI_', 'HERDR_', 'XDG_')) or key in ('TMUX','ZELLIJ','NO_MISTAKES_GATE'):
        base.pop(key, None)
base['TMPDIR'] = str(SCRATCH/'tmp')
base['GIT_CONFIG_NOSYSTEM']='1'
base['GIT_CONFIG_GLOBAL']='/dev/null'
transcript = (EVID/'lifecycle-cli-transcript.log').open('w')
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
        fn(); results.append(dict(name=name,result='pass',live=True,evidence='lifecycle-cli-transcript.log',reason=''))
        print('PASS '+name,flush=True)
    except Exception as exc:
        traceback.print_exc(file=transcript);transcript.flush()
        results.append(dict(name=name,result='fail',live=True,evidence='lifecycle-cli-transcript.log',reason=str(exc)))
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


SOCKET=ROOT/'.fm-lab-validation.sock'
base['TMUX']=str(SOCKET)+',1,0'

def launchable(h, ident):
    (h/'projects/phase').mkdir(exist_ok=True)
    (h/'data'/ident/'brief.md').write_text('Completed prep brief.\n')
    (h/'data'/ident/'autolaunch-prep').write_text('project=phase\nkind=scout\n')
    return run(['bash',ROOT/'bin/fm-autolaunch.sh','--list-prepared'],h).stdout.strip()

def cleanup():
    # This sweep is read-only. Refuse the live teardown if it would touch an outside worker.
    sweep=run(['bash',ROOT/'bin/fm-remote-job-reap-orphans.sh','--dry-run'])
    assert not sweep.stdout.strip(), 'Outside orphan workers would be changed by teardown: '+sweep.stdout
    run(['tmux','-S',SOCKET,'new-session','-d','-s','fm-lab-validation','-n','keeper','-x','100','-y','30','sleep 300'])
    try:
        for label,kind,body in [('ship','ship',''),('owner','scout','SLICE: main/example role=owner'),('bold','scout','**SLICE**: main/example role=owner')]:
            for accepted in [False,True]:
                ident=f'clean-{label}-{int(accepted)}'
                h=new_home(ident)
                seed(h,ident,kind,body,'done' if accepted else 'in_flight')
                if not accepted:
                    cli(h,'add','child','Dependent build')
                    cli(h,'block','child','--by',ident)
                # Prove the preparation is eligible before cleanup on a queued row.
                if not accepted:
                    cli(h,'reopen',ident)
                    assert launchable(h,ident)==ident
                    cli(h,'start',ident)
                else: launchable(h,ident)
                run(['tmux','-S',SOCKET,'new-window','-t','fm-lab-validation','-n',f'fm-{ident}','sleep 300'],h)
                run(['bash',ROOT/'bin/fm-captain-hold.sh','complete',ident,'--none'],h)
                run(['bash',ROOT/'bin/fm-lease.sh','claim',ident],h)
                out=run(['bash',ROOT/'bin/fm-teardown.sh',ident],h).stdout
                (EVID/f'{ident}-teardown.txt').write_text(out)
                assert 'scout phase report and note recorded' in out and 'parent completion state preserved.' in out,out
                assert 'stays open' not in out and 'parent outcome is not accepted' not in out,out
                assert state_of(shown(h,ident))==('done' if accepted else 'queued')
                assert not (h/'state'/f'{ident}.meta').exists()
                assert not (h/'state'/f'{ident}.backlog-close').exists()
                assert not run(['bash',ROOT/'bin/fm-autolaunch.sh','--list-prepared'],h).stdout.strip()
                assert (h/'data'/ident/'prep.md').read_text()=='Durable prep evidence.\n'
                assert (h/'data'/ident/'report.md').is_file()
                if not accepted: assert ident in shown(h,'child')
                windows=run(['tmux','-S',SOCKET,'list-windows','-t','fm-lab-validation','-F','#{window_name}'],h).stdout.splitlines()
                assert f'fm-{ident}' not in windows,windows
                keep_snapshot(h,ident)
    finally:
        run(['tmux','-S',SOCKET,'kill-server'],check=False)
        probe=run(['tmux','-S',SOCKET,'list-sessions'],check=False)
        assert probe.returncode != 0, 'Private tmux server survived teardown'
        if SOCKET.exists(): SOCKET.unlink()

def replay():
    for state in ['queued','in_flight','done','answered']:
        for mode in ['close','retain']:
            ident=f'replay-{state}-{mode}'
            h=new_home(ident)
            seed(h,ident,'scout','**SLICE**: main/example role=owner',state if state!='answered' else 'queued',meta=False)
            if state=='queued': assert launchable(h,ident)==ident
            else: launchable(h,ident)
            if state=='answered':
                run(['bash',ROOT/'bin/fm-captain-hold.sh','hold',ident,'--reason','Choose the reported outcome','--origin',ident],h)
                (h/'answer.txt').write_text('Accept this outcome.\n')
            script=''' . "$1/bin/fm-tasks-axi-lib.sh"
. "$1/bin/fm-backlog-transition-lib.sh"
flags=(); [ "$4" != retain ] || flags=(--retain)
fm_backlog_close_marker_stage "$2/state/$3.backlog-close" "$3" "$2/data" s1.1.1 "$2/state" 0 "${flags[@]}" --report "data/$3/report.md" || exit
if [ "$5" = answered ]; then bash "$1/bin/fm-captain-hold.sh" answer "$3" --decision-file "$2/answer.txt" || exit; fi
fm_backlog_close_marker_replay "$2/state" "$2/state/$3.backlog-close" "$2/data" || { echo "$FM_BACKLOG_TRANSITION_ERROR"; exit 1; }
printf 'replay_result=%s\n' "$FM_BACKLOG_CLOSE_REPLAY_RESULT"
fm_backlog_close_marker_replay "$2/state" "$2/state/$3.backlog-close" "$2/data" || exit
printf 'second_replay_result=%s\n' "$FM_BACKLOG_CLOSE_REPLAY_RESULT"
'''
            run(['bash','-c',script,'_',ROOT,h,ident,mode,state],h)
            expected='done' if state in ['done','answered'] else 'queued'
            out=shown(h,ident)
            assert state_of(out)==expected,out
            assert not (h/'state'/f'{ident}.backlog-close').exists()
            assert not run(['bash',ROOT/'bin/fm-autolaunch.sh','--list-prepared'],h).stdout.strip()
            if expected=='queued': assert 'scout phase finished' in out and f'data/{ident}/report.md' in out,out
            assert (h/'data'/ident/'prep.md').is_file() and (h/'data'/ident/'report.md').is_file()
            keep_snapshot(h,ident)

def prompt():
    out=run(['bash',ROOT/'bin/fm-branch-prompt.sh']).stdout
    (EVID/'emitted-supervision-prompt.txt').write_text(out)
    assert 'A scout phase on a ship or slice owner row records its report and note and does NOT mark the row done; the owner row is done only after its green walk.' in out
    assert 'Use the same guarded completion command to retain that phase' in out

try:
    scenario('Scout cleanup releases endpoints, queues unfinished parents without redispatch, preserves settled rows and dependencies, and reports state neutrally',cleanup)
    scenario('Interrupted report completion replays idempotently without metadata, preserves settled answers, and retires completed prep eligibility',replay)
    scenario('Generated supervision prompt distinguishes a completed scout phase from accepted owner completion',prompt)
finally:
    run(['tmux','-S',SOCKET,'kill-server'],check=False)
    if SOCKET.exists(): SOCKET.unlink()
    (EVID/'lifecycle-results.json').write_text(json.dumps(results,indent=2))
    transcript.close()
    shutil.rmtree(SCRATCH)
sys.exit(1 if any(r['result']=='fail' for r in results) else 0)
