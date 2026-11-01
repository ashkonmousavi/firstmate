import os,pathlib,subprocess,time,json,shlex,re
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M6ABB3CG4YQMA6RX128VE4E6');p=json.loads((R/'.test-tmp/live-paths.json').read_text());lab=pathlib.Path(p['lab']);sm=pathlib.Path(p['sm'])
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') and k.endswith('_OVERRIDE') or k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TASK_ID']: env.pop(k,None)
env.update(FM_HOME=str(lab),FM_BACKEND='tmux',TMUX_TMPDIR=str(lab/'tmux'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
log=open(E/'live-hung-probe-driver.log','w',buffering=1)
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
import signal
cmd(['tmux','-L','fm-lab','set-environment','-t','primary','PATH',env['PATH']])
cmd(['tmux','-L','fm-lab','kill-window','-t','primary:fm-sm1'])
oldspawn=actor('oldspawn',f"{R}/bin/fm-spawn.sh sm1 {sm} --secondmate --harness 'codex --no-daemon --disable hooks --dangerously-bypass-approvals-and-sandbox' > {E/'live-hang-oldspawn.txt'} 2>&1")
assert until(lambda:oldspawn.exists(),30)
assert oldspawn.read_text().strip()=='0'
time.sleep(8)
server=cmd(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{pid} #{socket_path}'])
pid,socket=server.stdout.strip().split(' ',1)
assert socket.startswith(str(lab/'tmux')+'/')
(lab/'competitor-ready').unlink(missing_ok=True);(lab/'release-competitor').unlink(missing_ok=True)
winner=actor('competitor-hang',f'''STATE="$FM_HOME/state" bash -c '
 . "$1/bin/fm-wake-lib.sh"
 fm_lock_try_acquire "$STATE/.spawn-sm1.lock" || exit 1
 touch "$FM_HOME/competitor-ready"
 until [ -e "$FM_HOME/release-competitor" ]; do sleep .1; done
 fm_lock_release "$STATE/.spawn-sm1.lock"
' _ {R} > {E/'live-hang-competitor.txt'} 2>&1''')
assert until(lambda:(lab/'competitor-ready').exists(),10)
(lab/'state'/'sm1.control-relaunch').unlink(missing_ok=True)
oldcorr=set(x.name for x in (lab/'state'/'pending-replies').glob('*'))
restart=actor('hang-restart',f"FM_SECONDMATE_PERSIST_WAIT=30 FM_SECONDMATE_PERSIST_POLL=1 FM_SECONDMATE_RESTART_VERIFY_WAIT=3 FM_SECONDMATE_RESTART_VERIFY_POLL=1 {R}/bin/fm-secondmate-restart.sh sm1 > {E/'live-hung-probe-restart.txt'} 2>&1")
assert until(lambda:any(x.name not in oldcorr for x in (lab/'state'/'pending-replies').glob('*')),10)
corr=next(x.name for x in (lab/'state'/'pending-replies').glob('*') if x.name not in oldcorr and re.fullmatch('[a-f0-9]{16}',x.name))
old=env['FM_HOME'];env['FM_HOME']=str(sm);cmd([R/'bin/fm-secondmate-report.sh','done',corr,'Empty disposable fixture; no open work to persist.']);env['FM_HOME']=old
journal=lab/'state'/'sm1.control-relaunch'
assert until(lambda:journal.exists() and 'phase=failed:launching' in journal.read_text(),45)
start=time.monotonic();stopped=False
try:
 os.kill(int(pid),signal.SIGSTOP);stopped=True
 log.write('Suspended only verified private lab tmux server '+pid+' '+socket+'\n')
 assert until(lambda:restart.exists(),12),'restart exceeded its verification budget with suspended server'
 elapsed=time.monotonic()-start
 result={'restart_exit':restart.read_text().strip(),'verification_wait_seconds':3,'elapsed_since_transport_suspended_seconds':elapsed,'lock_released':not (lab/'state'/'.secondmate-liveness-sm1.lock').exists()}
 (E/'live-hung-probe-result.json').write_text(json.dumps(result,indent=2))
 assert result['restart_exit']=='3' and elapsed<5 and result['lock_released'],result
finally:
 if stopped:os.kill(int(pid),signal.SIGCONT);log.write('Resumed private lab tmux server\n')
 (lab/'release-competitor').touch()
assert until(lambda:winner.exists(),10)
log.write('competitor exit='+winner.read_text())
log.close()
