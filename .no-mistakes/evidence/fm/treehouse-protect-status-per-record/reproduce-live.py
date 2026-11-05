import collections, json, os, pathlib, shutil, subprocess, sys, time

ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('~/.no-mistakes/evidence/01M6NX6MWXJ2PQ9RNNAJVSV3FV')
LAB = ROOT / '.test-live' / 'lab'
LAB.mkdir()
REAL = shutil.which('treehouse')
HOME = LAB / 'home'
for name in ('state', 'data', 'config', 'projects'):
    (HOME / name).mkdir(parents=True, exist_ok=True)
TRACE = LAB / 'calls.jsonl'
BIN = LAB / 'bin'
BIN.mkdir()
wrapper = BIN / 'treehouse'
wrapper.write_text('#!/usr/bin/env python3\nimport os,json,sys\nwith open(os.environ["LIVE_TRACE"],"a") as f: f.write(json.dumps({"cwd":os.getcwd(),"argv":sys.argv[1:]})+"\\n")\nos.execv(os.environ["LIVE_TREEHOUSE"],[os.environ["LIVE_TREEHOUSE"]]+sys.argv[1:])\n')
wrapper.chmod(0o755)
ENV = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TREEHOUSE_', 'GIT_'))}
ENV.update(HOME=str(HOME), FM_HOME=str(HOME), FM_ROOT_OVERRIDE=str(ROOT),
           FM_STATE_OVERRIDE=str(HOME/'state'), PATH=str(BIN)+os.pathsep+os.environ['PATH'],
           LIVE_TRACE=str(TRACE), LIVE_TREEHOUSE=REAL, TMPDIR=str(LAB))
transcript = open(EVIDENCE / 'live-transcript.log', 'w', buffering=1)
results = []
def run(args, cwd=LAB, expected=0, env=ENV):
    start = time.monotonic()
    proc = subprocess.run([str(x) for x in args], cwd=cwd, env=env, text=True, capture_output=True, timeout=120)
    transcript.write('$ (cwd='+str(cwd)+') '+ ' '.join(str(x) for x in args)+'\n')
    transcript.write(proc.stdout+proc.stderr+f'EXIT={proc.returncode} SECONDS={time.monotonic()-start:.3f}\n')
    if expected is not None:
        assert proc.returncode == expected, proc.stderr
    return proc
def repo(name):
    path = LAB / name
    run(['git', 'init', '-q', '-b', 'main', path])
    run(['git', '-C', path, '-c', 'user.name=Live test', '-c', 'user.email=live@example.invalid', 'commit', '--allow-empty', '-qm', 'initial'])
    return path
PROJECT = repo('project')
OTHER = repo('other-project')
def acquire(root):
    return json.loads(run(['treehouse','--root',root,'get','--lease','--json','--no-fetch','--base','main'], PROJECT).stdout)
def release(root, lease):
    run(['treehouse','--root',root,'return',lease['path'],'--if-lease-id',lease['lease_id']], PROJECT)
def record(name, lease, **extra):
    values = dict(project=str(PROJECT),worktree=lease['path'],kind='scout',status='done')
    values.update(extra)
    (HOME/'state'/f'{name}.meta').write_text(''.join(k+'='+v+'\n' for k,v in values.items()))
def calls():
    return [json.loads(x) for x in TRACE.read_text().splitlines()]
def status_calls(items):
    return [x for x in items if x['argv'][-2:] == ['status','--json']]
def library(op='protect', mode='', path='', name='direct', expected=0, source=None):
    lib = source or ROOT/'bin/fm-treehouse-lib.sh'
    script = '\n'.join('. "$ROOT/bin/'+x+'"' for x in ['fm-wake-lib.sh','fm-secondmate-registry-lib.sh','fm-backend.sh'])
    script += '\n. "$LIB"\n'
    if op == 'protect':
        script += 'fm_treehouse_protect_recorded_copies "$FM_HOME/state" "$PROJECT" "$MODE"\n'
    else:
        script += 'fm_treehouse_hold_recorded_copy "$PROJECT" "$COPY" "$TASK" "$MODE"\nprintf "NEW_LEASE_ID=%s\\n" "$FM_TREEHOUSE_NEW_LEASE_ID"\n'
    env = dict(ENV, ROOT=str(ROOT), LIB=str(lib), PROJECT=str(PROJECT), MODE=mode, COPY=path, TASK=name)
    before = len(calls()) if TRACE.exists() else 0
    result = run(['bash','-eu','-c',script], expected=expected, env=env)
    return calls()[before:], result
def statefile(lease):
    return pathlib.Path(lease['path']).parents[1]/'treehouse-state.json'
def lease_map(lease):
    return {x['path']:x for x in json.loads(statefile(lease).read_text())['worktrees']}
def save_result(name, **details):
    results.append(dict(name=name,result='pass',**details))
    transcript.write('SCENARIO '+json.dumps(results[-1])+'\n')

