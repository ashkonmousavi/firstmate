import os,pathlib,subprocess,time,json,shlex,re
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M6ABB3CG4YQMA6RX128VE4E6');p=json.loads((R/'.test-tmp/live-paths.json').read_text());lab=pathlib.Path(p['lab']);sm=pathlib.Path(p['sm'])
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') and k.endswith('_OVERRIDE') or k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TASK_ID']: env.pop(k,None)
env.update(FM_HOME=str(lab),FM_BACKEND='tmux',TMUX_TMPDIR=str(lab/'tmux'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
log=open(E/'live-success-and-stale.log','w',buffering=1)
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
cmd(['tmux','-L','fm-lab','set-environment','-t','primary','PATH',env['PATH']])
cmd(['tmux','-L','fm-lab','kill-window','-t','primary:fm-sm1'])
oldspawn=actor('oldspawn',f"{R}/bin/fm-spawn.sh sm1 {sm} --secondmate --harness 'codex --no-daemon --disable hooks --dangerously-bypass-approvals-and-sandbox' > {E/'live-success-oldspawn.txt'} 2>&1")
assert until(lambda:oldspawn.exists(),30)
assert oldspawn.read_text().strip()=='0'
time.sleep(8)
(lab/'config'/'secondmate-harness').write_text('cursor auto\n')
oldcorr=set(x.name for x in (lab/'state'/'pending-replies').glob('*'))
restart=actor('normal-restart',f"FM_SECONDMATE_PERSIST_WAIT=30 FM_SECONDMATE_PERSIST_POLL=1 {R}/bin/fm-secondmate-restart.sh sm1 > {E/'live-success-restart.txt'} 2>&1")
assert until(lambda:any(x.name not in oldcorr for x in (lab/'state'/'pending-replies').glob('*')),10)
corr=next(x.name for x in (lab/'state'/'pending-replies').glob('*') if x.name not in oldcorr and re.fullmatch('[a-f0-9]{16}',x.name))
old=env['FM_HOME'];env['FM_HOME']=str(sm);cmd([R/'bin/fm-secondmate-report.sh','done',corr,'No open work in isolated validation fixture.']);env['FM_HOME']=old
assert until(lambda:restart.exists(),100)
(E/'live-success-result.json').write_text(json.dumps({'restart_exit':restart.read_text().strip(),'lock_released':not (lab/'state'/'.secondmate-liveness-sm1.lock').exists()},indent=2))
p=cmd(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-sm1']);(E/'live-success-after.txt').write_text(p.stdout)
stale=actor('dead-marker',f'''STATE="$FM_HOME/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$STATE/.secondmate-liveness-sm1.lock"' _ {R} > {E/'live-stale-marker-create.txt'} 2>&1''')
assert until(lambda:stale.exists(),10)
assert stale.read_text().strip()=='0'
assert (lab/'state'/'.secondmate-liveness-sm1.lock').exists()
watch=actor('stale-watch',f'''bash -c '
 . "$1/bin/fm-watch.sh"
 SECONDMATE_LIVENESS_SECS=0
 secondmate_liveness_tick
 echo "watcher tick exit=$?"
 fm_secondmate_liveness_probe "$STATE/sm1.meta" sm1 poll
 echo "probe=$FM_SM_LIVE_STATUS state=$FM_SM_LIVE_STATE"
 if [ -e "$STATE/.secondmate-liveness-sm1.lock" ]; then echo "lock remains"; else echo "abandoned lock reclaimed and released"; fi
 if [ -e "$STATE/.secondmate-relaunch-sm1" ]; then cat "$STATE/.secondmate-relaunch-sm1"; else echo "attempt ledger absent"; fi
' _ {R} > {E/'live-stale-marker-recovery.txt'} 2>&1''')
assert until(lambda:watch.exists(),20)
log.write('normal restart exit='+restart.read_text()+'stale watcher exit='+watch.read_text())

# Capture actual model response or quota/login outcome after the launch settles.
for i in range(15):
 time.sleep(2)
 p=cmd(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-sm1'])
 (E/'live-success-ready.txt').write_text(p.stdout)
 if 'out of usage' in p.stdout or 'Ready' in p.stdout or 'ready and' in p.stdout: break
log.close()

