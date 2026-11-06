import os,sys,json,subprocess,time,pathlib,threading,http.server,shlex,hashlib,shutil
R=pathlib.Path.cwd(); L=R/'.l'; E=pathlib.Path('~/.no-mistakes/evidence/01M6Q77424A407CBW237T5PJ6A')
requests=[]
class API(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def do_GET(self):
  body=b'{"data": []}'; self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(body)
 def do_POST(self):
  self.rfile.read(int(self.headers.get('Content-Length','0'))); requests.append(self.path)
  self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
  def event(t,**d):
   self.wfile.write(('event: '+t+'\ndata: '+json.dumps({'type':t,**d})+'\n\n').encode()); self.wfile.flush()
  try:
   response={'id':'resp_lab','object':'response','status':'in_progress','output':[]}
   event('response.created',response=response); time.sleep(8)
   item={'id':'msg_lab','type':'message','role':'assistant','status':'completed','content':[{'type':'output_text','text':'lane-profile-lab-ok','annotations':[]}]}
   event('response.output_item.added',output_index=0,item={**item,'status':'in_progress','content':[]})
   event('response.content_part.added',item_id='msg_lab',output_index=0,content_index=0,part={'type':'output_text','text':'','annotations':[]})
   event('response.output_text.delta',item_id='msg_lab',output_index=0,content_index=0,delta='lane-profile-lab-ok')
   event('response.output_text.done',item_id='msg_lab',output_index=0,content_index=0,text='lane-profile-lab-ok')
   event('response.output_item.done',output_index=0,item=item)
   event('response.completed',response={**response,'status':'completed','output':[item],'usage':{'input_tokens':20,'output_tokens':8,'total_tokens':28}})
  except (BrokenPipeError,ConnectionResetError): pass
api=http.server.ThreadingHTTPServer(('127.0.0.1',0),API); threading.Thread(target=api.serve_forever,daemon=True).start()
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','GIT_CONFIG_','CODEX_','OPENAI_','ANTHROPIC_')) and k not in ['TMUX','CLAUDE_CONFIG_DIR','CLAUDECODE','GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','NO_MISTAKES_GATE']}
env.update(FM_HOME=str(L), HOME=str(L/'user'), CODEX_HOME=str(L/'user/.codex'), TMUX_TMPDIR=str(L/'tmux'), TREEHOUSE_ROOT=str(L/'pool'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', SHELL='/bin/bash', NO_MISTAKES_NO_UPDATE_CHECK='1', DISABLE_AUTOUPDATER='1', FM_SPAWN_NO_GUARD='1')
def run(args,check=True,timeout=200):
 p=subprocess.run([str(a) for a in args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 print('$ '+shlex.join([str(a) for a in args])+'\n'+p.stdout+'exit='+str(p.returncode),flush=True)
 if check and p.returncode: raise RuntimeError(str(args))
 return p
def codex_pids(target):
 pane=int(run(['tmux','-L','fm-lab','display-message','-p','-t',target,'#{pane_pid}']).stdout.strip())
 rows=[line.split(None,2) for line in subprocess.check_output(['ps','-eo','pid=,ppid=,args='],text=True).splitlines()]
 children={pane}
 for _ in range(12):
  children.update(int(pid) for pid,parent,args in rows if int(parent) in children)
 return {int(pid) for pid,parent,args in rows if int(pid) in children and '/codex' in args}
try:
 run(['bin/fm-lab-home.sh','create',L]); (L/'user/.codex').mkdir(parents=True); (L/'tmux').mkdir(); (L/'project').mkdir()
 config=['check_for_update_on_startup=false','model="gpt-5.4"','model_provider="lab"','cli_auth_credentials_store="file"','[features]','plugins=false','apps=false','[model_providers.lab]','name="Lab"',f'base_url="http://127.0.0.1:{api.server_port}/v1"','wire_api="responses"','requires_openai_auth=false']
 for name in ['gitnexus','claude-context','retained']:
  config += [f'[mcp_servers."{name}"]',f'command={json.dumps(sys.executable)}',f'args={json.dumps([str(R/"tests/lane-profile-native.py"),"mcp",name,str(L/(name+".pid"))])}']
 (L/'user/.codex/config.toml').write_text('\n'.join(config)+'\n'); (L/'user/.codex/AGENTS.md').write_text('')
 (L/'config/crew-harness').write_text('codex\n'); (L/'config/lane-capacity').write_text('10 0\n'); (L/'config/machine-admission.json').write_text(json.dumps({'schema':'fm-machine-admission.v1','memory_floor_gib':0,'memory_full_avg60_max':100,'disk_floor_gib':0,'disk_paths':[str(L)]}))
 activity=L/'user/.config/skills-master/.agents/skills/activity/activity.sh'
 activity.parent.mkdir(parents=True)
 activity.write_text("#!/usr/bin/env bash\nprintf '%s\\n' '{\"readable\":true,\"lanes\":0,\"target\":10,\"free_lanes\":10}'\n")
 activity.chmod(0o755)
 run(['git','-C',L/'project','init','-q']); (L/'project/README.md').write_text('# Disposable lane test\n'); run(['git','-C',L/'project','add','.']); run(['git','-C',L/'project','-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','initial']); run(['git','clone','--quiet','--bare',L/'project',L/'origin.git']); run(['git','-C',L/'project','remote','add','origin',L/'origin.git'])
 run(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','lab','-x','160','-y','45','-c',str(R),'bash --noprofile --norc'])
 run(['tmux','-L','fm-lab','set-option','-g','default-shell','/bin/bash']); run(['tmux','-L','fm-lab','set-option','-g','default-command','bash --noprofile --norc'])
 env['TMUX']=run(['tmux','-L','fm-lab','display-message','-p','-t','lab','#{socket_path},#{pid},#{session_id}']).stdout.strip().replace(',$',',')
 for args,reason in [(['--scout','--lane-profile','typo'],'unknown --lane-profile'),(['--scout','--lane-profile',''],'unknown --lane-profile'),(['--secondmate','--lane-profile','governance'],'requires a canonical Codex ship/scout'),(['codex --model custom','--scout','--lane-profile','governance'],'requires a canonical Codex ship/scout')]:
  p=run(['bin/fm-spawn.sh','refusal',L/'project',*args],check=False)
  assert p.returncode!=0 and reason in p.stdout
  assert not (L/'state/refusal.meta').exists()
 for profile in ['governance','ci-tooling','product-code','selected-account']:
  id='live-'+profile; d=L/'data'/id; d.mkdir(parents=True); (d/'brief.md').write_text('# Task\n## Captain\'s intent\nReply with lane-profile-lab-ok.\n\n## Firstmate spec\nNo tools and no file changes.\n')
  if profile=='selected-account':
   selected=L/'account'; selected.mkdir()
   shutil.copyfile(L/'user/.codex/config.toml',selected/'config.toml')
   (selected/'auth.json').write_text('{"OPENAI_API_KEY":"sk-lab-synthetic-never-remote"}')
   (selected/'AGENTS.md').write_text('')
   (selected/'rules').mkdir()
   (selected/'rules/default.rules').write_text('prefix_rule(pattern=["echo"], decision="allow")\n')
   (L/'config/codex-accounts').write_text(str(selected)+'\n')
   (L/'config/launch-env-allowlist').touch()
  chosen='governance' if profile=='selected-account' else profile
  for marker in L.glob('*.pid'): marker.unlink()
  p=run(['bin/fm-spawn.sh',id,L/'project','--scout','--backend','tmux','--lane-profile',chosen],check=False)
  (E/(id+'-spawn.log')).write_text(p.stdout)
  meta=L/'state'/(id+'.meta')
  if not meta.exists():
   run(['tmux','-L','fm-lab','capture-pane','-p','-t','lab:fm-'+id,'-S','-120'],check=False); raise RuntimeError('spawn did not publish '+id)
  data=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line); target=data['window']
  screen=run(['tmux','-L','fm-lab','capture-pane','-p','-t',target,'-S','-160']).stdout; (E/(id+'-screen.txt')).write_text(screen)
  observed={f.stem for f in L.glob('*.pid') if any(subprocess.run(['kill','-0',v],capture_output=True).returncode==0 for v in f.read_text().splitlines())}
  expected={'gitnexus','claude-context','retained'} if chosen=='product-code' else {'retained'}
  print(json.dumps({'profile':profile,'spawn_exit':p.returncode,'metadata_profile':data.get('lane_profile'),'observed_mcp':sorted(observed),'expected':sorted(expected)}),flush=True)
  assert p.returncode==0 and observed==expected and data['lane_profile']==chosen
  (E/(id+'-metadata.txt')).write_text(meta.read_text())
  if profile=='governance':
   original=meta.read_bytes()
   original_pids=codex_pids(target)
   assert original_pids
   for bad in ['harness','filtered','corrupt']:
    if bad=='filtered': (L/'config/launch-env-allowlist').touch()
    if bad=='corrupt': meta.write_text(original.decode().replace('lane_profile=governance','lane_profile=typo'))
    before=meta.read_bytes()
    refusal=run(['bin/fm-control.sh',id,'relaunch',*(['--harness','claude'] if bad=='harness' else [])],check=False)
    reason={'harness':'requires a canonical Codex ship/scout','filtered':'cannot establish the worker configuration','corrupt':'unknown --lane-profile'}[bad]
    assert refusal.returncode!=0 and reason in refusal.stdout
    assert meta.read_bytes()==before
    assert codex_pids(target)==original_pids
    print('refusal '+bad+': metadata unchanged; original Codex PIDs alive '+str(sorted(original_pids)),flush=True)
    if bad=='filtered': (L/'config/launch-env-allowlist').unlink()
    if bad=='corrupt': meta.write_bytes(original)
   for marker in L.glob('*.pid'): marker.unlink()
   relaunch=run(['bin/fm-control.sh',id,'relaunch','--note','Retain governance MCP startup; no previous work to recover.'])
   assert 'lane_profile=governance' in meta.read_text()
   assert {f.stem for f in L.glob('*.pid')}=={'retained'}
   (E/'governance-relaunch-screen.txt').write_text(run(['tmux','-L','fm-lab','capture-pane','-p','-t',target,'-S','-80']).stdout)
  if profile=='selected-account':
   assert 'account='+str(L/'account') in meta.read_text()
   print('selected-account exported root confirmed in metadata',flush=True)
  run(['bin/fm-control.sh',id,'exit'],check=False)
 print('API paths '+json.dumps(requests),flush=True)
finally:
 subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,capture_output=True)
 api.shutdown(); api.server_close()
 print('private tmux stopped; API stopped',flush=True)