try:
    run(['treehouse','--version'])
    root1, root2 = LAB/'root-a', LAB/'root-b'
    initial = [acquire(root1) for _ in range(4)]
    for i in (0,1): release(root1, initial[i])
    for i in range(3): record(f'a{i}', initial[i])
    for i in range(3): (pathlib.Path(initial[i]['path'])/'unlanded.txt').write_text(f'keep-{i}\n')
    original_id = initial[2]['lease_id']
    events,_ = library(mode='check')
    assert len(status_calls(events)) == 1
    assert not any(('lease' in x['argv'] or 'return' in x['argv']) and '--help' not in x['argv'] for x in events)
    assert not lease_map(initial[0])[initial[0]['path']].get('leased',False)
    save_result('check mode reads once without taking leases', status_reads=1)
    events,_ = library()
    assert len(status_calls(events)) == 1
    lease_events = [x for x in events if 'lease' in x['argv']]
    assert [x['argv'][3] for x in lease_events] == ['1','2']
    state = lease_map(initial[0])
    assert all(state[x['path']].get('leased') for x in initial[:3])
    assert state[initial[2]['path']]['lease_id'] == original_id
    assert state[initial[3]['path']]['lease_id'] == initial[3]['lease_id']
    for i in range(3): assert (pathlib.Path(initial[i]['path'])/'unlanded.txt').read_text() == f'keep-{i}\n'
    save_result('three retained copies share one snapshot and preserve unrelated/existing leases and files', status_reads=1, lease_slots=['1','2'], existing_lease_unchanged=True)
    events,_ = library()
    assert len(status_calls(events)) == 1 and not any('lease' in x['argv'] for x in events)
    release(root1, initial[3])
    record('a3', initial[3])
    events,_ = library()
    assert len(status_calls(events)) == 1
    assert [x['argv'][3] for x in events if 'lease' in x['argv']] == ['4']
    save_result('replay refreshes status and observes a newly retained slot', replay_status_reads=1, newly_held_slot='4')
    b = acquire(root2)
    release(root2,b)
    record('z-second-root',b)
    # Release slot 4 so a premature first-root hold would be visible.
    a4 = lease_map(initial[3])[initial[3]['path']]
    release(root1, a4)
    before = [statefile(initial[0]).read_bytes(), statefile(b).read_bytes()]
    lock = statefile(b).with_name('treehouse-state.lock')
    lock.unlink(missing_ok=True)
    lock.mkdir()
    events,proc = library(expected=1)
    assert len(status_calls(events)) == 2
    assert not any(('lease' in x['argv'] or 'return' in x['argv']) and '--help' not in x['argv'] for x in events)
    assert before == [statefile(initial[0]).read_bytes(),statefile(b).read_bytes()]
    assert 'cannot durably protect' in proc.stderr
    lock.rmdir()
    save_result('later root status failure refuses without partial leases', status_reads=2, native_error='treehouse-state.lock is a directory', unchanged_pool_bytes=True)
    events,_ = library()
    assert len(status_calls(events)) == 2
    assert collections.Counter(x['argv'][1] for x in status_calls(events)) == {str(root1):1,str(root2):1}
    assert lease_map(initial[0])[initial[3]['path']].get('leased')
    assert lease_map(b)[b['path']].get('leased')
    save_result('two roots each get one snapshot and recover after failure', roots=2, status_reads=2)
    fresh = acquire(root1)
    release(root1,fresh)
    events,proc = library(op='hold',path=fresh['path'])
    assert len(status_calls(events)) == 1 and 'NEW_LEASE_ID=' in proc.stdout
    direct_id = lease_map(fresh)[fresh['path']]['lease_id']
    assert direct_id and direct_id in proc.stdout
    events,proc = library(op='hold',path=fresh['path'])
    assert len(status_calls(events)) == 1 and not any('lease' in x['argv'] for x in events)
    assert lease_map(fresh)[fresh['path']]['lease_id'] == direct_id
    save_result('direct hold fetches fresh status and exposes new lease identity', status_reads_per_call=1)
    # Baseline implementation must reject the same independent count oracle.
    baseline = ROOT/'.test-live/baseline-lib.sh'
    baseline.write_text(run(['git','show','d23d07ade96bf4ccfae4275e4d4c63b673462c33:bin/fm-treehouse-lib.sh'],ROOT).stdout)
    events,_ = library(source=baseline)
    assert len(status_calls(events)) == 5
    save_result('baseline reproduces per-record work with identical real pool records', retained_records=5, old_status_reads=5, fixed_status_reads=2)
    comparisons=[]
    for cwd in [PROJECT, OTHER, pathlib.Path(initial[0]['path']), LAB]:
        start=time.monotonic()
        proc=run(['treehouse','--root',root1,'status','--json'],cwd,expected=None)
        comparisons.append(dict(cwd=str(cwd),exit=proc.returncode,seconds=round(time.monotonic()-start,3),slots=len(json.loads(proc.stdout)) if proc.returncode==0 else None,stderr=proc.stderr))
    assert [x['slots'] for x in comparisons] == [5,0,5,0]
    # LAB is enclosed by the gate repository; use an isolated HOME path with
    # Git discovery explicitly bounded at LAB to demonstrate a true non-repo.
    env=dict(ENV,GIT_CEILING_DIRECTORIES=str(LAB))
    proc=run(['treehouse','--root',root1,'status','--json'],HOME,expected=None,env=env)
    assert proc.returncode != 0 and 'not in a git or jj repository' in proc.stderr
    save_result('cwd selects repository-specific pools; a non-repository refuses', comparison=comparisons, nonrepo_exit=proc.returncode)
    (EVIDENCE/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    (EVIDENCE/'native-calls.jsonl').write_text(TRACE.read_text())
    for label,lease in [('root-a-final',initial[0]),('root-b-final',b)]:
        (EVIDENCE/(label+'.json')).write_bytes(statefile(lease).read_bytes())
finally:
    transcript.close()
