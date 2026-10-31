import os,pathlib,subprocess,time,json,urllib.request,base64,socket,signal
root=pathlib.Path.cwd(); lab=root/'.validation-live'; f=lab/'forge'; f.mkdir(exist_ok=True)
port=next(p for p in range(9660,9700) if not socket.socket().connect_ex(('127.0.0.1',p))==0)
conf=f/'app.ini'
conf.write_text(f'''APP_NAME = Isolated validation forge
RUN_USER = {os.environ.get('USER','tegris')}
RUN_MODE = prod
WORK_PATH = {f}
[server]
HTTP_ADDR = 127.0.0.1
HTTP_PORT = {port}
ROOT_URL = http://127.0.0.1:{port}/
DISABLE_SSH = true
OFFLINE_MODE = true
APP_DATA_PATH = {f}/data
[database]
DB_TYPE = sqlite3
PATH = {f}/forgejo.db
[repository]
ROOT = {f}/repos
[security]
INSTALL_LOCK = true
[service]
DISABLE_REGISTRATION = true
[log]
MODE = console
LEVEL = Warn
[mailer]
ENABLED = false
[actions]
ENABLED = false
''')
env=os.environ.copy(); env.update(HOME=str(lab/'user'),XDG_CONFIG_HOME=str(lab/'user/config'), GIT_CONFIG_GLOBAL=str(lab/'user/gitconfig'),GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1')
for x in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS') :env.pop(x,None)
(lab/'user').mkdir(exist_ok=True)
args=[str(lab/'tools/forgejo'),'-w',str(f),'-c',str(conf)]
log=open(lab/'server.log','w'); proc=subprocess.Popen(args+['web'],env=env,stdout=log,stderr=log)
def stop(*args):
 proc.terminate(); proc.wait(timeout=20); raise SystemExit(0)
signal.signal(signal.SIGTERM,stop)
try:
 for _ in range(100):
  try:
   urllib.request.urlopen(f'http://127.0.0.1:{port}/api/v1/version',timeout=1);break
  except Exception: time.sleep(.2)
 else:raise RuntimeError('forge start failed')
 import secrets
 password=secrets.token_urlsafe(24)
 r=subprocess.run(args+['admin','user','create','--username','labowner','--password',password,'--email','lab@example.invalid','--admin','--must-change-password=false'],env=env,capture_output=True,text=True)
 if r.returncode:raise RuntimeError(r.stdout+r.stderr)
 auth=base64.b64encode(('labowner:'+password).encode()).decode()
 def req(path,data):
  return json.load(urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}/api/v1/'+path,data=json.dumps(data).encode(),headers={'Authorization':'Basic '+auth,'Content-Type':'application/json'})))
 token=req('users/labowner/tokens',{'name':'disposable-validation','scopes':['all']})['sha1']
 r=subprocess.run([str(lab/'tools/tea'),'login','add','--name','lab','--url',f'http://127.0.0.1:{port}','--token',token],env=env,capture_output=True,text=True)
 if r.returncode:raise RuntimeError(r.stdout+r.stderr)
 (lab/'connection.json').write_text(json.dumps({'port':port,'token':token})); (lab/'connection.json').chmod(0o600)
 print('READY local forge port='+str(port),flush=True)
 while not (lab/'stop').exists():time.sleep(.5)
finally:
 if proc.poll() is None:proc.terminate();proc.wait(timeout=20)
 log.close()
