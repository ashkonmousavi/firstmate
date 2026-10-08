import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import threading
import time

root=Path.cwd()
lab=root/'.checkpoint-resume-lab'
sockets=root/'.t4'
evidence=Path('/home/tegris/.no-mistakes/evidence/01M4C578R6BY8Y88P3P9QJDFDG')
env=dict(os.environ)
for k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_TASK_ID','CODEX_SESSION_ID','CODEX_THREAD_ID'):
    env.pop(k,None)
env.update(FM_HOME=str(lab/'home'),TMUX_TMPDIR=str(sockets),TMPDIR=str(lab),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_TIMEOUT='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
records=[]
pid=None
timer=None

def run(label,args):
    start=time.monotonic()
    r=subprocess.run(args,cwd=root,env=env,capture_output=True,text=True,timeout=20)
    records.append(dict(label=label,command=args,elapsed=round(time.monotonic()-start,3),rc=r.returncode,stdout=r.stdout,stderr=r.stderr))
    print(json.dumps(records[-1]),flush=True)
    return r

try:
    assert not lab.exists() and not sockets.exists()
    lab.mkdir(mode=0o700)
    sockets.mkdir(mode=0o700)
    assert run('mint isolated lab',['bash','bin/fm-lab-home.sh','create',env['FM_HOME']]).returncode==0
    assert run('private tmux',['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','sleep 120']).returncode==0
    pid=int(run('private server pid',['tmux','-L','fm-lab','display-message','-p','#{pid}']).stdout)
    env['TMUX']=run('private socket',['tmux','-L','fm-lab','display-message','-p','#{socket_path},#{pid},0']).stdout.strip()
    p=lab/'home'
    (p/'state/one.meta').write_text('kind=ship\nbackend=tmux\nharness=codex\nwindow=primary:0\n')
    for f in ('.last-check','.last-heartbeat','home-summary.json'):
        (p/'state'/f).touch()
    os.kill(pid,signal.SIGSTOP)
    timer=threading.Timer(6,lambda:os.kill(pid,signal.SIGCONT))
    timer.start()
    r=run('three-second checkpoint; real server resumes at six seconds',['bash','bin/fm-watch-checkpoint.sh','--seconds','3'])
    assert r.returncode==124 and records[-1]['elapsed']<5
    timer.join()
    os.kill(pid,signal.SIGSTOP)
    timer=threading.Timer(4,lambda:os.kill(pid,signal.SIGCONT))
    timer.start()
    r=run('independent one-second real tmux capture; server resumes at four seconds',['bash','-c','value=$(timeout -k 1 1 tmux capture-pane -p -t primary:0 -S -40); rc=$?; printf "capture_rc=%s value=%s\\n" "$rc" "$value"'])
    assert 'capture_rc=124' in r.stdout and records[-1]['elapsed']>=3.8
    timer.join()
    print('CONFIRMED: checkpoint returns before the stopped server resumes; independent pipe capture still waits for server resume',flush=True)
finally:
    if timer:
        timer.cancel()
    if pid:
        os.kill(pid,signal.SIGCONT)
        run('private tmux teardown',['tmux','-L','fm-lab','kill-server'])
    shutil.rmtree(lab,ignore_errors=True)
    shutil.rmtree(sockets,ignore_errors=True)
    (evidence/'r2-live-backend-resume.json').write_text(json.dumps(records,indent=2)+'\n')
