import json,os,subprocess,pathlib
root=pathlib.Path.cwd(); lab=root/'.l'; ev=pathlib.Path('~/.no-mistakes/evidence/01M5EFYR8TJSF6027SV80VBGR7')
state=lab/'state'; work=lab/'worktree'; hook=root/'bin/fm-codex-busy.sh'; writer=root/'bin/fm-busy-event.sh'
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']: env.pop(k,None)
gen=subprocess.check_output([str(writer),'arm',str(state),'guard'],text=True).strip()
env.update(FM_CODEX_BUSY_WORKTREE=str(work),FM_CODEX_BUSY_STATE=str(state),FM_CODEX_BUSY_ID='guard',FM_CODEX_BUSY_GEN=gen)
def apply(event,cwd=work,session='parent',extra=None):
 p=dict(cwd=str(cwd),hook_event_name=event,session_id=session)
 e=env.copy();e.update(extra or {})
 r=subprocess.run(['bash',str(hook)],input=json.dumps(p),text=True,capture_output=True,env=e,check=True)
 assert r.stdout=='{}\n',r
 return (state/'guard.busy-state').read_text()
def unchanged(label,**kw):
 before=(state/'guard.busy-state').read_text();after=apply(**kw); assert before==after,label
 print(label+': record unchanged; '+after.strip())
with (ev/'routing-guards.log').open('w') as f:
 import contextlib
 with contextlib.redirect_stdout(f):
  print('Oracle: only matching task cwd, submitted parent session, and current launch generation may change its busy state.')
  unchanged('Stop before first submitted session',event='Stop')
  busy=apply('UserPromptSubmit'); assert 'state=busy source=codex-hook' in busy
  print('Parent submit: '+busy.strip())
  unchanged('Nested session Stop cannot settle parent',event='Stop',session='nested')
  unchanged('Nested session submit cannot steal parent',event='UserPromptSubmit',session='nested')
  sibling=lab/'worktree-other';sibling.mkdir(exist_ok=True)
  unchanged('Sibling cwd prefix cannot settle task',event='Stop',cwd=sibling)
  unchanged('Unrelated cwd cannot settle task',event='SessionEnd',cwd=root)
  sub=work/'child';sub.mkdir(exist_ok=True)
  idle=apply('Stop',cwd=sub); assert 'state=idle source=codex-hook' in idle
  print('Descendant cwd accepted: '+idle.strip())
  new=subprocess.check_output([str(writer),'arm',str(state),'guard'],text=True).strip()
  unchanged('Old session submit cannot alter replacement generation',event='UserPromptSubmit')
  unchanged('Old session Stop cannot alter replacement generation',event='Stop')
  env['FM_CODEX_BUSY_GEN']=new
  unchanged('Unbound launch is inert',event='UserPromptSubmit',extra={'FM_CODEX_BUSY_ID':''})
  for raw in ['{}','invalid json',json.dumps(dict(cwd=str(work),hook_event_name='UserPromptSubmit',session_id='bad token'))]:
   before=(state/'guard.busy-state').read_text()
   r=subprocess.run(['bash',str(hook)],input=raw,text=True,capture_output=True,env=env,check=True)
   assert r.stdout=='{}\n' and before==(state/'guard.busy-state').read_text()
  print('Malformed/missing payload and invalid session token: harmless JSON, no record mutation')
