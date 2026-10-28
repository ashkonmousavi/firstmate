import base64, hashlib, json, os, pathlib, signal, subprocess, sys, time
ROOT = pathlib.Path.cwd()
BASE = ROOT / '.test-exit76'
EVIDENCE = pathlib.Path('~/.no-mistakes/evidence/01M615XS1Y6YNQK6X4ABEX9M6G')
BASE.mkdir(exist_ok=True)
(BASE / 'tmp').mkdir(exist_ok=True)
LAB = BASE / 'live-barrier'
LAB.mkdir()
account = LAB / 'account'
(account / '.local/bin').mkdir(parents=True)
remote = LAB / 'remote'
(remote / 'state').mkdir(parents=True)
(remote / 'state/competitor.status').write_text('queued interactive command completed\n')
mode = LAB / 'mode.json'
mode.write_text('{}')
def executable(path, content):
    path.write_text(content)
    path.chmod(0o755)
executable(account / '.local/bin/perl', '#!/bin/bash\nwhile [ -f "$HOME/slow" ]; do /bin/sleep 0.1; done\nexec /usr/bin/perl "$@"\n')
queue_script = LAB / 'queue-call.sh'
executable(queue_script, '''#!/bin/bash
set -eu
root=$1 account=$2 home=$3 competing=$4
shift 4
. "$root/bin/fm-remote-job-lib.sh"
fm_remote_job_stage "$account" "$root" "$home" "$@" </dev/null >/dev/null
id=$FM_REMOTE_JOB_ID
other=
if [ "$competing" = 1 ]; then
  fm_remote_job_stage "$account" "$root" "$home" fm-remote-file.sh get state/competitor.status 1048576 </dev/null >/dev/null
  other=$FM_REMOTE_JOB_ID
fi
fm_remote_job_wait "$account" "$id"
rc=$FM_REMOTE_JOB_EXIT
cat "$FM_REMOTE_JOB_STDOUT"
cat "$FM_REMOTE_JOB_STDERR" >&2
rm -f "$account/slow"
fm_remote_job_reap "$account" "$id"
if [ -n "$other" ]; then
  fm_remote_job_wait "$account" "$other"
  [ "$FM_REMOTE_JOB_EXIT" = 0 ]
  fm_remote_job_reap "$account" "$other"
fi
exit "$rc"
''')
bridge = LAB / 'local-ssh.py'
executable(bridge, '''#!/usr/bin/env python3
import base64,json,os,pathlib,subprocess,sys,time
lab=pathlib.Path(os.environ['LIVE_LAB'])
a=sys.argv[sys.argv.index('--')+2:]
assert a[0]=='fm-remote-entrypoint.sh'
root=base64.b64decode(a[2]).decode()
home=base64.b64decode(a[3]).decode()
argv=base64.b64decode(a[4]).rstrip(b'\\0').decode().split('\\0')
c=json.loads((lab/'mode.json').read_text())
competing=False
if argv[0]=='fm-remote-delta-read.sh':
    offset=int(argv[2])
    if offset>=c.get('min_offset',0):
        key=argv[2]+':'+argv[3]
        if c.get('once_per_cursor'):
            seen=c.setdefault('seen',[])
            competing=key not in seen
            if competing:seen.append(key)
        elif c.get('remaining',0)>0:
            c['remaining']-=1
            competing=True
    (lab/'mode.json').write_text(json.dumps(c))
slow=lab/'account/slow'
if competing:slow.touch()
else:slow.unlink(missing_ok=True)
t=time.monotonic()
r=subprocess.run([str(lab/'queue-call.sh'),root,str(lab/'account'),home,str(int(competing)),*argv],capture_output=True)
with (lab/'calls.jsonl').open('a') as f:
    f.write(json.dumps({'argv':argv,'queued_competitor':competing,'exit':r.returncode,'elapsed':round(time.monotonic()-t,3),'stdout_bytes':len(r.stdout)})+'\\n')
sys.stdout.buffer.write(r.stdout)
sys.stderr.buffer.write(r.stderr)
sys.exit(r.returncode)
''')
env = dict(os.environ)
for k in list(env):
    if k.startswith('FM_') or k in ('HERDR_SESSION','TMUX'):
        env.pop(k)
env.update(HOME=str(account), FM_ROOT_OVERRIDE=str(ROOT), FM_REMOTE_JOB_STATE_ROOT=str(LAB/'jobs'), FM_REMOTE_JOB_TIMEOUT='20', FM_REMOTE_JOB_POLL_SECONDS='0.05', FM_REMOTE_JOB_ACTIVE_POLL_SECONDS='0.05', FM_SSH_BIN=str(bridge), LIVE_LAB=str(LAB), TMPDIR=str(BASE/'tmp'), PYTHONDONTWRITEBYTECODE='1')
worker_log = (EVIDENCE/'worker.log').open('w')
worker = subprocess.Popen([str(ROOT/'bin/fm-remote-job-worker.sh'),'--serve'],env=env,stdout=worker_log,stderr=subprocess.STDOUT,start_new_session=True)
log = (EVIDENCE/'live-transcript.log').open('w',buffering=1)
def emit(label,obj):
    text=label+' '+json.dumps(obj,sort_keys=True)
    log.write(text+'\n')
    print(text,flush=True)
def home_for(name):
    home=LAB/name
    subprocess.run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(home)],env=env,check=True,capture_output=True)
    (home/'data/secondmates.md').write_text(f'- q-server - disposable remote (host: local-lab; root: {ROOT}; home: {remote}; scope: testing; projects: none; added 2026-10-28)\n')
    stamp=int(time.time())-20
    initial=f'working [at={stamp}]: caught up\n'
    (remote/'state/parent-replies.status').write_text(initial)
    (home/'state/.remote-reply-mirrored-q-server').write_text(initial)
    return home,initial,stamp
