import os, pathlib, subprocess, json, ssl, socketserver, threading, http.server, time, datetime, shutil
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M5H8ZXZRA1N26RZ4DE5CK27Q'); W=ROOT/'.live-test-tmp/manual'; W.mkdir(parents=True,exist_ok=True)
def run(args,env=None,cwd=None,check=True):
 p=subprocess.run(args,cwd=cwd or ROOT,env=env or ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 if check and p.returncode: raise RuntimeError(f'{args}: {p.returncode}: {p.stderr}')
 return p
ENV=os.environ.copy()
for k in list(ENV):
 if k.startswith('FM_') or k in ['GH_TOKEN','GITHUB_TOKEN','GITHUB_ENTERPRISE_TOKEN','GH_ENTERPRISE_TOKEN','TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND']: ENV.pop(k,None)
ENV.update(GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',TMPDIR=str(W),GH_CONFIG_DIR=str(W/'gh'),GH_TOKEN='local-fixture-only',GH_PROMPT_DISABLED='1')
subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(W/'key'),'-out',str(W/'cert'),'-days','1','-subj','/CN=api.github.com','-addext','subjectAltName=DNS:api.github.com,DNS:github.com'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(W/'cert',W/'key')
state={'prstate':'OPEN','present':True,'age':1200,'fail':False,'prs':[],'files':{}}
log=[]; reports=[]
class API(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def do_GET(self): self.answer(None)
 def do_POST(self): self.answer(json.loads(self.rfile.read(int(self.headers.get('Content-Length',0)))))
 def answer(self,body):
  log.append({'path':self.path,'body':body})
  q=(body or {}).get('query',''); variables=(body or {}).get('variables',{})
  code=200
  if '/files' in self.path:
   n=self.path.split('/pulls/')[1].split('/')[0]
   if n not in state['files']: code=503; data={'message':'disposable file lookup unavailable'}
   else: data=state['files'][n]
  elif 'timelineItems' in q:
   if state['fail']: code=503; data={'message':'disposable label lookup unavailable'}
   else:
    page=variables.get('endCursor'); first=not page
    at=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=state['age'])).strftime('%Y-%m-%dT%H:%M:%SZ') if not state.get('at') else state['at']
    nodes=[{'__typename':'LabeledEvent','createdAt':at,'label':{'name':'conflict'}}] if first else []
    data={'data':{'repository':{'pullRequest':{'labels':{'nodes':[{'name':'conflict'}] if state['present'] else []},'timelineItems':{'pageInfo':{'hasNextPage':first,'endCursor':'page2' if first else None},'nodes':nodes}}}}}
  elif 'pullRequests(' in q:
   data={'data':{'repository':{'pullRequests':{'nodes':state['prs'],'pageInfo':{'hasNextPage':False,'endCursor':None}}}}}
  elif 'pullRequest(' in q: data={'data':{'repository':{'pullRequest':{'state':state['prstate']}}}}
  else: data={'data':{'repository':{'id':'local','name':'r','owner':{'login':'o'},'nameWithOwner':'o/r','isPrivate':False,'defaultBranchRef':{'name':'main'}}}}
  b=json.dumps(data).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b))); self.send_header('Connection','close'); self.end_headers(); self.wfile.write(b)
class Proxy(socketserver.BaseRequestHandler):
 def handle(self):
  f=self.request.makefile('rb'); line=f.readline()
  if not line: return
  while f.readline().strip(): pass
  self.request.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
  try:
   with context.wrap_socket(self.request,server_side=True) as s: API(s,self.client_address,self.server)
  except (ssl.SSLError,ConnectionError): pass
