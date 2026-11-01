import pathlib,os,subprocess,time,json
R=pathlib.Path.cwd();L=R/'.restart-live';P=L/'parent';B=L/'product/bin';E=pathlib.Path('~/.no-mistakes/evidence/01M6A6KX5P60NKCFH991XHF4T7')
e=os.environ.copy()
for k in list(e):
 if k.startswith('FM_') or k in ['NO_MISTAKES_GATE','TMUX','TMUX_PANE','GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:e.pop(k,None)
e.update(FM_HOME=str(P),FM_BACKEND='tmux',TMUX_TMPDIR=str(E/'tmux'),FM_SKIP_SECONDMATE_SYNC='1',FM_SKIP_SECONDMATE_INHERIT='1',FM_SPAWN_NO_GUARD='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
tmux=['tmux','-L','fm-lab']
def cmd(a,**kw):return subprocess.run(a,env=e,text=True,capture_output=True,**kw)
e['TMUX']=cmd(tmux+['display-message','-p','-t','primary:fm-sm1','#{socket_path},#{pid},0'],check=True).stdout.strip()
def sh(s,**kw):return cmd(['bash','-c',s,'_',str(B)],**kw)
def log(n,s): (E/n).write_text(s); print(n,s,flush=True)
probe='STATE="$FM_HOME/state"; . "$1/fm-secondmate-liveness-lib.sh"; fm_secondmate_liveness_probe "$STATE/sm1.meta" sm1 poll; echo "endpoint=$FM_SM_LIVE_STATE verdict=$FM_SM_LIVE_STATUS"'
tick='. "$1/fm-watch.sh"; SECONDMATE_LIVENESS_SECS=0; secondmate_liveness_tick; rc=$?; echo "watch_tick_rc=$rc"; exit "$rc"'
q=sh(probe,timeout=20);log('watch-live-initial-agent.txt',q.stdout+q.stderr);assert 'endpoint=alive' in q.stdout
# Remove only the stale spawn lock abandoned by the previous setup driver, through the public lock helpers.
r=sh('STATE="$FM_HOME/state"; . "$1/fm-wake-lib.sh"; fm_lock_try_acquire "$STATE/.spawn-sm1.lock" && fm_lock_release "$STATE/.spawn-sm1.lock"',timeout=10);assert r.returncode==0,r.stderr
holder= None
try:
 holder=subprocess.Popen(['bash','-c','STATE="$FM_HOME/state"; . "$1/fm-wake-lib.sh"; fm_secondmate_liveness_lock_not_used=1; fm_lock_try_acquire "$STATE/.secondmate-liveness-sm1.lock" || exit 1; echo held; read -r release; fm_lock_release "$STATE/.secondmate-liveness-sm1.lock"','_',str(B)],env=e,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 assert holder.stdout.readline().strip()=='held'
 stopped=cmd(['bash',str(B/'fm-control.sh'),'sm1','exit'],timeout=45);log('watch-live-agent-exit.txt',stopped.stdout+stopped.stderr);assert stopped.returncode==0
 q=sh(probe,timeout=20);log('watch-live-dead-endpoint.txt',q.stdout+q.stderr);assert 'endpoint=dead' in q.stdout
 ledger=P/'state/.secondmate-relaunch-sm1';before=ledger.read_bytes() if ledger.exists() else b''
 pane_before=cmd(tmux+['display-message','-p','-t','primary:fm-sm1','#{pane_id}:#{pane_pid}'],check=True).stdout
 for i in range(3):
  t=sh(tick,timeout=30);log(f'watch-live-locked-tick-{i}.txt',t.stdout+t.stderr);assert t.returncode==0
  assert (ledger.read_bytes() if ledger.exists() else b'')==before
  assert cmd(tmux+['display-message','-p','-t','primary:fm-sm1','#{pane_id}:#{pane_pid}'],check=True).stdout==pane_before
  assert 'endpoint=dead' in sh(probe,timeout=20).stdout
 log('watch-live-lock-result.json',json.dumps({'ticks':3,'agent_state':'dead','endpoint_identity_unchanged':True,'ledger_unchanged':True,'restart_lock_held':True},indent=2))
 holder.communicate('release\n',timeout=5);assert holder.returncode==0
 # Simulate a restarter crash with a real lock-owner process that exits without unlocking.
 abandoned=sh('STATE="$FM_HOME/state"; . "$1/fm-wake-lib.sh"; fm_lock_try_acquire "$STATE/.secondmate-liveness-sm1.lock"; echo "abandoned_owner=${BASHPID:-$$}"',timeout=5)
 log('watch-live-abandoned-lock.txt',abandoned.stdout+abandoned.stderr);assert abandoned.returncode==0
 t=sh(tick,timeout=130);log('watch-live-stale-lock-recovery.txt',t.stdout+t.stderr);assert t.returncode==0
 q=sh(probe,timeout=30);log('watch-live-recovered-agent.txt',q.stdout+q.stderr);assert 'endpoint=alive' in q.stdout
 rows=ledger.read_text();log('watch-live-recovery-ledger.txt',rows);assert rows.count('\tattempt\n')==1 and rows.count('\trelaunched\n')==1
 assert not (P/'state/.secondmate-liveness-sm1.lock').exists()
 pane=cmd(tmux+['capture-pane','-p','-t','primary:fm-sm1'],check=True);log('watch-live-recovered-pane.txt',pane.stdout)
 log('watch-live-recovery-result.json',json.dumps({'watch_tick_exit':t.returncode,'endpoint_after_recovery':'alive','attempt_rows':1,'relaunched_rows':1,'stale_lock_reclaimed':True},indent=2))
finally:
 if holder and holder.poll() is None:
  holder.terminate();holder.wait(timeout=5)
