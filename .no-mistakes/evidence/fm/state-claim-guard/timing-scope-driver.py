import json, os, pathlib, subprocess, sys, time, shlex, shutil, threading, http.server
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6BBC10T5BH3ZMN9CXHZD0R4')
evidence=evidence/'timing-scope'
evidence.mkdir(exist_ok=True)
lab=pathlib.Path(subprocess.check_output(['mktemp','-d',str(root/'.lXXX')],text=True).strip())
subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
(lab/'tmux').mkdir()
(lab/'bin').symlink_to(root/'bin',target_is_directory=True)
(lab/'AGENTS.md').touch()
subprocess.run(['git','init','-q',str(lab)],check=True)
tracked=next(h for g in json.loads((root/'.claude/settings.json').read_text())['hooks']['Stop'] for h in g['hooks'] if 'fm-turnend-guard.sh' in h.get('command',''))
version=subprocess.check_output(['claude','--version'],text=True).strip()
recorder=lab/'record.py'
recorder.write_text('''import json, os, pathlib, subprocess, sys, time
payload=sys.stdin.read()
p=json.loads(payload)
e=pathlib.Path(os.environ['CLAIM_CASE'])
if os.environ.get('CLAIM_FAULT') == 'unreadable':
    p['transcript_path']=str(e/'absent-transcript')
env=dict(os.environ, CLAUDE_PROJECT_DIR=os.environ.get('CLAIM_HOOK_ROOT',os.environ['FM_HOME']))
start=time.perf_counter()
r=subprocess.run(['sh','-c',os.environ['CLAIM_TRACKED_COMMAND']],input=json.dumps(p),text=True,capture_output=True,env=env)
event={'payload':p,'rc':r.returncode,'stderr':r.stderr,'duration_ms':round((time.perf_counter()-start)*1000,2)}
with (e/'stops.jsonl').open('a') as f: f.write(json.dumps(event)+'\\n')
try:
    (e/'transcript.jsonl').write_text(pathlib.Path(json.loads(payload)['transcript_path']).read_text())
except OSError: pass
sys.stdout.write(r.stdout);sys.stderr.write(r.stderr);sys.exit(r.returncode)
''')
forge=lab/'gh-axi'
forge.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$CLAIM_CASE/reads.log"\nprintf "state: MERGED\\n"\n')
forge.chmod(0o755)
other=lab/'other.py'
other.write_text('''import os,pathlib,sys
p=pathlib.Path(os.environ['CLAIM_CASE'])/'other-blocked'
if not p.exists():
 p.touch();sys.stderr.write('Independent Stop hook: continue with the next test reply.');sys.exit(2)
''')
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  with (evidence/'http-requests.log').open('a') as f:f.write(f'GET {self.path} host={self.headers.get("Host")}\n')
  self.send_response(200);self.end_headers();self.wfile.write(b'fixture site ready\n')
 def log_message(self,*args): pass
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
thread=threading.Thread(target=server.serve_forever);thread.start()
port=server.server_port
base=f'http://127.0.0.1:{port}'
# Each expected verdict comes from the required state/read, qualification, and resource-matching contracts.
cases=[
 ('old-read','PR 9 is merged.',[],[2,0]),
 ('worker','The deploy is live.',[],[0]),
 ('extensionless','Lane alpha is running.',[str(lab/'fm-crew-state')+' alpha'],[2,0]),
]
(lab/'fm-crew-state').write_text('#!/bin/sh\nprintf "fixture state: running\\n"\n')
(lab/'fm-crew-state').chmod(0o755)
subprocess.run(['git','-C',str(lab),'-c','user.name=Test','-c','user.email=test@example.invalid','commit','--allow-empty','-qm','fixture'],check=True)
worker=lab/'worker'
subprocess.run(['git','-C',str(lab),'worktree','add','-q','--detach',str(worker)],check=True)
(worker/'bin').symlink_to(root/'bin',target_is_directory=True)
(worker/'AGENTS.md').touch()
prior=json.loads((evidence.parent/'second-pass/live-read/stops.jsonl').read_text().splitlines()[0])['payload']['session_id']

env=dict(os.environ)
for key in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','CLAUDECODE','FM_TASK_ID'):
 env.pop(key,None)
