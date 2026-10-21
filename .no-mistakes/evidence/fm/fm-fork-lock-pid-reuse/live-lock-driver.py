import os, pathlib, subprocess, tempfile, shutil, time, signal
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M5DZZKH0CM54A41JRQBQZY8H')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=root))
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('STATE','DATA','CONFIG','TMUX'))}
env.update(FM_HOME=str(lab),TMPDIR=str(lab),FM_REMOTE_REPLY_LIFECYCLE_LOCK_WAIT='1')
lib=root/'bin/fm-wake-lib.sh'
processes=[]
log=[]
def emit(s):
    print(s,flush=True); log.append(s)
def run(args, **kw):
    t=time.monotonic(); p=subprocess.run(args,env=env,cwd=root,text=True,capture_output=True,timeout=8,**kw)
    emit(f'$ {" ".join(map(str,args))}\nexit={p.returncode} elapsed={time.monotonic()-t:.3f}s\n{p.stdout}{p.stderr}')
    return p

def shell(code,*args): return run(['bash','-c',code,'_',str(lib),*map(str,args)])
def holder(lock):
    ready=lab/'ready'; ready.unlink(missing_ok=True)
    p=subprocess.Popen(['bash','-c','. "$1"; fm_lock_try_acquire "$2" || exit 7; : > "$3"; while :; do sleep 0.1; done','_',str(lib),str(lock),str(ready)],env=env,cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,start_new_session=True)
    processes.append(p)
    for _ in range(100):
        if ready.exists(): break
        if p.poll() is not None: raise RuntimeError(p.stderr.read())
        time.sleep(.03)
    assert ready.exists()
    emit(f'actual holder pid={p.pid}, persisted pid={ (lock/"pid").read_text().strip()}, identity={ (lock/"identity").read_text().strip()}')
    return p

def stop(p):
    if p.poll() is None: os.killpg(p.pid,signal.SIGTERM); p.wait(timeout=3)
try:
    assert run(['bin/fm-lab-home.sh','create',str(lab)]).returncode==0
    state=lab/'state'; lock=state/'.identity.lock'
    p=holder(lock)
    # The independently observed Linux process start tick must equal the published contract.
    ticks=pathlib.Path(f'/proc/{p.pid}/stat').read_text().rsplit(')',1)[1].split()[19]
    emit(f'independent /proc start-time tick={ticks}')
    assert (lock/'identity').read_text().strip().startswith('linux-starttime='+ticks+' ')
    r=shell('. "$1"; if fm_lock_try_acquire "$2"; then exit 8; fi; printf "blocked by matching live holder pid=%s identity=%s\\n" "$FM_LOCK_HELD_PID" "$(cat "$2/identity")"; [ "$FM_LOCK_HELD_PID" = "$3" ]',lock,p.pid)
    assert r.returncode==0
    stop(p)
    unrelated=subprocess.Popen(['sleep','60'],start_new_session=True); processes.append(unrelated)
    old_identity=(lock/'identity').read_text(); (lock/'pid').write_text(str(unrelated.pid)+'\n')
    emit(f'reuse fixture: dead original owner identity={old_identity.strip()}, pid record now points to unrelated live sleep pid={unrelated.pid}')
    # Baseline must exhibit the incident against this same persisted state.
    base=lab/'base/bin'; base.mkdir(parents=True)
    (base/'fm-wake-lib.sh').write_text(subprocess.check_output(['git','show','f8a8cb8867915267231084312ced4dab147af081:bin/fm-wake-lib.sh'],text=True))
    shutil.copy(root/'bin/fm-path-lib.sh',base/'fm-path-lib.sh')
    r=run(['bash','-c','. "$1"; if fm_lock_try_acquire "$2"; then exit 8; fi; printf "BASELINE BUG: stale lock blocked by unrelated live pid=%s\\n" "$FM_LOCK_HELD_PID"','_',str(base/'fm-wake-lib.sh'),str(lock)])
    assert r.returncode==0 and 'BASELINE BUG' in r.stdout
    r=shell('. "$1"; fm_lock_try_acquire "$2" || exit 8; printf "reclaimed stale lock: recovered_pid=%s new_pid=%s new_identity=%s\\n" "$FM_LOCK_RECOVERED_PID" "$(cat "$2/pid")" "$(cat "$2/identity")"; [ "$FM_LOCK_RECOVERED_PID" = "$3" ] || exit 9; fm_lock_release "$2"; [ ! -e "$2" ]',lock,unrelated.pid)
    assert r.returncode==0; assert unrelated.poll() is None
    emit('unrelated process remains alive after recovery')
    for fmt in ('directory','symlink'):
        legacy=state/f'.legacy-{fmt}.lock'; owner=legacy if fmt=='directory' else state/'.legacy-owner'
        owner.mkdir(); (owner/'pid').write_text(str(unrelated.pid)+'\n')
        if fmt=='symlink': legacy.symlink_to(owner)
        r=shell('. "$1"; if fm_lock_try_acquire "$2"; then exit 8; fi; printf "legacy live holder protected: pid=%s\\n" "$FM_LOCK_HELD_PID"; [ "$FM_LOCK_HELD_PID" = "$3" ]',legacy,unrelated.pid)
        assert r.returncode==0
    lifecycle=state/'.remote-reply-lifecycle-mate1.lock'; p=holder(lifecycle)
    identity=(lifecycle/'identity').read_text().strip()
    (state/'mate1.meta').write_text('kind=secondmate\nremote_host=lab-unreachable\nremote_home=/disposable-lab-only\nbackend=tmux\n')
    (lab/'data/secondmates.md').write_text('- mate1 remote_host=lab-unreachable remote_home=/disposable-lab-only\n')
    for args in (['bin/fm-procevent-remote-reply.sh','arm','mate1'],['bin/fm-procevent-remote-reply.sh','handle','mate1','1',str(lab/'unused-result')],['bin/fm-procevent-remote-reply.sh','retire','mate1'],['bin/fm-procevent-remote-reply.sh','autohandle','remote-reply-mate1','1',str(lab/'unused-result')],['bin/fm-teardown.sh','mate1']):
        r=run(args)
        assert r.returncode!=0 and f'by pid {p.pid} (identity: {identity})' in r.stderr
        assert (lifecycle/'pid').read_text().strip()==str(p.pid)
        assert p.poll() is None
    emit('all lifecycle commands refused within deadline; holder and metadata preserved')
    # A released live holder allows a waiter to proceed, rather than always timing out.
    stop(p)
    r=shell('. "$1"; . "$4"; secondmate_reply_lifecycle_lock_wait "$2" || exit $?; printf "lifecycle recovery after owner exit: recovered=%s\\n" "$FM_LOCK_RECOVERED_PID"; fm_lock_release "$2"',lifecycle,p.pid,root/'bin/fm-secondmate-registry-lib.sh')
    assert r.returncode==0
    emit('ALL LIVE SCENARIOS PASSED')
finally:
    for p in processes: stop(p)
    shutil.rmtree(lab)
    emit('disposable lab and all owned processes removed')
    (evidence/'live-lock-transcript.txt').write_text('\n'.join(log)+'\n')