calls_path=LAB/'calls.jsonl'
def calls():
    return [json.loads(s) for s in calls_path.read_text().splitlines()] if calls_path.exists() else []
def run(home,label):
    before=len(calls())
    t=time.monotonic()
    r=subprocess.run(['python3',str(ROOT/'bin/fm-main-backstop.py'),'--home',str(home),'--code-root',str(ROOT),'--mate','q-server'],env=env,capture_output=True,text=True,timeout=150)
    memory=json.loads((home/'state/.main-backstop.json').read_text())
    rows=calls()[before:]
    notes=list((home/'state/inbox').glob('*.md'))
    emit(label,{'exit':r.returncode,'elapsed':round(time.monotonic()-t,3),'stdout':r.stdout,'stderr':r.stderr,'memory':memory,'calls':rows,'inbox':[p.read_text() for p in notes]})
    assert r.returncode==0,r.stderr
    return memory,rows,r.stdout
try:
    for _ in range(100):
        assert worker.poll() is None,'worker exited'
        if (LAB/'jobs/worker.ready').exists():break
        time.sleep(.1)
    # One real queue preemption, identical re-arm, followed by a real no-data exit 75.
    home,initial,stamp=home_for('one-preemption')
    mode.write_text('{}')
    run(home,'one/bootstrap')
    body=initial+f'done [at={stamp+1}]: multi-line reply\ncontinuation text\n'
    (remote/'state/parent-replies.status').write_text(body)
    mode.write_text(json.dumps({'remaining':1}))
    m,rows,_=run(home,'one/rearm')
    assert [x['exit'] for x in rows]==[76,0,75]
    assert rows[0]['argv']==rows[1]['argv']
    assert m['readers']['q-server']['offset']==len(body.encode())
    assert not m['read_fails']
    emit('PASS one-preemption',{'same_argv':True,'at_tail':True,'read_fails':m['read_fails']})
    # Last allowed reissue succeeds: three preemptions followed by a delta.
    (remote/'state/parent-replies.status').write_text(body+f'done [at={stamp+2}]: last allowed reissue\n')
    mode.write_text(json.dumps({'remaining':3}))
    m,rows,_=run(home,'three/rearm')
    assert [x['exit'] for x in rows]==[76,76,76,0,75]
    assert all(x['argv']==rows[0]['argv'] for x in rows[:4])
    assert not m['read_fails']
    emit('PASS three-preemptions',{'attempts_before_success':4})
    # Four useful windows remain available, even when each cursor is preempted once.
    home,initial,stamp=home_for('window-budget')
    mode.write_text('{}')
    run(home,'budget/bootstrap')
    body=initial+(f'done [at={stamp+1}]: backlog\n'+'continuation '+('x'*80)+'\n')*1400
    assert 2*65536<len(body.encode())-len(initial.encode())<3*65536
    (remote/'state/parent-replies.status').write_text(body)
    mode.write_text(json.dumps({'once_per_cursor':True}))
    m,rows,_=run(home,'budget/drain')
    assert [x['exit'] for x in rows]==[76,0,76,0,76,0,76,75]
    for i in range(0,8,2): assert rows[i]['argv']==rows[i+1]['argv']
    assert m['readers']['q-server']['offset']==len(body.encode())
    assert not m['read_fails']
    emit('PASS four-read-budget',{'attempts':8,'completed_data_windows':3,'tail_exit':75})
    # Progress made before repeated preemption is durable; first pass is tolerated.
    home,initial,stamp=home_for('exhaustion')
    mode.write_text('{}')
    run(home,'exhaustion/bootstrap')
    body=initial+(f'done [at={stamp+1}]: backlog\n'+'continuation '+('y'*80)+'\n')*1400
    (remote/'state/parent-replies.status').write_text(body)
    mode.write_text(json.dumps({'remaining':100,'min_offset':len(initial.encode())+1}))
    m,rows,out=run(home,'exhaustion/first-pass')
    assert [x['exit'] for x in rows]==[0,76,76,76,76]
    cursor=m['readers']['q-server'].copy()
    assert cursor['offset']>len(initial.encode())
    assert all(x['argv']==rows[1]['argv'] for x in rows[1:])
    assert 'q-server' in m['read_fails']
    assert 'REPLY DELIVERY UNVERIFIED' not in out
    m,rows,out=run(home,'exhaustion/second-pass')
    assert [x['exit'] for x in rows]==[76]*4
    assert m['readers']['q-server']==cursor
    assert 'REPLY DELIVERY UNVERIFIED q-server' in out
    # The alarm is persisted through the real durable inbox.
    inbox=[p.read_text() for p in (home/'state/inbox').rglob('*') if p.is_file()]
    assert any('REPLY DELIVERY UNVERIFIED q-server' in s for s in inbox),inbox
    emit('PASS bounded-exhaustion',{'attempts_per_failed_read':4,'preserved_cursor':cursor,'durable_alarm':True})
    mode.write_text('{}')
    m,rows,out=run(home,'exhaustion/recovered')
    assert not m['read_fails']
    assert m['readers']['q-server']['offset']==len(body.encode())
    assert 'read-q-server' not in m['episodes']
    emit('PASS recovery',{'at_tail':True,'cleared_read_failure':True})
finally:
    worker.send_signal(signal.SIGTERM)
    try:rc=worker.wait(timeout=15)
    except subprocess.TimeoutExpired:
        os.killpg(worker.pid,signal.SIGKILL)
        rc=worker.wait()
    emit('worker-exit',{'exit':rc})
    worker_log.close()
    log.close()
