import os, pathlib, subprocess, time, json, sys
R=pathlib.Path.cwd(); L=R/'.restart-live'; P=L/'parent'; B=L/'product/bin'
E=pathlib.Path('~/.no-mistakes/evidence/01M6A6KX5P60NKCFH991XHF4T7')
e=os.environ.copy()
for k in list(e):
 if k.startswith('FM_') or k in ['NO_MISTAKES_GATE','TMUX','TMUX_PANE','GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','TASKS_AXI_FILE','TASKS_AXI_BACKEND']: e.pop(k,None)
e.update(FM_HOME=str(P),FM_BACKEND='tmux',TMUX_TMPDIR=str(E/'tmux'),FM_SKIP_SECONDMATE_SYNC='1',FM_SKIP_SECONDMATE_INHERIT='1',FM_SPAWN_NO_GUARD='1',FM_SECONDMATE_PERSIST_WAIT='120',FM_SECONDMATE_PERSIST_POLL='1',FM_SECONDMATE_RESTART_VERIFY_WAIT='90',FM_SECONDMATE_RESTART_VERIFY_POLL='1',FM_CONTROL_EXIT_WAIT='30',FM_CONTROL_LAUNCH_WAIT='60',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
tmux=['tmux','-L','fm-lab']
def cmd(args,**kw): return subprocess.run(args,env=e,text=True,capture_output=True,**kw)
e['TMUX']=cmd(tmux+['display-message','-p','-t','primary:fm-sm1','#{socket_path},#{pid},0'],check=True).stdout.strip()
def sh(s,**kw): return cmd(['bash','-c',s,'_',str(B)],**kw)
def wait(pred,seconds,desc):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  if pred(): return
  time.sleep(.1)
 raise RuntimeError('Timeout: '+desc)
def phase():
 p=P/'state/sm1.control-relaunch'
 return p.read_text() if p.exists() else ''
def log(name,text): (E/name).write_text(text); print(name, text[-2200:], flush=True)
children=[]
try:
 lockscript='STATE="$FM_HOME/state"; . "$1/fm-wake-lib.sh"; fm_lock_try_acquire "$STATE/.spawn-sm1.lock" || exit 1; touch "$FM_HOME/state/holder-ready"; while [ ! -e "$FM_HOME/state/release-holder" ]; do sleep 0.1; done; fm_lock_release "$STATE/.spawn-sm1.lock"'
 holder=subprocess.Popen(['bash','-c',lockscript,'_',str(B)],env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);children.append(holder)
 wait(lambda:(P/'state/holder-ready').exists(),5,'spawn lock holder')
 f=(E/'live-restart-collision.txt').open('w')
 restart=subprocess.Popen(['bash',str(B/'fm-secondmate-restart.sh'),'sm1'],env=e,stdout=f,stderr=subprocess.STDOUT,text=True);children.append(restart)
 wait(lambda:'phase=failed:launching' in phase() or restart.poll() is not None,150,'restart launch refusal')
 assert 'phase=failed:launching' in phase(), (E/'live-restart-collision.txt').read_text()
 log('live-collision-journal.txt',phase())
 probe='STATE="$FM_HOME/state"; . "$1/fm-secondmate-liveness-lib.sh"; fm_secondmate_liveness_probe "$STATE/sm1.meta" sm1 poll; echo "endpoint=$FM_SM_LIVE_STATE verdict=$FM_SM_LIVE_STATUS"'
 pre=sh(probe,timeout=20);log('live-before-winner-probe.txt',pre.stdout+pre.stderr);assert 'endpoint=dead' in pre.stdout
 assert (P/'state/.secondmate-liveness-sm1.lock').exists(), 'restart must hold liveness lock'
 ledger=P/'state/.secondmate-relaunch-sm1';before=ledger.read_bytes() if ledger.exists() else b''
 tick=sh('. "$1/fm-watch.sh"; SECONDMATE_LIVENESS_SECS=0; secondmate_liveness_tick; rc=$?; echo "watch_tick_rc=$rc"; exit "$rc"',timeout=30)
 log('live-watch-during-restart.txt',tick.stdout+tick.stderr);assert tick.returncode==0
 assert (ledger.read_bytes() if ledger.exists() else b'')==before,'watcher spent a relaunch attempt'
 assert restart.poll() is None, 'restart gave up before winner'
 assert 'endpoint=dead' in sh(probe,timeout=20).stdout,'watcher changed the endpoint'
 (P/'state/release-holder').touch();h_out=holder.communicate(timeout=5)[0];assert holder.returncode==0,h_out
 winner=cmd(['bash',str(B/'fm-spawn.sh'),'sm1','--relaunch'],timeout=100)
 log('live-winning-spawn.txt',winner.stdout+winner.stderr);assert winner.returncode==0
 restart.wait(timeout=100);f.close();print('restart_exit='+str(restart.returncode),flush=True)
 out=(E/'live-restart-collision.txt').read_text();print(out,flush=True)
 assert restart.returncode==0 and 'restarted: sm1' in out and 'replacement was then confirmed running' in out and 'another spawn is already creating task sm1' in out
 assert not (P/'state/.secondmate-liveness-sm1.lock').exists()
 after=sh(probe,timeout=20);log('live-after-winner-probe.txt',after.stdout+after.stderr);assert 'endpoint=alive' in after.stdout
 assert (ledger.read_bytes() if ledger.exists() else b'')==before
 capture=cmd(tmux+['capture-pane','-p','-S','-100','-t','primary:fm-sm1'],check=True)
 log('live-winning-agent-pane.txt',capture.stdout)
 log('live-collision-result.json',json.dumps({'restart_exit':restart.returncode,'watch_tick_exit':tick.returncode,'winner_spawn_exit':winner.returncode,'watcher_attempts_added':0,'endpoint_before':'dead','endpoint_after':'alive','restart_lock_released':True},indent=2))
finally:
 for p in children:
  if p.poll() is None:
   p.terminate()
   try:p.wait(timeout=5)
   except subprocess.TimeoutExpired:p.kill();p.wait()
