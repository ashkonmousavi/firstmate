import os,pathlib,subprocess,socket,threading,time,base64,shlex,json
import paramiko
R=pathlib.Path.cwd();W=R/'.live-validation/world';E=pathlib.Path('~/.no-mistakes/evidence/01M69RB4TAK0F6YXBXEYRM564V');log=(E/'mismatch-live.log').open('w',buffering=1)
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
    a=shlex.split(c.decode());root=base64.b64decode(a[2]).decode();home=base64.b64decode(a[3]).decode();argv=[x.decode() for x in base64.b64decode(a[4]).split(b'\0') if x];log.write('SSH requested '+shlex.join(argv)+'\n'); argv[3:] = ['main', main_tip] if argv[1] == 'update' else argv[3:]; log.write('SSH fault-injected argv '+shlex.join(argv)+'\n')
    if state_hang and argv[1]=='state':
     while not ch.closed and not stop.wait(.1):pass
     return
    if race:
     race=False;seed=W/'seed';git(seed,'checkout','-q','curated');(seed/'RACE').write_text('origin moved while update was in flight\n');git(seed,'add','.');git(seed,'commit','-qm','advance after parent resolution');git(seed,'push','-q','origin','curated')
    p=subprocess.Popen(['bash',str(R/'.live-validation/queue-call.sh'),str(R),str(W/'account-mismatch'),str(W/'queue-mismatch'),root,home,*argv],env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE);children.append(p);o,e=p.communicate(timeout=60);ch.sendall(o);ch.sendall_stderr(e);ch.send_exit_status(p.returncode)
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
account=W/'account-mismatch';account.mkdir(mode=0o700);server=threading.Thread(target=serve);server.start()
parent=W/'parent';primary=W/'primary';root=W/'remote';home=W/'remote-home';target=head(primary)
(parent/'data/secondmates.md').write_text(f'- remote-home - lab (host: lab; root: {root}; home: {home}; scope: lab; projects: lab; added 2026-10-31)\n')
def update():return run([R/'bin/fm-update.sh'],{'FM_ROOT_OVERRIDE':str(primary),'FM_HOME':str(parent),'FM_SSH_BIN':str(W/'ssh'),'FM_UPDATE_REMOTE_UPDATE_SECONDS':'15','FM_UPDATE_REMOTE_STATE_SECONDS':'3'},timeout=60)
try:
 base=git(W/'seed','rev-list','--max-parents=0','HEAD');main_tip=git(W/'seed','rev-parse','main')
 root=W/'mismatch-root';home=W/'mismatch-home'
 for path in [root,home]:
  run(['git','clone','-q',W/'origin.git',path]);git(path,'checkout','-q','main')
 git(root,'reset','--hard',base);git(home,'checkout','-q','--detach',base)
 (home/'.fm-secondmate-home').write_text('mismatch-home\n')
 (parent/'data/secondmates.md').write_text(f'- mismatch-home - lab (host: lab; root: {root}; home: {home}; scope: lab; projects: lab; added 2026-10-31)\n')
 out=update()
 assert f'host reports {main_tip}, not update target {target}' in out
 assert head(root)==main_tip and head(home)==main_tip
 assert 'restart-secondmates: none' in out and 'nudge-secondmates: none' in out
 log.write(f'PASS independent remote request fault landed real root/home at main={main_tip}; parent rejected the mismatching result against curated={target} and selected no action\n')
 results.append('post-mutation comparison rejects a real mismatched remote result')

finally:
 stop.set();listener.close();server.join(timeout=3)
 for p in children:
  if p.poll() is None:p.terminate()
  try:p.wait(timeout=4)
  except subprocess.TimeoutExpired:p.kill();p.wait()
 for t in threads:t.join(timeout=5)
 state=W/'queue-mismatch'
 if (state/'worker.pid').exists():run(['bash','-c','. "$1/bin/fm-remote-job-lib.sh"; fm_remote_job_stop_worker_tree "$(cat "$2/worker.pid")"','_',R,state],{'HOME':str(account),'FM_REMOTE_JOB_STATE_ROOT':str(state)})
 log.write('Server, request children and worker stopped.\n');(E/'mismatch-results.json').write_text(json.dumps(results,indent=2)+'\n');log.close()
