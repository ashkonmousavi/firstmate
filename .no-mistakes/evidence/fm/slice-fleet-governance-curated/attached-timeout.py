import os,pathlib,tempfile,subprocess,time,shutil,json,signal
r=pathlib.Path.cwd();e=pathlib.Path('~/.no-mistakes/evidence/01M6QTPTMK4BHKP80JC21WTY8N');h=pathlib.Path(tempfile.mkdtemp(prefix='.live-attached-',dir=r));children=[];logs=[]
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','TMUX'))}
env.update(FM_HOME=str(h),FM_POLL='1',FM_CHECK_INTERVAL='0',FM_HEARTBEAT='999999',FM_GUARD_GRACE='3',FM_WATCHER_STALL_BOUND='4',FM_CHECK_FORCE_FALLBACK='1',FM_ARM_ATTACH_POLL='0.1',FM_ARM_SUCCESSOR_CONFIRM_TIMEOUT='1')
def start(s,*args):
 p=subprocess.Popen(['bash',str(r/'bin'/s),*args],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True);children.append(p);return p

def finish(p,label):
 o,err=p.communicate(timeout=20);logs.append(dict(label=label,exit=p.returncode,stdout=o,stderr=err));return p.returncode,o,err
try:
 rc,o,err=finish(start('fm-lab-home.sh','create',str(h)),'lab create');assert rc==0,(o,err)
 c=h/'state'/'slow.check.sh';c.write_text('#!/usr/bin/env bash\n# FM_CHECK_TIMEOUT=12\ntouch "$FM_HOME/entered"\nprintf "check entered\\n"\nsleep 30\n');c.chmod(0o700)
 rc,o,err=finish(start('fm-check-register.sh','slow'),'register slow');assert rc==0,(o,err)
 watcher=start('fm-watch.sh');deadline=time.monotonic()+8
 while not (h/'entered').exists() and time.monotonic()<deadline:time.sleep(.05)
 assert (h/'entered').exists(),'slow check not entered'
 arm=start('fm-watch-arm.sh');time.sleep(5)
 assert arm.poll() is None,'attached arm exited before check result'
 rc,o,err=finish(start('fm-watch.sh'),'duplicate start after stall bound');assert rc==0 and f'already running pid {watcher.pid}' in o,(o,err)
 rc,o,err=finish(watcher,'watcher timeout completion');assert rc==0 and 'failing tool: slow' in o,(o,err)
 rc,o,err=finish(arm,'attached arm delivery');assert rc==0 and f'attached pid={watcher.pid}' in o and 'failing tool: slow' in o,(o,err)
 q=(h/'state'/'.wake-queue').read_text();logs.append(dict(label='persisted timeout notification',queue=q));assert 'timed out after 12s (measured ' in q
 assert not (h/'state'/'.watch.lock'/'pid').exists(),'watcher lock survived'
 print('PASS: portable timeout path preserved original watcher beyond a 4s stall bound; attached arm waited and delivered the 12s named timeout.',flush=True)
finally:
 for p in children:
  if p.poll() is None:
   p.terminate()
   try:p.communicate(timeout=6)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.communicate()
 (e/'attached-timeout.json').write_text(json.dumps(logs,indent=2,ensure_ascii=False));shutil.rmtree(h)
