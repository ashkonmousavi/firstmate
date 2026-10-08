import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import threading
import time

root=Path.cwd()
lab=root/'.checkpoint-publication-lab'
evidence=Path('/home/tegris/.no-mistakes/evidence/01M4C578R6BY8Y88P3P9QJDFDG')
env=dict(os.environ)
for k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_TASK_ID','CODEX_SESSION_ID','CODEX_THREAD_ID'):
    env.pop(k,None)
env.update(TMPDIR=str(lab),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_TIMEOUT='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
records=[]
holder=None
stop=threading.Event()

def run(label,args,p):
    start=time.monotonic()
    r=subprocess.run(args,cwd=root,env=env|{'FM_HOME':str(p)},capture_output=True,text=True,timeout=18)
    records.append(dict(label=label,command=args,elapsed=round(time.monotonic()-start,3),rc=r.returncode,stdout=r.stdout,stderr=r.stderr))
    print(json.dumps(records[-1]),flush=True)
    return r

def ack(p):
    r=run('durable publication drain',['bash','bin/fm-wake-drain.sh'],p)
    m=re.search(r'--ack-through (\d+) --recovery-generation (\S+)',r.stderr)
    assert m,r.stderr
    assert run('generation acknowledgement',['bash','bin/fm-wake-drain.sh','--ack-through',m[1],'--recovery-generation',m[2]],p).returncode==0
    return r.stdout

try:
    assert not lab.exists()
    lab.mkdir(mode=0o700)
    for attempt in range(1,9):
        p=lab/f'attempt{attempt}'
        assert run('mint marked lab',['bash','bin/fm-lab-home.sh','create',str(p)],p).returncode==0
        for f in ('.last-check','.last-heartbeat','home-summary.json'):
            (p/'state'/f).touch()
        for f in ('a.status','b.status'):
            (p/'state'/f).write_text(f'done: {f} witness\n')
        stop.clear()
        lock=p/'state/.wake-queue.lock'
        def contend():
            while not stop.is_set():
                queue=p/'state/.wake-queue'
                if queue.exists() and queue.stat().st_size:
                    try:
                        lock.mkdir()
                        # The public lock record names this actual live owner.
                        (lock/'pid').write_text(f'{os.getpid()}\n')
                        (p/'holder-ready').touch()
                        return
                    except FileExistsError:
                        pass
                time.sleep(0.0001)
        holder=threading.Thread(target=contend)
        holder.start()
        r=run(f'contended publication attempt {attempt}',['bash','bin/fm-watch-checkpoint.sh','--seconds','3'],p)
        stop.set()
        holder.join()
        if (p/'holder-ready').exists():
            assert (lock/'pid').read_text().strip()==str(os.getpid())
            (lock/'pid').unlink()
            lock.rmdir()
        holder=None
        queue=(p/'state/.wake-queue').read_text()
        records.append(dict(label='post-publication contention queue',queue=queue,holder_ready=(p/'holder-ready').exists()))
        if queue.count('\tsignal\t')==1 and r.returncode==124:
            break
    else:
        raise AssertionError('could not reach post-first-publication contention')
    first=ack(p)
    assert first.count('\tsignal\ta.status\t')==1 and '\tsignal\tb.status\t' not in first
    r=run('later signal resumed after lock release',['bash','bin/fm-watch-checkpoint.sh','--seconds','3'],p)
    assert r.returncode==0 and 'signal:' in r.stdout
    later=ack(p)
    assert '\tsignal\ta.status\t' not in later and later.count('\tsignal\tb.status\t')==1
    r=run('both acknowledged publications stay quiet',['bash','bin/fm-watch-checkpoint.sh','--seconds','3'],p)
    assert r.returncode==124 and 'no actionable wake' in r.stdout
    print('LIVE CONTENDED PUBLICATION PASSED',flush=True)
finally:
    if holder:
        stop.set()
        holder.join()
    shutil.rmtree(lab,ignore_errors=True)
    (evidence/'live-publication.json').write_text(json.dumps(records,indent=2)+'\n')
