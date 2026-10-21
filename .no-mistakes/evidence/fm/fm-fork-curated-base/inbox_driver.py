from pathlib import Path
import subprocess,os
v=Path('.validation').absolute(); root=Path.cwd(); rh=v/'remote'; state=rh/'state/parent-route'; state.mkdir(parents=True,exist_ok=True); (rh/'bin').mkdir(exist_ok=True)
(rh/'AGENTS.md').write_text('# Disposable validation home\n'); (rh/'.fm-secondmate-home').write_text('lab\n')
(state/'lab.meta').write_text('window=fm-remote:p1\nworktree=-\nproject=-\nbackend=herdr\nendpoint_task_id=lab\nharness=claude\nherdr_session=fm-remote\nherdr_workspace_id=w1\nherdr_tab_id=t1\nherdr_pane_id=p1\n')
env=dict(os.environ,FM_HOME=str(v/'local'),FM_SSH_BIN=str(v/'ssh/ssh'))
for k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE'):env.pop(k,None)
def lib(script,*args):
 return subprocess.check_output(['bash','-c','. "$1"; shift; '+script,'inbox-lib',str(root/'bin/fm-task-inbox-lib.sh'),str(state),'lab',*args],env=env,text=True).strip()
def remote(*args):
 p=subprocess.run(['bin/fm-on.sh','lab','fm-remote-secondmate-control.sh','inbox','lab',*args],env=env,capture_output=True,text=True,timeout=45)
 assert p.returncode==0,p.stderr
 print('remote inbox '+' '.join(args)+' -> '+p.stdout.strip(),flush=True); return p.stdout.strip()
rec=lib('fm_task_inbox_write_idempotent "$1" "$2" "$3"','ordinary durable steer')
again=lib('fm_task_inbox_write_idempotent "$1" "$2" "$3"','ordinary durable steer'); assert again==rec
print('Idempotent enqueue persisted one exact record: '+Path(rec).read_text().strip(),flush=True)
assert remote('due','0','2')=='ring '+Path(rec).name
# Record two delivery-attempt outcomes through the library; no terminal or doorbell is faked.
for _ in range(2):lib('fm_task_inbox_record_ring "$1" "$2" "$3"',rec)
assert remote('due','0','2')=='escalate '+Path(rec).name+' 2'
assert remote('escalated',Path(rec).name)=='escalated'; assert remote('due','0','2')=='quiet'
handled=Path(rec).parent/'handled'; handled.mkdir(exist_ok=True); Path(rec).rename(handled/Path(rec).name)
assert remote('due','0','2')=='quiet'
ff=lib('fm_task_inbox_write_idempotent "$1" "$2" "$3" fire-and-forget','one-shot steer')
assert remote('due','0','2')=='quiet'
print('PASS: real SSH remote inbox protocol returned ring/escalate/quiet, deduplicated enqueue, and excluded handled and fire-and-forget records. Physical doorbell delivery was not exercised.',flush=True)
