import os,pathlib,subprocess,time,json,shlex,re
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M6ABB3CG4YQMA6RX128VE4E6');p=json.loads((R/'.test-tmp/live-paths.json').read_text());lab=pathlib.Path(p['lab']);sm=pathlib.Path(p['sm'])
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') and k.endswith('_OVERRIDE') or k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TASK_ID']: env.pop(k,None)
env.update(FM_HOME=str(lab),FM_BACKEND='tmux',TMUX_TMPDIR=str(lab/'tmux'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
log=open(E/'live-busy-recovery-driver.log','w',buffering=1)
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
(lab/'busy-lock-ready').unlink(missing_ok=True);(lab/'release-busy-lock').unlink(missing_ok=True)
before=(lab/'state'/'sm1.meta').read_text()
lock=actor('busy-recovery',f'''STATE="$FM_HOME/state" bash -c '
 . "$1/bin/fm-wake-lib.sh"
 fm_lock_try_acquire "$STATE/.secondmate-liveness-sm1.lock" || exit 1
 touch "$FM_HOME/busy-lock-ready"
 until [ -e "$FM_HOME/release-busy-lock" ]; do sleep .1; done
 fm_lock_release "$STATE/.secondmate-liveness-sm1.lock"
' _ {R}''')
assert until(lambda:(lab/'busy-lock-ready').exists(),5)
oldcorr=set(x.name for x in (lab/'state'/'pending-replies').glob('*'))
restart=actor('busy-restart',f"FM_SECONDMATE_PERSIST_WAIT=10 FM_SECONDMATE_PERSIST_POLL=1 FM_SECONDMATE_RESTART_LOCK_WAIT=1 {R}/bin/fm-secondmate-restart.sh sm1 > {E/'live-busy-recovery-restart.txt'} 2>&1")
try:
 assert until(lambda:any(x.name not in oldcorr for x in (lab/'state'/'pending-replies').glob('*')),5)
 corr=next(x.name for x in (lab/'state'/'pending-replies').glob('*') if x.name not in oldcorr and re.fullmatch('[a-f0-9]{16}',x.name))
 old=env['FM_HOME'];env['FM_HOME']=str(sm);cmd([R/'bin/fm-secondmate-report.sh','done',corr,'Empty validation fixture; no open work.']);env['FM_HOME']=old
 assert until(lambda:restart.exists(),10)
 result={'restart_exit':restart.read_text().strip(),'metadata_unchanged':before==(lab/'state'/'sm1.meta').read_text()}
 (E/'live-busy-recovery-result.json').write_text(json.dumps(result,indent=2))
 assert result['restart_exit']=='3' and result['metadata_unchanged'],result
 p=cmd(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-sm1']);(E/'live-auto-ready.txt').write_text(p.stdout)
finally:
 (lab/'release-busy-lock').touch()
assert until(lambda:lock.exists(),5)
log.close()