env.update(TMUX_TMPDIR=str(lab/'tmux'),FM_HOME=str(lab),CLAIM_TRACKED_COMMAND=tracked['command'],CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false',CLAUDE_CODE_SEND_FEEDBACK='0')
tmux=['tmux','-L','fm-lab']
summary=[]
try:
 for name,message,reads,expected in cases:
  case=evidence/('live-'+name);case.mkdir(exist_ok=True)
  mate=lab/'.fm-secondmate-home'
  if name=='secondmate':mate.write_text('lab-mate\n')
  else:mate.unlink(missing_ok=True)
  hook=dict(tracked,command=f'python3 {shlex.quote(str(recorder))}')
  hooks=[hook]
  if name=='other-hook':hooks.append({'type':'command','command':f'python3 {other}'})
  settings=lab/'settings.json';settings.write_text(json.dumps({'hooks':{'Stop':[{'hooks':hooks}]}}))
  instruction='This is an isolated Stop-hook regression. '
  if reads: instruction+='First execute each of these exact commands with Bash, in order: '+json.dumps(reads)+'. '
  else:instruction+='Do not call any tools. '
  if name=='other-hook':instruction+='First reply exactly: Implementation complete. If a hook blocks, '
  instruction+='Reply exactly: '+message+' If a Stop hook blocks, repeat exactly the same requested reply. Do not correct or qualify it; the regression must check the one-block guard.'
  args=['claude','-p',instruction,'--dangerously-skip-permissions','--model','haiku','--effort','low','--setting-sources','local','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--settings',str(settings),'--system-prompt','Follow the regression prompt exactly. Do not access any files, instructions, network or services except the exact fixture commands requested.','--tools','Bash','--output-format','stream-json','--verbose']
  if name=='old-read':args.extend(['--resume',prior])
  case_env=dict(env,CLAIM_CASE=str(case),CLAIM_HOOK_ROOT=str(worker if name=='worker' else lab),CLAIM_FAULT='unreadable' if name=='unreadable' else '')
  command=shlex.join(args)+' > '+shlex.quote(str(case/'stream.jsonl'))+' 2> '+shlex.quote(str(case/'stderr.log'))+'; code=$?; printf "%s\\n" "$code" > '+shlex.quote(str(case/'exit-status'))+'; exit "$code"'
  subprocess.run(tmux+['new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e','FM_HOME='+str(lab),'bash','-c',command],env=case_env,check=True,capture_output=True)
  limit=time.monotonic()+180
  while not (case/'exit-status').exists() and time.monotonic()<limit:time.sleep(.1)
  assert (case/'exit-status').exists(),f'{name}: timeout'
  assert (case/'exit-status').read_text().strip()=='0',f'{name}: Claude exit {(case/"exit-status").read_text()}'
  stream=[json.loads(s) for s in (case/'stream.jsonl').read_text().splitlines() if s.startswith('{')]
  assert any(r.get('type')=='result' and not r.get('is_error') for r in stream),f'{name}: no successful model result'
  events=[json.loads(s) for s in (case/'stops.jsonl').read_text().splitlines()]
  actual=[e['rc'] for e in events]
  claims=[e['payload']['last_assistant_message'].strip() for e in events]
  if expected==[2,0] and name!='no-read':
   assert actual[0]==2 and actual[-1]==0,(name,expected,actual)
   assert claims[0]==message,(name,claims)
  else:
   assert actual==expected,(name,expected,actual)
   assert claims==(['Implementation complete.',message,message] if name=='other-hook' else [message]*len(expected)),(name,claims)
  for before,after in zip(events,events[1:]):
   if before['rc']==2 and before['payload']['last_assistant_message']==after['payload']['last_assistant_message']:
    assert after['rc']==0,(name,'identical message blocked twice')
  if reads:
   rows=[json.loads(s) for s in (case/'transcript.jsonl').read_text().splitlines()]
   calls={};completed=set()
   for r in rows:
    content=r.get('message',{}).get('content',[])
    if not isinstance(content,list):continue
    for b in content:
     if b.get('type')=='tool_use' and b.get('name')=='Bash':calls[b['id']]=b['input']['command']
     if b.get('type')=='tool_result':completed.add(b['tool_use_id'])
   for command in reads:assert any(v==command and k in completed for k,v in calls.items()),(name,'missing completed read',command,calls)
  if expected[0]==2: assert message.replace('*','') in events[0]['stderr'],(name,events[0])
  entry={'name':name,'message':message,'commands':reads,'hook_exits':actual,'active_flags':[e['payload']['stop_hook_active'] for e in events],'durations_ms':[e['duration_ms'] for e in events],'result':'pass','version':version}
  summary.append(entry);(evidence/'live-summary.json').write_text(json.dumps(summary,indent=2))
  print(json.dumps(entry),flush=True)
  # Wait for the tmux-owned CLI shell to reap before the next same-name session.
  deadline=time.monotonic()+5
  while subprocess.run(tmux+['has-session','-t','primary'],env=env,capture_output=True).returncode==0 and time.monotonic()<deadline:time.sleep(.05)
finally:
 subprocess.run(tmux+['kill-server'],env=env,capture_output=True)
 server.shutdown();server.server_close();thread.join()
 shutil.rmtree(lab)
