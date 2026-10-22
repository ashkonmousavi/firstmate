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
try:
 p=poll(); record('Aged OPEN conflict via real gh and two GraphQL pages',p); assert p.returncode==0 and p.stdout.startswith('conflict:'),p
 state['age']=300; p=poll(); record('Young conflict stays quiet',p); assert p.stdout=='conflict-clear\n'
 state['present']=False; p=poll(); record('Removed label clears episode',p); assert p.stdout=='conflict-clear\n'
 state['present']=True; state['age']=1200
 for ps in ['CLOSED','MERGED','UNKNOWN']:
  state['prstate']=ps; before=len(log); p=poll(); record(f'{ps} PR',p); assert p.returncode==0 and p.stdout==('merged\n' if ps=='MERGED' else '')
  assert not any('timelineItems' in (x['body'] or {}).get('query','') for x in log[before:])
 state['prstate']='OPEN'; state['fail']=True; p=poll(); record('Label API failure remains nonzero',p); assert p.returncode!=0 and not p.stdout
 state['fail']=False
 nojq=W/'no-jq'; nojq.mkdir(exist_ok=True)
 for tool in ['bash','gh','cat','date','python3','sed','head','git']:
  link=nojq/tool
  if not link.exists(): link.symlink_to(shutil.which(tool))
 saved_path=ENV['PATH']; ENV['PATH']=str(nojq)
 p=poll(); record('GitHub poll with no jq executable on PATH',p); assert p.returncode==0 and p.stdout.startswith('conflict:')
 ENV['PATH']=saved_path
 # Ordinary executable overlap interface, using real Git merge-tree and real gh.
 repo=W/'repo'; shutil.rmtree(repo,ignore_errors=True); run(['git','init','-q','-b','main',str(repo)])
 (repo/'old.txt').write_text('base\n'); (repo/'other.txt').write_text('other\n'); run(['git','add','.'],cwd=repo); run(['git','commit','-qm','base'],cwd=repo)
 run(['git','remote','add','origin','https://github.com/o/r.git'],cwd=repo)
 run(['git','checkout','-qb','rename'],cwd=repo); run(['git','mv','old.txt','new.txt'],cwd=repo); run(['git','commit','-qm','rename'],cwd=repo); sha=run(['git','rev-parse','HEAD'],cwd=repo).stdout.strip(); run(['git','checkout','-q','main'],cwd=repo)
 state['prs']=[{'number':1,'url':'https://github.com/o/r/pull/1','headRefOid':sha},{'number':2,'url':'https://github.com/o/r/pull/2','headRefOid':'1'*40},{'number':3,'url':'https://github.com/o/r/pull/3','headRefOid':'2'*40}]
 state['files']={'2':[{'filename':'new.txt','previous_filename':'old.txt'}]}
 before=run(['git','status','--porcelain'],cwd=repo).stdout
 for i,heading in enumerate(['## SCOPE\nold.txt','FILES: old.txt','BLAST RADIUS:\n- old.txt','## SCOPE\nnew.txt','## SCOPE\nother.txt','No paths provided']):
  brief=W/f'brief-{i}.md'; brief.write_text('# Task\n'+heading+'\n## Work\nMake a change.\n')
  p=run(['bin/fm-pr-overlap.sh','--project',str(repo),'--brief',str(brief)]); out=brief.read_text(); reports.append(f'### Overlap: {heading}\nexit: {p.returncode}\n{out}\n'); (E/f'overlap-{i}.md').write_text(out)
  if i<4: assert '/pull/1 (old.txt)' in out or '/pull/1 (new.txt)' in out; assert '/pull/2 (' in out; assert '/pull/3 (unchecked:' in out
  if i==4: assert '1 compared open pull requests' not in out; assert '2 compared open pull requests' in out and '/pull/3 (unchecked:' in out
  if i==5: assert 'Overlap was not checked' in out
  run(['bin/fm-pr-overlap.sh','--project',str(repo),'--brief',str(brief)]); assert brief.read_text().count('## SHARED')==1
 assert run(['git','status','--porcelain'],cwd=repo).stdout==before
 reports.append('Overlap leaves source checkout unchanged.\n')

 # Live watcher and durable inbox delivery to the real Claude TUI in a private tmux server.
 lab=ROOT/'.l'; env=ENV.copy(); env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'tmux'),FM_BACKEND='tmux',FM_CHECK_INTERVAL='0',FM_POLL='0.05',FM_HEARTBEAT='999999',FM_SIGNAL_GRACE='0')
 socket=run(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path}'],env=env).stdout.strip(); env['TMUX']=socket+',1,0'
 def tmux(*args): return run(['tmux','-L','fm-lab',*args],env=env)
 # Fixture git remote stays entirely inside this worktree.
 remote=W/'remote.git'; shutil.rmtree(remote,ignore_errors=True); run(['git','init','--bare','-q',str(remote)]); run(['git','config','core.logAllRefUpdates','true'],cwd=remote)
 run(['git','remote','set-url','origin',str(remote)],cwd=repo); run(['git','push','-q','origin','main'],cwd=repo)
 run(['git','checkout','-qb','lane'],cwd=repo); (repo/'old.txt').write_text('worker\n'); run(['git','commit','-qam','worker change'],cwd=repo); run(['git','push','-qu','origin','lane'],cwd=repo)
 before_head=run(['git','rev-parse','HEAD'],cwd=repo).stdout.strip()
 run(['git','checkout','-q','main'],cwd=repo); (repo/'old.txt').write_text('main\n'); run(['git','commit','-qam','main change'],cwd=repo); run(['git','push','-q','origin','main'],cwd=repo); run(['git','checkout','-q','lane'],cwd=repo)
 shutil.rmtree(lab/'state',ignore_errors=True); (lab/'state').mkdir()
 (lab/'state/lane.meta').write_text('base_branch=main\nwindow=primary:fm-lane\nbackend=tmux\nharness=claude\nmodel=sonnet\nkind=ship\nproject='+str(repo)+'\nworktree='+str(repo)+'\nbranch=lane\npr=https://github.com/o/r/pull/7\n')
 prompt=f'This is a disposable live product test. Act only as worker lane in FM_HOME={lab}. Do not run session startup, fleet supervision, no-mistakes, or dispatch other workers. Your only allowed source repository is {repo}; it has a local bare origin under the same disposable directory. Do not edit the enclosing Firstmate repository. When the task inbox doorbell arrives, read the .msg records under ~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.l/state/lane.inbox, then carry out their merge instruction in the disposable repository. Resolve old.txt to exactly two lines: main then worker. Verify those two lines and the merge parent count, and push the lane branch to its local origin once. Do not rebase or force-push. For now reply READY and wait.'
 tmux('send-keys','-t','primary','-l',prompt); tmux('send-keys','-t','primary','Enter')
 for _ in range(80):
  pane=tmux('capture-pane','-p','-S','-150','-t','primary').stdout
  if 'READY' in pane and ('❯' in pane or '>' in pane): break
  time.sleep(.5)
 (E/'claude-initial.txt').write_text(pane)
 arm='source bin/fm-pr-lib.sh\nfm_pr_poll_prepare "$FM_HOME/state" lane github https://github.com/o/r/pull/7 github.com o/r 7 tests/fixtures/fm-pr-poll-v1.sh && fm_pr_poll_publish_prepared\n'
 run(['bash','-c',arm],env=env)
 state['at']='2026-01-01T00:00:00Z'
 out=open(W/'watch.out','w'); err=open(W/'watch.err','w'); watcher=subprocess.Popen(['bash','bin/fm-watch.sh'],env=env,stdout=out,stderr=err,cwd=ROOT)
 try:
  for _ in range(120):
   if (lab/'state/lane.pr-conflict-episode').exists(): break
   if watcher.poll() is not None: break
   time.sleep(.25)
  reports.append('### Live watcher delivery\n'+(W/'watch.err').read_text()+'\n'+(W/'watch.out').read_text())
  inbox=lab/'state/lane.inbox'; files=[p for p in inbox.rglob('*') if p.is_file()] if inbox.exists() else []
  for i,f in enumerate(files): (E/f'delivered-inbox-{i}.txt').write_bytes(f.read_bytes())
  assert (lab/'state/lane.pr-conflict-episode').exists(), 'real watcher did not open episode'
  assert files, 'real watcher did not deliver inbox record'
  time.sleep(2)
  # No repeat steer for the same application.
  count=len([p for p in inbox.rglob('*.msg')]); reports.append(f'Inbox message files after repeated polling: {count}\n'); assert count==1
 finally:
  watcher.terminate()
  try: watcher.wait(timeout=10)
  except subprocess.TimeoutExpired: watcher.kill(); watcher.wait()
  out.close(); err.close()
 for _ in range(240):
  head=run(['git','rev-parse','refs/heads/lane'],cwd=remote).stdout.strip()
  pane=tmux('capture-pane','-p','-S','-200','-t','primary').stdout
  if head!=before_head: break
  time.sleep(.5)
 (E/'claude-merge.txt').write_text(pane)
 after_head=run(['git','rev-parse','refs/heads/lane'],cwd=remote).stdout.strip()
 graph=run(['git','log','--graph','--oneline','--all','-8'],cwd=repo).stdout; reports.append('### Real worker merge result\n'+graph+'\n'+(repo/'old.txt').read_text()+f'\nremote lane before={before_head}\nafter={after_head}\n')
 assert after_head!=before_head, 'real worker did not push a merge within two minutes'
 assert (repo/'old.txt').read_text()=='main\nworker\n'
 assert len(run(['git','show','-s','--format=%P',after_head],cwd=repo).stdout.split())==2

finally:
 server.shutdown(); server.server_close(); (E/'live-transcript.md').write_text('\n'.join(reports)); (E/'local-api-requests.json').write_text(json.dumps(log,indent=2))
print('Live poll and overlap scenarios passed; evidence saved.')
