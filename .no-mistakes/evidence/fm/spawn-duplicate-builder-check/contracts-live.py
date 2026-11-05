import pathlib,subprocess,json,time,urllib.request,base64,traceback,socket,threading
R=pathlib.Path.cwd();D=R/'.test-live';E=pathlib.Path('~/.no-mistakes/evidence/01M6P6CGV28DT78F2NZW37QR91');v=json.loads((D/'lab-env.json').read_text());env=v['env'];URL=v['branch_pr']['html_url'].split('/labuser/')[0];env.update(GH_CONFIG_DIR=str(D/'user/gh'),GLAB_CONFIG_DIR=str(D/'user/glab'))
for k in ('GH_TOKEN','GITHUB_TOKEN','GITLAB_TOKEN','GLAB_TOKEN','GITHUB_ENTERPRISE_TOKEN','GH_ENTERPRISE_TOKEN'):env.pop(k,None)
log=(E/'contracts-live-transcript.log').open('w',buffering=1)
def note(s):print(s,flush=True);log.write(s+'\n')
def run(a,code=0):
 p=subprocess.run([str(x) for x in a],env=env,cwd=R,capture_output=True,text=True,timeout=30)
 note('$ '+' '.join(str(x) for x in a)+'\n'+p.stdout.strip()+'\n'+p.stderr.strip()+f'\nexit={p.returncode}')
 assert p.returncode==code,p.stdout+p.stderr
 return p.stdout
basic='Basic '+base64.b64encode(b'labuser:DisposableLab-12345').decode()
def api(path,data=None,method=None):
 req=urllib.request.Request(URL+'/api/v1'+path,data=json.dumps(data).encode() if data is not None else None,method=method,headers={'Authorization':basic,'Content-Type':'application/json'})
 with urllib.request.urlopen(req,timeout=15) as r:
  raw=r.read();return json.loads(raw) if raw else None
base=['python3','bin/fm-open-pr-lookup.py','--forge','forgejo','--origin',URL+'/labuser/project.git','--branch','fm/t1','--task-id','t1','--timeout','2']
server=None;listener=None;t=None;stop=threading.Event()
try:
 out=(E/'forgejo-contracts-server.log').open('w')
 server=subprocess.Popen(v['fargs']+['web'],env=env,cwd=R,stdout=out,stderr=subprocess.STDOUT)
 for _ in range(80):
  try:api('/version');break
  except Exception:time.sleep(.2)
 else:raise RuntimeError('server startup failed')
 bodies=[('R3 different fence','```\n~~~\nSLICE: home/t1',True),('R9 bullet','- ```\n example\n ```\n\nTask: home/t1',True),('R9 ordered','1. ```\n   Task-ID: home/t1\n   ```',True),('R10 blank-start','- \n ```\n example\nTask: t1',True),('R10 double blank','-\n\n ```\nTask: t1\n ```',True),('strong Task','**Task: home/t1**',True),('strong SLICE','__SLICE: home/t1__',True),('decorated value','> - Task-ID: **home:t1**',True),('prose only','Blocked by t1; depends on t1.',False),('other slice','SLICE: home/other | blocked by t1',False)]
 for name,body,expected in bodies:
  api('/repos/labuser/project/pulls/5',{'body':body},'PATCH')
  answer=json.loads(run(base));actual=[x['number'] for x in answer['prs']]
  assert actual==([5] if expected else []),(name,actual)
  note('PASS real PR body '+name+' => '+str(actual))
 # Mutation proof uses a disposable copy, leaving production source untouched.
 mutant=D/'lookup-mutant.py';mutant.write_text((R/'bin/fm-open-pr-lookup.py').read_text().replace('if head_branch == args.branch:', 'if False:'))
 args=['python3',mutant,*base[2:]];i=args.index('--branch');args[i+1]='fm/dup-live';i=args.index('--task-id');args[i+1]='dup-live'
 original=list(args);original[1]='bin/fm-open-pr-lookup.py'
 assert [p['number'] for p in json.loads(run(original))['prs']]==[4]
 bad=json.loads(run(args));assert bad['prs']==[]
 note('MUTATION KILLED: independent oracle requires existing real branch PR #4; branch-matching mutant returned [] and fails that assertion')
 # A real merge removes a formerly matching pull request.
 api('/repos/labuser/project/pulls/8',{'body':'Task: t1'},'PATCH')
 assert [p['number'] for p in json.loads(run(base))['prs']]==[8]
 api('/repos/labuser/project/pulls/8/merge',{'Do':'merge','merge_when_checks_succeed':False},'POST')
 merged=api('/repos/labuser/project/pulls/8');assert merged['merged'] is True
 assert json.loads(run(base))['prs']==[]
 note('PASS actually merged PR #8 is excluded')
 for n in (1,2,3,4,5,6,7):api('/repos/labuser/project/pulls/'+str(n),{'state':'closed'},'PATCH')
 assert api('/repos/labuser/project/pulls?state=open')==[]
 assert json.loads(run(base))['prs']==[]
 note('PASS genuinely empty open-PR API list succeeds')
 for forge in ('gerrit','external'):
  a=list(base);a[a.index('--forge')+1]=forge
  answer=json.loads(run(a));assert answer['state']=='skip' and answer['notice']
 for origin in ('','../../remotes/x.git','/srv/x.git','file:///x'):
  a=list(base);a[a.index('--origin')+1]=origin
  answer=json.loads(run(a));assert answer['state']=='skip' and answer['notice']==''
 for origin in ('custom://github.com/o/r.git','https://unregistered.example/o/r.git'):
  a=list(base);a[a.index('--forge')+1]='none';a[a.index('--origin')+1]=origin
  assert json.loads(run(a,3))['state']=='unknown'
 for host in ('github.com','gitlab.com'):
  env.update(HTTPS_PROXY='http://127.0.0.1:9',HTTP_PROXY='http://127.0.0.1:9',ALL_PROXY='http://127.0.0.1:9',NO_PROXY='127.0.0.1,localhost')
  a=list(base);a[a.index('--forge')+1]='none';a[a.index('--origin')+1]='https://'+host+'/disposable/project.git'
  answer=json.loads(run(a,3));assert answer['state']=='unknown'
 note('REAL GH/GLAB LIMIT: isolated client config has no service credential; successful GitHub/GitLab reads remain untested. No operator credentials or repository were used.')
 # Stalled TCP transport is an actual timeout boundary, not a mocked lookup.
 server.terminate();server.wait(timeout=25);server=None
 port=int(URL.rsplit(':',1)[1]);listener=socket.socket();listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);listener.bind(('127.0.0.1',port));listener.listen();listener.settimeout(.2)
 def stall():
  while not stop.is_set():
   try:
    conn,_=listener.accept()
    with conn:stop.wait(3)
   except socket.timeout:pass
 t=threading.Thread(target=stall);t.start()
 answer=json.loads(run(base,3));assert 'did not answer within' in answer['error']
 note('PASS stalled real tea HTTP transport returns UNKNOWN on timeout')
except Exception:
 note(traceback.format_exc());raise
finally:
 stop.set()
 if t:t.join(timeout=5);assert not t.is_alive()
 if listener:listener.close()
 if server is not None:server.terminate();server.wait(timeout=25)
 note('All disposable server/listener children stopped and awaited')
 log.close()
