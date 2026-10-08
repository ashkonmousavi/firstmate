import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

root = Path.cwd()
lab = root/'.checkpoint-handoff-lab'
sockets = root/'.t3'
evidence = Path('/home/tegris/.no-mistakes/evidence/01M4C578R6BY8Y88P3P9QJDFDG')
env = dict(os.environ)
for k in ('NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_TEST_SEAM', 'FM_TASK_ID', 'CODEX_SESSION_ID', 'CODEX_THREAD_ID'):
    env.pop(k, None)
env.update(TMUX_TMPDIR=str(sockets), TMPDIR=str(lab), FM_POLL='1', FM_CHECK_TIMEOUT='1', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999')
records = []

def run(label, args, p=None):
    started = time.monotonic()
    r = subprocess.run(args, cwd=root, env=env | ({'FM_HOME':str(p)} if p else {}), text=True, capture_output=True, timeout=35)
    rec = dict(label=label, command=args, elapsed=round(time.monotonic()-started,3), rc=r.returncode, stdout=r.stdout, stderr=r.stderr)
    records.append(rec)
    print(json.dumps(rec), flush=True)
    return r

def new(name):
    p=lab/name
    assert run('create isolated home', ['bash','bin/fm-lab-home.sh','create',str(p)]).returncode==0
    for f in ('.last-check','.last-heartbeat','home-summary.json'):
        (p/'state'/f).touch()
    return p

def checkpoint(p,label,args=None):
    return run(label,['bash','bin/fm-watch-checkpoint.sh']+(args or ['--seconds','6']),p)

def ack(p):
    r=run('durable drain', ['bash','bin/fm-wake-drain.sh'],p)
    m=re.search(r'--ack-through (\d+) --recovery-generation (\S+)',r.stderr)
    assert m,r.stderr
    assert run('explicit generation acknowledgement',['bash','bin/fm-wake-drain.sh','--ack-through',m[1],'--recovery-generation',m[2]],p).returncode==0
    return r.stdout

try:
    assert not lab.exists() and not sockets.exists()
    lab.mkdir(mode=0o700)
    sockets.mkdir(mode=0o700)
    assert run('private 120x40 tmux',['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'sleep 300']).returncode==0
    env['TMUX']=run('private socket identity',['tmux','-L','fm-lab','display-message','-p','#{socket_path},#{pid},0']).stdout.strip()
    p=new('recovery')
    child=new('child')
    (child/'.fm-secondmate-home').write_text('mate\n')
    meta=p/'state/mate.meta'
    meta.write_text(f'kind=secondmate\nbackend=tmux\nharness=codex\nwindow=primary:absent-mate\nhome={child}\n')
    before=meta.read_bytes()
    for i in (1,2):
        r=checkpoint(p,f'bounded missing-mate handoff {i}')
        assert r.returncode==0 and 'recovery cycle required for relaunch mate' in r.stdout
        assert before==meta.read_bytes()
        assert not (p/'state/.secondmate-relaunch-mate').exists()
    queue=(p/'state/.wake-queue').read_text()
    assert queue.count('\tcheckpoint-recovery-relaunch-mate\t')==1
    records.append(dict(label='recovery handoff custody', queue=queue, metadata=meta.read_text(), attempt_ledger_exists=False))
    # The child is deliberately not a provisioned Git checkout. The real spawn
    # must fail closed, and --recover must publish that failure without faking
    # a successful native spawn or changing its recorded route.
    r=checkpoint(p,'explicit recovery reports invalid lab route', ['--recover'])
    assert r.returncode==0 and 'auto-relaunch failed' in r.stdout
    assert before==meta.read_bytes()
    ledger=(p/'state/.secondmate-relaunch-mate').read_text()
    assert ledger.count('\tattempt\n')==1 and ledger.count('\tfailed\n')==1
    assert '\trelaunched\n' not in ledger
    records.append(dict(label='failed recovery durable outcome',ledger=ledger,queue=(p/'state/.wake-queue').read_text()))
    ack(p)
    for kind in ('status','turn-ended'):
        p=new(kind)
        (p/'state'/f'demo.{kind}').write_text('done: real signal witness\n' if kind=='status' else 'finished\n')
        r=checkpoint(p,f'default-grace {kind} signal',['--seconds','3'])
        assert r.returncode==0 and 'signal:' in r.stdout
        drained=ack(p)
        assert drained.count(f'\tsignal\tdemo.{kind}\t')==1
        r=checkpoint(p,f'acknowledged {kind} signal does not repeat',['--seconds','3'])
        assert r.returncode==124 and 'no actionable wake' in r.stdout
    p=new('invalid-arguments')
    for args in (['--seconds','0'],['--recover','--seconds','3']):
        r=checkpoint(p,'invalid checkpoint arguments refused',args)
        assert r.returncode==2 and 'error:' in r.stderr
    print('LIVE HANDOFF, FAILED RECOVERY, DEFAULT-GRACE SIGNALS AND ARGUMENT GUARDS PASSED',flush=True)
finally:
    if sockets.exists():
        run('private server teardown',['tmux','-L','fm-lab','kill-server'])
    shutil.rmtree(lab,ignore_errors=True)
    shutil.rmtree(sockets,ignore_errors=True)
    (evidence/'r2-live-handoff-signals.json').write_text(json.dumps(records,indent=2)+'\n')