server=socketserver.ThreadingTCPServer(('127.0.0.1',0),Proxy); threading.Thread(target=server.serve_forever,daemon=True).start()
ENV.update(HTTPS_PROXY=f'http://127.0.0.1:{server.server_address[1]}',HTTP_PROXY=f'http://127.0.0.1:{server.server_address[1]}',NO_PROXY='',SSL_CERT_FILE=str(W/'cert'))
def poll(): return run(['bin/fm-pr-poll.sh','--validated','github','https://github.com/o/r/pull/7','github.com','o/r','7'],check=False)
def record(title,p):
 reports.append(f'### {title}\nexit: {p.returncode}\nstdout:\n{p.stdout}\nstderr:\n{p.stderr}\n')
lab=ROOT/'.l'; env=ENV.copy(); env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'tmux'),FM_BACKEND='tmux',FM_CHECK_INTERVAL='0',FM_POLL='0.05',FM_HEARTBEAT='999999',FM_SIGNAL_GRACE='0')
socket=run(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path}'],env=env).stdout.strip(); env['TMUX']=socket+',1,0'
state['at']='2026-01-01T00:00:00Z'
try:
 for mode in ['legacy-fallback','legacy-merged','closed','secondmate','current-failure','legacy-failure']:
  home=W/('watch-'+mode); shutil.rmtree(home,ignore_errors=True); run(['bin/fm-lab-home.sh','create',str(home)])
  ev=env.copy(); ev['FM_HOME']=str(home)
  meta='base_branch=main\n'
  if mode=='secondmate': meta+='kind=secondmate\nwindow=primary:fm-lane\nharness=claude\n'
  (home/'state/lane.meta').write_text(meta+'pr=https://github.com/o/r/pull/7\n')
  template='tests/fixtures/fm-pr-poll-v1.sh' if mode.startswith('legacy') or mode=='secondmate' else 'bin/fm-pr-poll.sh'
  arm2='source bin/fm-pr-lib.sh\nfm_pr_poll_prepare "$FM_HOME/state" lane github https://github.com/o/r/pull/7 github.com o/r 7 '+template+' && fm_pr_poll_publish_prepared'
  run(['bash','-c',arm2],env=ev)
  state['prstate']='CLOSED' if mode=='closed' else ('MERGED' if mode=='legacy-merged' else 'OPEN'); state['fail']=mode.endswith('failure')
  o=open(home/'out','w'); e=open(home/'err','w'); proc=subprocess.Popen(['bash','bin/fm-watch.sh'],env=ev,stdout=o,stderr=e,cwd=ROOT)
  try:
   for _ in range(160):
    if proc.poll() is not None or (home/'state/.last-check').exists(): break
    time.sleep(.1)
   rc=proc.poll()
   if rc is None: proc.terminate(); proc.wait(timeout=10)
  finally:
   if proc.poll() is None: proc.kill(); proc.wait()
   o.close(); e.close()
  queue=(home/'state/.wake-queue').read_text() if (home/'state/.wake-queue').exists() else ''
  reports.append(f'### Watcher {mode}\nexit before stop: {rc}\nstdout:\n'+(home/'out').read_text()+'\nstderr:\n'+(home/'err').read_text()+'\nnotifications:\n'+queue)
  if mode=='legacy-fallback':
   assert 'conflict' in queue and (home/'state/lane.pr-conflict-episode').exists()
   assert (home/'state/lane.check.sh').read_bytes()==(ROOT/'bin/fm-pr-poll.sh').read_bytes()
  elif mode=='legacy-merged': assert 'merged' in queue and not (home/'state/lane.check.sh').exists()
  elif mode.endswith('failure'): assert rc and not queue and not (home/'state/lane.pr-conflict-episode').exists()
  else: assert (home/'state/.last-check').exists() and not queue and not (home/'state/lane.inbox').exists() and not (home/'state/lane.pr-conflict-episode').exists()
finally:
 server.shutdown(); server.server_close(); (E/'boundary-transcript.md').write_text('\n'.join(reports)); (E/'boundary-api-requests.json').write_text(json.dumps(log,indent=2))
print('Live watcher boundary scenarios passed.')
