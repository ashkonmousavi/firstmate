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



import re
home=W/'episode-home'; shutil.rmtree(home,ignore_errors=True); run(['bin/fm-lab-home.sh','create',str(home)]); ev=env.copy(); ev['FM_HOME']=str(home)
(home/'state/lane.meta').write_text('base_branch=main\npr=https://github.com/o/r/pull/7\n')
run(['bash','-c','source bin/fm-pr-lib.sh; fm_pr_poll_prepare "$FM_HOME/state" lane github https://github.com/o/r/pull/7 github.com o/r 7 bin/fm-pr-poll.sh && fm_pr_poll_publish_prepared'],env=ev)
def cycle(label):
 (home/'state/.last-check').unlink(missing_ok=True)
 o=open(home/'out','w'); e=open(home/'err','w'); proc=subprocess.Popen(['bash','bin/fm-watch.sh'],env=ev,stdout=o,stderr=e,cwd=ROOT)
 try:
  for _ in range(200):
   if (home/'state/.last-check').exists() or proc.poll() is not None: break
   time.sleep(.1)
  assert (home/'state/.last-check').exists(),label
 finally:
  proc.terminate()
  try: proc.wait(timeout=10)
  except subprocess.TimeoutExpired: proc.kill(); proc.wait()
  o.close(); e.close()
 q=home/'state/.wake-queue'; queue=q.read_text() if q.exists() else ''
 reports.append('### '+label+'\n'+(home/'out').read_text()+'\n'+(home/'err').read_text()+'\nNotifications:\n'+queue)
 seq=(home/'state/.wake-queue.seq').read_text().strip()
 d=run(['bin/fm-wake-drain.sh'],env=ev,check=False); reports.append('Drain:\n'+d.stdout+'\n'+d.stderr)
 m=re.search(r'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',d.stdout+d.stderr)
 assert m,'no acknowledgement contract'
 a=run(['bin/fm-wake-drain.sh','--ack-through',m[1],'--recovery-generation',m[2]],env=ev,check=False); reports.append('Acknowledgement:\n'+a.stdout+'\n'+a.stderr); assert a.returncode==0
 return int(seq)
try:
 assert cycle('First aged label opens one notification')==1
 assert cycle('Same label application stays quiet')==1
 state['present']=False; assert cycle('Clear removes episode without another notification')==1; assert not (home/'state/lane.pr-conflict-episode').exists()
 state['present']=True; state['at']='2026-01-02T00:00:00Z'; assert cycle('Relabel after observed clear opens a second notification')==2
 state['at']='2026-01-03T00:00:00Z'; assert cycle('Relabel without observing clear opens a third notification')==3
 assert cycle('Repeated third episode stays quiet')==3
finally:
 server.shutdown(); server.server_close(); (E/'episode-transcript.md').write_text('\n'.join(reports)); (E/'episode-api-requests.json').write_text(json.dumps(log,indent=2))
print('Live conflict episode scenarios passed.')
