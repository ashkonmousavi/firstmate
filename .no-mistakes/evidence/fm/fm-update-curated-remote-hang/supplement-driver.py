import os,pathlib,subprocess,socket,threading,time,base64,shlex,json
import paramiko
R=pathlib.Path.cwd();W=R/'.live-validation/world';E=pathlib.Path('~/.no-mistakes/evidence/01M69RB4TAK0F6YXBXEYRM564V');log=(E/'supplement-live.log').open('w',buffering=1)
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_HOME','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_GATE_REFUSE_BYPASS','GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE']:env.pop(k,None)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',TMPDIR=str(R/'.live-validation/tmp'))
stop=threading.Event();threads=[];children=[];race=False;state_hang=False;results=[]
def run(args,extra=None,timeout=60):
 e=env.copy();e.update(extra or {});p=subprocess.run(list(map(str,args)),env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
 log.write('$ '+shlex.join(list(map(str,args)))+'\n'+p.stdout+f'exit={p.returncode}\n');assert p.returncode==0;return p.stdout

def git(p,*args):return run(['git','-C',p,*args]).strip()
def head(p):return git(p,'rev-parse','HEAD')
key=paramiko.RSAKey.from_private_key_file(str(W/'client-key'));host=paramiko.RSAKey.generate(2048)
listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();listener.settimeout(.2);port=listener.getsockname()[1]
(W/'known_hosts').write_text(f'[127.0.0.1]:{port} {host.get_name()} {host.get_base64()}\n')
(W/'ssh_config').write_text(f'Host lab\n HostName 127.0.0.1\n Port {port}\n User lab\n IdentityFile {W}/client-key\n UserKnownHostsFile {W}/known_hosts\n StrictHostKeyChecking yes\n IdentitiesOnly yes\n BatchMode yes\n')
class S(paramiko.ServerInterface):
 def check_auth_publickey(self,u,k):return paramiko.AUTH_SUCCESSFUL if k==key else paramiko.AUTH_FAILED
 def get_allowed_auths(self,u):return 'publickey'
 def check_channel_request(self,k,i):return paramiko.OPEN_SUCCEEDED
 def check_global_request(self,k,m):return True
 def check_channel_exec_request(self,ch,c):
  def work():
   global race
   try:
    a=shlex.split(c.decode());root=base64.b64decode(a[2]).decode();home=base64.b64decode(a[3]).decode();argv=[x.decode() for x in base64.b64decode(a[4]).split(b'\0') if x];log.write('SSH request '+shlex.join(argv)+'\n')
    if state_hang and argv[1]=='state':
     while not ch.closed and not stop.wait(.1):pass
     return
    if race:
     race=False;seed=W/'seed';git(seed,'checkout','-q','curated');(seed/'RACE').write_text('origin moved while update was in flight\n');git(seed,'add','.');git(seed,'commit','-qm','advance after parent resolution');git(seed,'push','-q','origin','curated')
    p=subprocess.Popen(['bash',str(R/'.live-validation/queue-call.sh'),str(R),str(W/'account-supplement'),str(W/'queue-supplement'),root,home,*argv],env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE);children.append(p);o,e=p.communicate(timeout=60);ch.sendall(o);ch.sendall_stderr(e);ch.send_exit_status(p.returncode)
   except Exception as ex:
    log.write('ERROR '+repr(ex)+'\n')
    try:ch.sendall_stderr(str(ex).encode());ch.send_exit_status(70)
    except:pass
   finally:ch.close()
  t=threading.Thread(target=work);threads.append(t);t.start();return True

def conn(s):
 t=paramiko.Transport(s);t.add_server_key(host)
 try:
  t.start_server(server=S())
  while t.is_active() and not stop.wait(.1):pass
 except Exception as ex:
  if not stop.is_set():log.write(repr(ex)+'\n')
 finally:t.close()
def serve():
 while not stop.is_set():
  try:s,_=listener.accept()
  except socket.timeout:continue
  except OSError:break
  t=threading.Thread(target=conn,args=(s,));threads.append(t);t.start()
account=W/'account-supplement';account.mkdir(mode=0o700);server=threading.Thread(target=serve);server.start()
parent=W/'parent';primary=W/'primary';root=W/'remote';home=W/'remote-home';target=head(primary)
(parent/'data/secondmates.md').write_text(f'- remote-home - lab (host: lab; root: {root}; home: {home}; scope: lab; projects: lab; added 2026-10-31)\n')
def update():return run([R/'bin/fm-update.sh'],{'FM_ROOT_OVERRIDE':str(primary),'FM_HOME':str(parent),'FM_SSH_BIN':str(W/'ssh'),'FM_UPDATE_REMOTE_UPDATE_SECONDS':'15','FM_UPDATE_REMOTE_STATE_SECONDS':'3'},timeout=60)
try:
 race=True;out=update();tip=git(W/'seed','rev-parse','curated');assert tip!=target
 assert head(primary)==target and head(root)==target and head(home)==target
 log.write(f'PASS origin moved to {tip}; primary, remote root and home stayed pinned to {target}\n');results.append('origin race preserves one pinned target')
 (parent/'state/remote-home.meta').write_text(f'kind=secondmate\nremote_host=lab\nremote_backend=herdr\nwindow=remote:remote-home\nharness=claude\nhome={home}\n')
 state_hang=True;start=time.monotonic();out=update();elapsed=time.monotonic()-start
 assert 'state step timed out after 3s' in out and 'restart-secondmates: none' in out and 'nudge-secondmates: none' in out and elapsed<20
 log.write(f'PASS live SSH state request timed out in {elapsed:.2f}s; no restart/nudge selected\n');results.append('state timeout leaves mate out of action sets')
finally:
 stop.set();listener.close();server.join(timeout=3)
 for p in children:
  if p.poll() is None:p.terminate()
  try:p.wait(timeout=4)
  except subprocess.TimeoutExpired:p.kill();p.wait()
 for t in threads:t.join(timeout=5)
 state=W/'queue-supplement'
 if (state/'worker.pid').exists():run(['bash','-c','. "$1/bin/fm-remote-job-lib.sh"; fm_remote_job_stop_worker_tree "$(cat "$2/worker.pid")"','_',R,state],{'HOME':str(account),'FM_REMOTE_JOB_STATE_ROOT':str(state)})
 log.write('Server, request children and worker stopped.\n');(E/'supplement-results.json').write_text(json.dumps(results,indent=2)+'\n');log.close()
