import os, pathlib, subprocess, tempfile, threading, queue, shutil, json
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M5D70D1KH51JH0MC04VMEJ9K')
q=queue.Queue(); stop=threading.Event()
def worker():
    q.put(threading.get_native_id()); stop.wait()
t=threading.Thread(target=worker); t.start(); tid=q.get(); pid=os.getpid()
log=[]
def note(s):
    log.append(s); print(s, flush=True)
def drain(home, bindir):
    env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('STATE','TMUX','NO_MISTAKES_GATE')}
    env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(home),FM_STATUS_PRESENTATION_LOCK_TIMEOUT='1')
    p=subprocess.run(['bash',str(bindir/'fm-wake-drain.sh')],env=env,text=True,capture_output=True,timeout=20)
    note(f'CLI {bindir.name}/fm-wake-drain.sh rc={p.returncode}\nstdout:\n{p.stdout}\nstderr:\n{p.stderr}')
    return p
def seed(home, holder, name):
    state=home/'state'; lock=state/'.wake-queue.lock'; lock.mkdir()
    (lock/'pid').write_text(str(holder)+'\n')
    (state/'.wake-queue').write_text('1700000000\t1\tcheck\tlock-proof\t'+name+'\n')
    return state,lock
try:
    with tempfile.TemporaryDirectory(prefix='.lock-live-',dir=root) as temp:
        temp=pathlib.Path(temp)
        def home(name):
            h=temp/name
            subprocess.run(['bash',str(root/'bin/fm-lab-home.sh'),'create',str(h)],check=True,capture_output=True)
            return h
        os.kill(tid,0)
        status=pathlib.Path(f'/proc/{tid}/status').read_text()
        note('REAL KERNEL ORACLE: '+ '\n'.join(x for x in status.splitlines() if x.startswith(('Name:', 'Tgid:', 'Pid:'))))
        assert tid!=pid
        assert f'Tgid:\t{pid}\n' in status
        note(f'kill -0 accepts non-leader thread {tid}; its process leader is {pid}. No proc override is set.')
        # Reproduce old behavior through the same CLI, with the original library.
        baseline=temp/'baseline-bin'; shutil.copytree(root/'bin',baseline)
        old=subprocess.run(['git','show','94e6a4315d7674895a70cf3b17ed24ce21a0cff3:bin/fm-wake-lib.sh'],check=True,capture_output=True).stdout
        (baseline/'fm-wake-lib.sh').write_bytes(old)
        h=home('old-thread'); state,lock=seed(h,tid,'thread-id recovery')
        p=drain(h,baseline)
        assert 'WAKE DRAIN SKIPPED' in p.stdout and (lock/'pid').read_text().strip()==str(tid)
        note('BASELINE REPRODUCED: old CLI incorrectly refuses to drain behind a non-leader thread ID.')
        h=home('thread'); state,lock=seed(h,tid,'thread-id recovery')
        p=drain(h,root/'bin')
        assert p.returncode==0 and 'thread-id recovery' in p.stdout and 'WAKE DRAIN SKIPPED' not in p.stdout
        assert not lock.exists(); os.kill(tid,0)
        note('PASS thread-ID stale lock: real CLI presented queued wake, released reclaimed lock, and unrelated thread survived.')
        h=home('live'); state,lock=seed(h,pid,'live-process protection')
        before=(state/'.wake-queue').read_bytes()
        p=drain(h,root/'bin')
        assert p.returncode==0 and 'WAKE DRAIN SKIPPED' in p.stdout
        assert (lock/'pid').read_text().strip()==str(pid) and (state/'.wake-queue').read_bytes()==before
        os.kill(pid,0)
        note('PASS live process lock: CLI reports live holder, preserves PID and queue bytes.')
        (lock/'pid').unlink(); lock.rmdir()
        p=drain(h,root/'bin')
        assert p.returncode==0 and 'live-process protection' in p.stdout and not lock.exists()
        note('PASS after holder release: same CLI presents the preserved wake.')
        child=subprocess.Popen(['sleep','60']); dead=child.pid; child.terminate(); child.wait()
        try: os.kill(dead,0)
        except ProcessLookupError: pass
        else: raise AssertionError('dead PID unexpectedly alive')
        h=home('dead'); state,lock=seed(h,dead,'dead-process recovery')
        p=drain(h,root/'bin')
        assert p.returncode==0 and 'dead-process recovery' in p.stdout and not lock.exists()
        note('PASS dead process lock: CLI reclaims terminated holder and presents queued wake.')
    note('CLEANUP: all disposable homes and baseline binaries removed.')
finally:
    stop.set(); t.join()
    (evidence/'live-locks.log').write_text('\n'.join(log)+'\n')
