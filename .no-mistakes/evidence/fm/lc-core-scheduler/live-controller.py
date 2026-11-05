#!/usr/bin/env python3
"""Drive real executable callbacks, without service-manager/clock/spawn mocks.

This is recovery/primitive evidence, not a live systemd deadline/cadence claim.
All seeded data and subprocess state live in a marked disposable worktree home.
"""
import ctypes
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
LAB = ROOT / '.gate-live' / 'home'
SCHED = ROOT / 'bin/fm-autolaunch.sh'
ENGINE = ROOT / 'bin/fm-autolaunch-steps.py'
env = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
env.update(FM_HOME=str(LAB), PYTHONDONTWRITEBYTECODE='1')
children = []
ctypes.CDLL(None).prctl(36, 1, 0, 0, 0)  # own and reap orphan test descendants
results = []

def run(args, expected=0, timeout=20, **kw):
    p = subprocess.run([str(a) for a in args], env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, **kw)
    print('$', ' '.join(str(a) for a in args), flush=True)
    print('exit=',p.returncode,'stdout=',p.stdout.strip(),'stderr=',p.stderr.strip(),flush=True)
    assert p.returncode == expected, (args,p.returncode,p.stdout,p.stderr)
    return p

def load(path):
    return json.loads(path.read_text())

def write(path, data):
    path.write_text(json.dumps(data))

def effects(rc=73, acquired=False):
    run([sys.executable, ENGINE, 'controller-effects', SCHED, str(rc), str(int(acquired))])

def passed(name, detail):
    results.append(dict(name=name,result='pass',live=True,evidence='live-controller.log',reason='',detail=detail))
    print('PASS:',name,detail,flush=True)

def waitfile(path):
    end=time.monotonic()+10
    while not path.exists() and time.monotonic()<end:
        time.sleep(.05)
    assert path.exists(),path

