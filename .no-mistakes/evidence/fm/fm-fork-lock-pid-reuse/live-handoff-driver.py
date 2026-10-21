import pathlib, os, tempfile, subprocess, time, signal, shutil
root=pathlib.Path.cwd(); ev=pathlib.Path('~/.no-mistakes/evidence/01M5DZZKH0CM54A41JRQBQZY8H')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=root)); processes=[]; log=[]
env={k:v for k,v in os.environ.items() if not(k.startswith('FM_') or k in ('STATE','DATA','CONFIG','TMUX'))}; env.update(FM_HOME=str(lab),TMPDIR=str(lab))
def emit(s): print(s,flush=True); log.append(s)
def start(code):
 p=subprocess.Popen(['bash','-c',code,'_',str(root/'bin/fm-wake-lib.sh'),str(lab/'state/.handoff.lock'),str(lab)],env=env,start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True); processes.append(p); return p
def ready(name):
 for _ in range(150):
  if (lab/name).exists(): return
  time.sleep(.02)
 raise AssertionError('not ready: '+name)
try:
 subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],env=env,check=True,capture_output=True)
 holder=start('. "$1"; fm_lock_try_acquire "$2" || exit 1; touch "$3/holder-ready"; while [ ! -e "$3/release-holder" ]; do sleep 0.05; done; fm_lock_release "$2"')
 ready('holder-ready')
 waiter=start('. "$1"; fm_lock_acquire_wait_bounded "$2" 3 || exit $?; touch "$3/waiter-ready"; while [ ! -e "$3/release-waiter" ]; do sleep 0.05; done; fm_lock_release "$2"')
 time.sleep(.3); assert not (lab/'waiter-ready').exists(); emit('waiter stays blocked while original live holder owns the lock')
 (lab/'release-holder').touch(); holder.wait(timeout=3); assert holder.returncode==0
 ready('waiter-ready'); lock=lab/'state/.handoff.lock'
 pid=(lock/'pid').read_text().strip(); identity=(lock/'identity').read_text().strip()
 ticks=pathlib.Path(f'/proc/{waiter.pid}/stat').read_text().rsplit(')',1)[1].split()[19]
 assert pid==str(waiter.pid) and identity.startswith('linux-starttime='+ticks+' ')
 emit(f'bounded helper handed lock to waiting caller pid={pid}; independent caller start tick={ticks}; stored identity={identity}')
 r=subprocess.run(['bash','-c','. "$1"; if fm_lock_try_acquire "$2"; then exit 9; fi; printf "contender blocked by caller pid=%s\\n" "$FM_LOCK_HELD_PID"; [ "$FM_LOCK_HELD_PID" = "$3" ]','_',str(root/'bin/fm-wake-lib.sh'),str(lock),pid],env=env,text=True,capture_output=True,timeout=3)
 emit(r.stdout+r.stderr); assert r.returncode==0
 (lab/'release-waiter').touch(); waiter.wait(timeout=3); assert waiter.returncode==0 and not lock.exists()
 emit('caller released handed-off lock successfully')
finally:
 for p in processes:
  if p.poll() is None: os.killpg(p.pid,signal.SIGTERM); p.wait(timeout=3)
 shutil.rmtree(lab); emit('lab and owned processes removed')
 (ev/'live-handoff-transcript.txt').write_text('\n'.join(log)+'\n')
