import os,pathlib,signal,subprocess,time,shutil
root=pathlib.Path.cwd(); lab=root/'.nm-baseline-lab'
subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],check=True)
env=os.environ.copy()
for k in ('FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_TEST_HARNESS'):env.pop(k,None)
env.update(FM_HOME=str(lab),STATE=str(lab/'state'),FM_SUPERVISION_ACTOR='main',FM_LEASE_HOLDER_PID=str(os.getpid()))
(lab/'state/.lock').write_text(str(os.getpid())+'\n')
holder=None
try:
    lock=lab/'state/.plain.lock';lock.write_bytes(b'foreign file\n')
    for lib,rc in [('bin/.nm-baseline-wake-lib.sh',124),('bin/fm-wake-lib.sh',78)]:
        start=time.monotonic()
        p=subprocess.run(['timeout','2','bash','-c','. "$1"; fm_lock_acquire_wait "$STATE/.plain.lock"; echo UNLOCKED_ENTRY','_',lib],env=env,text=True,capture_output=True)
        print('Plain-file acquisition using '+lib+': exit='+str(p.returncode)+' elapsed=%.3fs'%(time.monotonic()-start));print(p.stdout+p.stderr,end='',flush=True);assert p.returncode==rc
        assert lock.read_bytes()==b'foreign file\n'
    for lib,rc in [('bin/.nm-baseline-lease-lib.sh',124),('bin/fm-lease-lib.sh',0)]:
        ready=lab/'ready'; ready.unlink(missing_ok=True)
        holder=subprocess.Popen(['bash','-c','. "$1"; fm_lease_guard slow probe; trap fm_lease_guard_release EXIT; echo ready > "$FM_HOME/ready"; sleep 30','_',lib],env=env,start_new_session=True)
        deadline=time.monotonic()+5
        while not ready.exists():assert time.monotonic()<deadline;time.sleep(.05)
        e=env.copy();e['FM_SUPERVISION_ACTOR']='branch';start=time.monotonic()
        p=subprocess.run(['timeout','2','bash','bin/fm-lease.sh','claim','unrelated','--actor','branch'],env=e,capture_output=True,text=True)
        print('Unrelated claim during guarded mutation using '+lib+': exit='+str(p.returncode)+' elapsed=%.3fs'%(time.monotonic()-start)); print(p.stdout+p.stderr,end='',flush=True);assert p.returncode==rc
        os.killpg(holder.pid,signal.SIGTERM);holder.wait(timeout=3);holder=None
    print('Both reported failures reproduce at base and pass at target.',flush=True)
finally:
    if holder is not None:os.killpg(holder.pid,signal.SIGTERM);holder.wait(timeout=3)
    shutil.rmtree(lab)
