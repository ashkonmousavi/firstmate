import fcntl, os, pathlib, signal, subprocess, time
root=pathlib.Path.cwd(); lab=root/'.nm-lock-lab'
subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],check=True)
env=os.environ.copy()
for k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_TEST_HARNESS'): env.pop(k,None)
env['FM_HOME']=str(lab); env['FM_SUPERVISION_ACTOR']='branch'; env['FM_LEASE_HOLDER_PID']=str(os.getpid())
state=lab/'state'; holder=None

def run(args, expected, extra=None, timeout=10):
    e=env.copy(); e.update(extra or {})
    start=time.monotonic(); p=subprocess.run(args,env=e,capture_output=True,text=True,timeout=timeout)
    print('$ '+' '.join(map(str,args)),flush=True)
    print('exit=%s elapsed=%.3fs'%(p.returncode,time.monotonic()-start),flush=True)
    print(p.stdout+p.stderr,end='',flush=True)
    assert p.returncode==expected,(p.returncode,expected)
    return p
try:
    lock=state/'.fm-lease-command.lock'
    lock.write_bytes(b'foreign flock lock: do not remove\n')
    os.utime(lock,(1000000000,1000000000))
    before=lock.stat(); original=lock.read_bytes()
    with lock.open('rb') as fd:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        for command in (['bash','bin/fm-lease.sh','claim','malformed','--actor','branch'],['bash','bin/fm-lease.sh','release-actor','--actor','branch']):
            p=run(command,78); assert str(lock) in p.stderr
        after=lock.stat()
        assert (before.st_ino,before.st_mtime_ns,before.st_size)==(after.st_ino,after.st_mtime_ns,after.st_size)
        assert lock.read_bytes()==original
        print('Observed: foreign-held regular file kept its inode, modification time, size, and exact contents; no lease published.',flush=True)
        assert not (state/'.lease-malformed').exists()
    lock.unlink()
    legacy=state/'.steal-probe.lock'; legacy.mkdir(); (legacy/'pid').write_text('99999999\n')
    steal=state/'.steal-probe.lock.steal'; steal.touch()
    run(['bash','-c','STATE="$FM_HOME/state"; . bin/fm-wake-lib.sh; fm_lock_acquire_wait "$STATE/.steal-probe.lock"; echo UNLOCKED_ENTRY'],78)
    assert steal.is_file() and not steal.is_symlink()
    watch=state/'.watch.lock'; watch.write_bytes(b'foreign watcher lock\n')
    p=run(['bash','bin/fm-watch.sh'],1); assert str(watch) in p.stderr and 'already running' not in p.stderr+p.stdout
    assert watch.read_bytes()==b'foreign watcher lock\n'
    print('Observed: malformed steal mutex and watcher lock refuse promptly by name.',flush=True)
    run(['bash','bin/fm-lease.sh','claim','kept','--actor','branch'],0)
    lease=state/'.lease-kept'; saved=lease.read_bytes()
    holder=subprocess.Popen(['bash','-c','STATE="$FM_HOME/state"; . bin/fm-wake-lib.sh; fm_lock_acquire_wait "$STATE/.fm-lease-command.lock"; trap \'fm_lock_release "$STATE/.fm-lease-command.lock"\' EXIT; echo "$$" > "$FM_HOME/ready"; sleep 60'],env=env,start_new_session=True)
    deadline=time.monotonic()+5
    while not (lab/'ready').exists():
        assert time.monotonic()<deadline; time.sleep(.05)
    start=time.monotonic()
    p=run(['bash','bin/fm-lease.sh','release-actor','--actor','branch'],7,{'FM_LEASE_RELEASE_ACTOR_WAIT':'3600'})
    elapsed=time.monotonic()-start
    assert 3.5<elapsed<8 and str(holder.pid) in p.stderr
    assert lease.read_bytes()==saved
    print('Observed: a 3600-second legacy environment override cannot extend the fixed bound; holder pid named and lease byte-identical.',flush=True)
    os.killpg(holder.pid,signal.SIGTERM); holder.wait(timeout=3); holder=None
    run(['bash','bin/fm-lease.sh','release-actor','--actor','branch'],0)
    assert not lease.exists()
    print('Observed: after contention clears, a real release removes the branch lease.',flush=True)
finally:
    if holder is not None:
        os.killpg(holder.pid,signal.SIGTERM); holder.wait(timeout=3)
    import shutil
    shutil.rmtree(lab)
    print('Disposable lock/lease lab removed.',flush=True)