def spawn(args):
    p=subprocess.Popen([str(a) for a in args],env=env,stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
    children.append(p)
    return p

def stop(p):
    if p.poll() is None:
        os.killpg(p.pid,signal.SIGTERM)
    p.wait(timeout=10)

def free_slot(key):
    with (slots/(key+'.lock')).open('a') as f:
        try:
            fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            return False

def seed(key,kind,argv,task='',expired=False):
    now=int(time.time())
    token=key+'-g1-r0-a1'
    row=dict(key=key,kind=kind,task=task,argv=argv,phase='running',rung=0,
             opened=now-620 if expired else now,overrun=0,generation=1,dispatch=1,attempt=token)
    attempt=dict(key=key,kind=kind,argv=argv,deadline=now-10 if expired else now+120,
                 unit='disposable-direct-callback',started=row['opened'],rung=0)
    write(journal/(key+'.json'),row)
    write(journal/token,attempt)
    return token

try:
    run(['bash',ROOT/'bin/fm-lab-home.sh','create',LAB])
    state=LAB/'state'
    journal=state/'autolaunch-controller'
    slots=state/'autolaunch-slots'
    (LAB/'.fm-secondmate-home').write_text('gate-disposable\n')
    (LAB/'data/backlog.md').write_text('## In flight\n## Queued\n## Done\n')
    (LAB/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')

    (LAB/'config/autolaunch-sole').touch()
    r=run(['bash',SCHED],expected=1)
    assert 'controller obligations preserved' in r.stderr
    journal.mkdir(exist_ok=True)
    write(journal/'pass.json',{'continuity_sentinel':'retain-me'})
    (LAB/'config/autolaunch-sole').unlink()
    run(['bash',SCHED],expected=1)
    assert load(journal/'pass.json')=={'continuity_sentinel':'retain-me'}
    passed('Activated home refuses an unavailable manager and preserves custody after marker removal',
           'Both public launcher invocations exited 1; the saved journal survived unchanged.')

    slots.mkdir(exist_ok=True)
    lock=state/'.spawn-live-probe.lock'
    holder_script=LAB/'hold-lock.sh'
    holder_script.write_text('''#!/bin/bash
source "$1/bin/fm-wake-lib.sh"
fm_lock_try_acquire "$2" || exit 3
printf '%s\\n' "$BASHPID" > "$3"
trap 'fm_lock_release "$2"' EXIT
while :; do sleep .2; done
''')
    holderpid=LAB/'holder.pid'
    holder=spawn(['bash',holder_script,ROOT,lock,holderpid])
    waitfile(holderpid)
    start=time.monotonic()
    p=run(['bash',SCHED,'--controller-spawn-lock','live-probe'])
    assert p.stdout.strip()==holderpid.read_text().strip()
    assert time.monotonic()-start<5 and holder.poll() is None and lock.exists()
    stop(holder)
    run(['bash',SCHED,'--controller-spawn-lock','live-probe'])
    assert not lock.exists()
    passed('Spawn-lock probe returns the live holder without waiting or disturbing it',
           'The real lock library reported its matching holder; after release a probe acquired and released the lock.')

    token=seed('ctl-b-recovery-live','recovery',['sleep','1000'],'live-recovery',True)
    action=spawn(['bash',SCHED,'--run-action',token])
    waitfile(journal/(token+'.identity'))
    ident=load(journal/(token+'.identity'))
    assert ident['pid']==action.pid or Path('/proc/'+str(ident['pid'])).exists()
    assert not free_slot('ctl-b-recovery-live')
    effects(); effects()
    row=load(journal/'ctl-b-recovery-live.json')
    assert row['phase']=='running' and row['handoff']['receipt'] and row['attempt']==token
    status=state/'live-recovery.status'
    assert status.read_text().count('blocked ')==1
    assert action.poll() is None and not free_slot(row['key'])
    run(['bash',SCHED,'--run-action',token],expected=75)
    assert action.poll() is None and not free_slot(row['key'])
    agent=spawn(['sleep','1000'])
    fields=Path('/proc/'+str(agent.pid)+'/stat').read_text().rsplit(') ',1)[1].split()
    boot=Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    (state/'live-recovery.meta').write_text(f'agent_root_pid={agent.pid}\nagent_root_start=wrong\nboot_id={boot}\n')
    effects()
    assert 'resolved ' not in status.read_text()
    (state/'live-recovery.meta').write_text(f'agent_root_pid={agent.pid}\nagent_root_start={fields[19]}\nboot_id={boot}\n')
    effects(); effects()
    assert status.read_text().count('resolved ')==1 and 'launched-late' in status.read_text()
    assert not free_slot(row['key']) and action.poll() is None
    print(status.read_text(),flush=True)
    shutil.copyfile(status,EVIDENCE/'live-recovery.status')
    shutil.copyfile(journal/'ctl-b-recovery-live.json',EVIDENCE/'live-recovery-row.json')
    stop(action); stop(agent)
    passed('Restore an overdue recovery with a living main: own once, retain its slot, and close only for matching current identity',
           'Real callbacks preserved the running attempt and occupied flock; stale start metadata did not close it; a current PID/start/boot did. No kernel KILL or harness launch is claimed.')

    pidfile=LAB/'descendant.pid'
    cmd=[sys.executable,'-c',"import subprocess,pathlib; p=subprocess.Popen(['sleep','1000'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); pathlib.Path("+repr(str(pidfile))+").write_text(str(p.pid))"]
    token=seed('ctl-a-descriptor-live','step',cmd)
    run(['bash',SCHED,'--run-action',token])
    childpid=int(pidfile.read_text())
    assert Path('/proc/'+str(childpid)).exists() and free_slot('ctl-a-descriptor-live')
    assert load(journal/(token+'.result'))['rc']==0
    os.kill(childpid,signal.SIGTERM)
    os.waitpid(childpid,0)
    passed('An action descendant survives wrapper exit without retaining its slot descriptor',
           'The real action callback returned rc=0 and released the flock while its spawned descendant was still alive.')

    source=state/'live-ask.status'
    source.write_text(f'needs-decision [key=retry-policy] [at={int(time.time())-190}]: choose retry interval\n')
    effects(); effects()
    assert source.read_text().count('blocked ')==1 and 'unanswered key=retry-policy' in source.read_text()
    askrows=[load(p) for p in journal.glob('ctl-c-ask-*.json')]
    assert len(askrows)==1 and askrows[0]['handoff']['receipt']
    assert not list((state/'autolaunch-diag').glob('*.identity'))
    run(['bash',ROOT/'bin/fm-status-append.sh',source,'resolved','--key','retry-policy'],input='chosen 60 seconds\n')
    effects(); effects()
    assert load(next(journal.glob('ctl-c-ask-*.json')))['closed']
    print(source.read_text(),flush=True)
    shutil.copyfile(source,EVIDENCE/'live-technical-decision.status')
    passed('Restore an overdue technical key: publish one durable ownership receipt and close after the answer',
           'Fresh callback processes produced one ownership record with no diagnosis, then consumed the real status writer’s answer. Cadence bounds are not claimed.')

    # Genuine elapsed-time test, no clock seam. This callback is the actual
    # busy-pass effects path, invoked directly because no isolated manager exists.
    passlock=state/'.autolaunch.lock'
    holderpid.unlink()
    holder=spawn(['bash',holder_script,ROOT,passlock,holderpid])
    waitfile(holderpid)
    held_at=int(time.time())
    (passlock/'at').write_text(str(held_at))
    for _ in range(3): effects()
    assert not list(journal.glob('ctl-e-pass-lock-*.json'))
    print('Three burst observations: no incident. Waiting for 61 real seconds of lock tenure.',flush=True)
    while time.time()<held_at+61:
        time.sleep(min(5,max(.01,held_at+61-time.time())))
    effects(); effects()
    incident=next(journal.glob('ctl-e-pass-lock-*.json'))
    assert load(incident)['handoff']['receipt']
    autostatus=state/'autolaunch.status'
    assert autostatus.read_text().count('blocked ')==1 and holder.poll() is None
    stop(holder)
    # Actual verified acquire precedes passing the acquisition witness.
    run(['bash','-c','source "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" && fm_lock_release "$2"','lab',ROOT,passlock])
    effects(73,True); effects(73,True)
    assert load(incident)['closed'] and autostatus.read_text().count('resolved ')==1
    print(autostatus.read_text(),flush=True)
    shutil.copyfile(autostatus,EVIDENCE/'live-pass-lock.status')
    passed('Rapid lock observations do not escalate; a persistent live lock owns once and closes on verified acquisition',
           f'Three burst observations created no incident; one appeared after {int(time.time())-held_at}s of real tenure without killing or stealing the holder. Recovery closed it once.')
finally:
    for child in children:
        stop(child)
    # Reap every adopted descendant, including action commands after TERM.
    end=time.monotonic()+5
    while time.monotonic()<end:
        try:
            pid,_=os.waitpid(-1,os.WNOHANG)
        except ChildProcessError:
            break
        if not pid:
            time.sleep(.05)
    shutil.rmtree(LAB,ignore_errors=True)
    (EVIDENCE/'live-controller-results.json').write_text(json.dumps(results,indent=2))
    print('Disposable lab removed; retained results:',len(results),flush=True)
