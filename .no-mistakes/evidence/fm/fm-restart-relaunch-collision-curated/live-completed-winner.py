import os,pathlib,subprocess,time,json,shlex,re
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M6ABB3CG4YQMA6RX128VE4E6');p=json.loads((R/'.test-tmp/live-paths.json').read_text());lab=pathlib.Path(p['lab']);sm=pathlib.Path(p['sm'])
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') and k.endswith('_OVERRIDE') or k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TASK_ID']: env.pop(k,None)
env.update(FM_HOME=str(lab),FM_BACKEND='tmux',TMUX_TMPDIR=str(lab/'tmux'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
log=open(E/'live-completed-winner.log','w',buffering=1)
def cmd(args):
 p=subprocess.run(list(map(str,args)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+'exit='+str(p.returncode)+'\n');return p

def actor(name,body):
 rc=lab/(name+'.rc');rc.unlink(missing_ok=True)
 path=lab/(name+'.sh');path.write_text('#!/bin/bash\ncd '+str(R)+'\n'+body+'\nprintf "%s\\n" "$?" > '+str(rc)+'\n')
 cmd(['tmux','-L','fm-lab','new-window','-d','-t','primary','-n',name,'-c',R,'bash',path]);return rc

def until(f,seconds=30):
 d=time.monotonic()+seconds
 while time.monotonic()<d:
  if f():return True
  time.sleep(.1)
 return False

realcodex=__import__('shutil').which('codex');(lab/'tools').mkdir(exist_ok=True)
for mode in ['complete']:
 prefix='live-'+mode
 cmd(['tmux','-L','fm-lab','set-environment','-t','primary','PATH',env['PATH']])
 cmd(['tmux','-L','fm-lab','kill-window','-t','primary:fm-sm1'])
 for n in ['competitor-ready','release-competitor']: (lab/n).unlink(missing_ok=True)
 (lab/'state'/'sm1.control-relaunch').unlink(missing_ok=True)
 # No project or global settings are modified by these per-invocation flags.
 oldspawn=actor('oldspawn',f"{R}/bin/fm-spawn.sh sm1 {sm} --secondmate --harness 'codex --no-daemon --disable hooks --dangerously-bypass-approvals-and-sandbox' > {E/(prefix+'-oldspawn.txt')} 2>&1")
 assert until(lambda:oldspawn.exists(),30)
 assert oldspawn.read_text().strip()=='0',(E/(prefix+'-oldspawn.txt')).read_text()
 time.sleep(8)
 p=cmd(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-sm1']);(E/(prefix+'-before.txt')).write_text(p.stdout)
 # This transparent workspace-local launcher execs the real authenticated CLI;
 # complete disables hooks, failed retains the actual operator-review dialog.
 wrapper=lab/'tools'/'codex';wrapper.write_text('#!/bin/bash\nexec '+shlex.quote(realcodex)+' --no-daemon '+('--disable hooks ' if mode=='complete' else '')+'"$@"\n');wrapper.chmod(0o755)
 cmd(['tmux','-L','fm-lab','set-environment','-t','primary','PATH',str(lab/'tools')+':'+env['PATH']])
 winner=actor('winner',f'''export PATH={lab/'tools'}:"$PATH"
 . {R}/bin/fm-wake-lib.sh
 fm_lock_try_acquire "$FM_HOME/state/.spawn-sm1.lock" || exit 1
 touch "$FM_HOME/competitor-ready"
 until grep -q '^phase=failed:launching' "$FM_HOME/state/sm1.control-relaunch" 2>/dev/null; do sleep .05; done
 fm_lock_release "$FM_HOME/state/.spawn-sm1.lock"
 tmux kill-window -t primary:fm-sm1
 {R}/bin/fm-spawn.sh sm1 {sm} --secondmate --harness cursor > {E/(prefix+'-winner.txt')} 2>&1''')
 assert until(lambda:(lab/'competitor-ready').exists(),8)
 oldcorr=set(x.name for x in (lab/'state'/'pending-replies').glob('*')) if (lab/'state'/'pending-replies').exists() else set()
 restart=actor('restart',f'''FM_SECONDMATE_PERSIST_WAIT=30 FM_SECONDMATE_PERSIST_POLL=1 FM_SECONDMATE_RESTART_VERIFY_WAIT=8 FM_SECONDMATE_RESTART_VERIFY_POLL=20 {R}/bin/fm-secondmate-restart.sh sm1 > {E/(prefix+'-restart.txt')} 2>&1''')
 assert until(lambda:any(x.name not in oldcorr for x in (lab/'state'/'pending-replies').glob('*')),10)
 corr=next(x.name for x in (lab/'state'/'pending-replies').glob('*') if x.name not in oldcorr and re.fullmatch('[a-f0-9]{16}',x.name))
 # The tester acknowledges the empty fixture's open-work contract using the real producer.
 old=env['FM_HOME'];env['FM_HOME']=str(sm);cmd([R/'bin/fm-secondmate-report.sh','done',corr,'No open work exists in this disposable home; empty persistence verified by tester.']);env['FM_HOME']=old
 assert until(lambda:(lab/'state'/'.secondmate-liveness-sm1.lock').exists(),10)
 watch=actor('watcher',f'''bash -c '
 . "$1/bin/fm-watch.sh"
 SECONDMATE_LIVENESS_SECS=0
 end=$((SECONDS+12))
 while [ "$SECONDS" -lt "$end" ] && [ -e "$STATE/.secondmate-liveness-sm1.lock" ]; do
  printf "observed "; sed -n "s/^phase=/phase=/p" "$STATE/sm1.control-relaunch"
  secondmate_liveness_tick || exit 1
  sleep 0.1
 done
 echo "watcher tick exit=$?"
 if [ -e "$STATE/.secondmate-relaunch-sm1" ]; then cat "$STATE/.secondmate-relaunch-sm1"; else echo "attempt ledger absent"; fi
 echo "restart lock:"; cat "$STATE/.secondmate-liveness-sm1.lock"/pid 2>/dev/null || ls -ld "$STATE/.secondmate-liveness-sm1.lock"
' _ {R} > {E/(prefix+'-watcher.txt')} 2>&1''')
 assert until(lambda:watch.exists(),25)
 assert until(lambda:restart.exists(),45)
 assert until(lambda:winner.exists(),45)
 assert winner.read_text().strip()=='0',(E/(prefix+'-winner.txt')).read_text()
 verification_elapsed=(E/(prefix+'-restart.txt')).stat().st_mtime-(lab/'state'/'sm1.control-relaunch').stat().st_mtime
 (E/(prefix+'-results.json')).write_text(json.dumps({'verification_elapsed_seconds':verification_elapsed,'restart_exit':restart.read_text().strip(),'winner_exit':winner.read_text().strip(),'watcher_exit':watch.read_text().strip(),'verification_wait':8,'verification_poll':20,'lock_released':not (lab/'state'/'.secondmate-liveness-sm1.lock').exists(),'attempt_ledger_absent':not (lab/'state'/'.secondmate-relaunch-sm1').exists()},indent=2))
 p=cmd(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-sm1']);(E/(prefix+'-after.txt')).write_text(p.stdout)
 log.write((E/(prefix+'-results.json')).read_text()+'\n')
log.close()
