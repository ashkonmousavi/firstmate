import os, pathlib, subprocess, shutil, socket, threading, time, base64, shlex, json, signal
import paramiko
R=pathlib.Path.cwd(); W=R/'.live-validation/world'; E=pathlib.Path('~/.no-mistakes/evidence/01M69RB4TAK0F6YXBXEYRM564V')
W.mkdir(); log=(E/'live-product.log').open('w',buffering=1)
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_HOME','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','GIT_DIR','GIT_COMMON_DIR','GIT_INDEX_FILE','GIT_WORK_TREE','TASKS_AXI_FILE','TASKS_AXI_BACKEND']: env.pop(k,None)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',TMPDIR=str(R/'.live-validation/tmp'))
workers=[]; results=[]; threads=[]; children=[]; lock=threading.Lock(); stop=threading.Event(); listener=None

def note(s):
 with lock: log.write(s+'\n')
def run(args,cwd=None,extra=None,ok=True,show=False,timeout=90):
 e=env.copy(); e.update(extra or {})
 p=subprocess.run([str(a) for a in args],cwd=cwd,env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
 if show: note('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'exit={p.returncode}')
 if ok and p.returncode: raise RuntimeError(p.stdout)
 return p

def git(path,*args): return run(['git','-C',path,*args]).stdout.strip()
def head(path): return git(path,'rev-parse','HEAD')
def result(name,detail): results.append({'name':name,'result':'pass','detail':detail});note('SCENARIO PASS: '+name+'\n'+detail)
def update(extra=None,ok=True):
 e={'FM_ROOT_OVERRIDE':str(W/'primary'),'FM_HOME':str(W/'parent'),'FM_UPDATE_REMOTE_UPDATE_SECONDS':'4','FM_UPDATE_REMOTE_STATE_SECONDS':'4','FM_SSH_BIN':str(W/'ssh')};e.update(extra or {})
 return run([R/'bin/fm-update.sh'],extra=e,ok=ok,show=True,timeout=100)

def queue_env(account,state):
 e=env.copy(); e.update(HOME=str(account),FM_REMOTE_JOB_STATE_ROOT=str(state),FM_REMOTE_JOB_PROGRESS_STALL_SECONDS='2',FM_REMOTE_JOB_QUEUE_TIMEOUT='90',FM_REMOTE_JOB_TIMEOUT='60');return e

class Server(paramiko.ServerInterface):
 def check_auth_publickey(self, username,key): return paramiko.AUTH_SUCCESSFUL if key==client_key else paramiko.AUTH_FAILED
 def get_allowed_auths(self,username):return 'publickey'
 def check_channel_request(self,kind,chanid):return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
 def check_global_request(self,kind,msg):return True
 def check_channel_exec_request(self,ch,command):
  def serve():
   p=None
   try:
    a=shlex.split(command.decode());assert a[0]=='fm-remote-entrypoint.sh' and a[1]=='1'
    root=pathlib.Path(base64.b64decode(a[2]).decode());home=pathlib.Path(base64.b64decode(a[3]).decode());argv=[v.decode() for v in base64.b64decode(a[4]).split(b'\0') if v]
    assert root.is_relative_to(W) and home.is_relative_to(W)
    note('SSH request '+root.name+' '+shlex.join(argv))
    if root.name=='blackhole':
     while not ch.closed and not stop.wait(.1):pass
     return
    account=W/('account-'+root.name);account.mkdir(exist_ok=True,mode=0o700);state=W/('queue-'+root.name);workers.append((account,state))
    p=subprocess.Popen(['bash',str(R/'.live-validation/queue-call.sh'),str(R),str(account),str(state),str(root),str(home),*argv],env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    children.append(p)
    out,err=p.communicate(timeout=85)
    ch.sendall(out);ch.sendall_stderr(err);ch.send_exit_status(p.returncode)
   except Exception as ex:
    note('SSH lab exception '+repr(ex))
    if p and p.poll() is None:p.kill();p.wait()
    try:ch.sendall_stderr(str(ex).encode());ch.send_exit_status(70)
    except:pass
   finally:ch.close()
  t=threading.Thread(target=serve);threads.append(t);t.start();return True

def connection(sock):
 t=paramiko.Transport(sock);t.add_server_key(host_key)
 try:
  t.start_server(server=Server())
  while t.is_active() and not stop.wait(.1):pass
 except Exception as ex:
  if not stop.is_set():note('SSH transport '+repr(ex))
 finally:t.close()
def accept():
 while not stop.is_set():
  try:s,_=listener.accept()
  except socket.timeout:continue
  except OSError:return
  t=threading.Thread(target=connection,args=(s,));threads.append(t);t.start()

try:
 seed=W/'seed';seed.mkdir();shutil.copytree(R/'bin',seed/'bin');shutil.copy(R/'AGENTS.md',seed/'AGENTS.md')
 (seed/'.gitignore').write_text('state/\ndata/\nconfig/\nprojects/\n.fm-secondmate-home\n.fm-lab-home\n')
 (seed/'README').write_text('base\n')
 run(['git','init','-q','-b','main',seed]);git(seed,'add','.');git(seed,'commit','-qm','lab product baseline')
 origin=W/'origin.git';run(['git','init','--bare','-q','-b','main',origin]);git(seed,'remote','add','origin',str(origin));git(seed,'push','-q','origin','main');git(seed,'checkout','-qb','curated');git(seed,'push','-q','origin','curated')
 base=head(seed)
 for name in ['primary','remote','legacy','local','clone','dirty','diverged','blackhole']:
  p=W/name;run(['git','clone','-q',origin,p]);git(p,'checkout','-qb','curated','--track','origin/curated')
 for name in ['local','clone','dirty','diverged','remote','legacy']:
  p=W/name
  if name!='legacy' and name!='remote':git(p,'checkout','-q','--detach')
  (p/'.fm-secondmate-home').write_text(name+'\n')
 (W/'dirty'/'README').write_text('uncommitted private work\n')
 (W/'diverged'/'LOCAL_ONLY').write_text('unlanded\n');git(W/'diverged','add','.');git(W/'diverged','commit','-qm','unique local result');diverged=head(W/'diverged')
 parent=W/'parent';run([R/'bin/fm-lab-home.sh','create',parent]);reg=parent/'data/secondmates.md'
 def localrow(n):return f'- {n} - lab (home: {W/n}; scope: lab; projects: lab; added 2026-10-31)\n'
 def remoterow(n,root=None):return f'- {n} - lab (host: lab; root: {W/(root or n)}; home: {W/n}; scope: lab; projects: lab; added 2026-10-31)\n'
 reg.write_text(''.join(localrow(n) for n in ['local','clone','dirty','diverged'])+remoterow('remote'))
 host_key=paramiko.RSAKey.generate(2048);client_key=paramiko.RSAKey.generate(2048);client_key.write_private_key_file(str(W/'client-key'));os.chmod(W/'client-key',0o600)
 listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();listener.settimeout(.2);port=listener.getsockname()[1]
 (W/'known_hosts').write_text(f'[127.0.0.1]:{port} {host_key.get_name()} {host_key.get_base64()}\n')
 (W/'ssh_config').write_text(f'Host lab\n HostName 127.0.0.1\n Port {port}\n User lab\n IdentityFile {W}/client-key\n UserKnownHostsFile {W}/known_hosts\n StrictHostKeyChecking yes\n IdentitiesOnly yes\n BatchMode yes\n')
 (W/'ssh').write_text('#!/bin/bash\nexec /usr/bin/ssh -F '+shlex.quote(str(W/'ssh_config'))+' "$@"\n');os.chmod(W/'ssh',0o700)
 accept_thread=threading.Thread(target=accept);accept_thread.start()
 (seed/'CURATED_ONLY').write_text('curated release\n');git(seed,'add','.');git(seed,'commit','-qm','curated update');git(seed,'push','-q','origin','curated');target=head(seed)
 git(seed,'checkout','-q','main');(seed/'MAIN_ONLY').write_text('main release\n');git(seed,'add','.');git(seed,'commit','-qm','main update');git(seed,'push','-q','origin','main');main_tip=head(seed)
 out=update().stdout
 for name in ['primary','local','clone','remote']:
  assert head(W/name)==target,(name,head(W/name),target);assert not (W/name/'MAIN_ONLY').exists();note(f'{name} HEAD={head(W/name)}')
 assert git(W/'primary','symbolic-ref','--short','HEAD')=='curated'
 assert head(W/'dirty')==base and (W/'dirty'/'README').read_text()=='uncommitted private work\n';assert head(W/'diverged')==diverged
 result('Curated fleet updates primary, detached clones and remote root/home to one commit, preserving unsafe homes',f'curated={target}; origin/main={main_tip}; dirty and unique divergence preserved')
 # Remote configured root and home are distinct in this second check.
 remotehome=W/'remote-home';run(['git','clone','-q',origin,remotehome]);git(remotehome,'checkout','-q','--detach',base);(remotehome/'.fm-secondmate-home').write_text('remote-home\n')
 reg.write_text(remoterow('remote-home','remote'))
 out=update().stdout;assert head(remotehome)==target and head(W/'remote')==target
 result('Pinned remote control updates a separate persistent home from its configured root',f'root={head(W/"remote")}; home={head(remotehome)}')
 # Same-named upstream must not authorize the feature checkout.
 primary=W/'primary';git(primary,'checkout','-qb','feature/wip');(primary/'FEATURE_ONLY').write_text('unlanded feature\n');git(primary,'add','.');git(primary,'commit','-qm','feature');git(primary,'push','-qu','origin','feature/wip');feature=head(primary)
 selected=run(['bash','-c','. "$1/bin/fm-ff-lib.sh"; primary_head_commit "$2"','_',R,primary]).stdout.strip();assert selected==base
 reg.write_text(localrow('clone'));out=update().stdout
 assert 'update target: origin/main '+main_tip in out and 'firstmate: skipped:' in out;assert head(primary)==feature and head(W/'clone')==target;assert not (W/'clone'/'FEATURE_ONLY').exists()
 result('Published feature branch is skipped and its commit is never propagated',f'feature={feature}; primary sync chose main={selected}; existing detached divergent home preserved')
 git(primary,'checkout','-q','curated')
 # Fail target lookup using a real missing origin; no home may move.
 reg.write_text(localrow('local')+remoterow('remote-home','remote'));before={n:head(W/n) for n in ['primary','local','remote','remote-home']};git(primary,'remote','set-url','origin',str(W/'absent.git'))
 out=update(ok=False);assert out.returncode!=0 and 'no homes updated' in out.stdout;assert before=={n:head(W/n) for n in before};git(primary,'remote','set-url','origin',str(origin))
 result('Unresolvable shared target aborts before mutating any home',json.dumps(before))
 # Real historic product rejects the new pinned arguments with status 2.
 old=run(['git','show','4220467f622e1095bae46961814f305d27418b97:bin/fm-remote-secondmate-control.sh']).stdout
 legacy=W/'legacy';(legacy/'bin/fm-remote-secondmate-control.sh').write_text(old);git(legacy,'add','.');git(legacy,'commit','-qm','legacy argument parser');legacy_before=head(legacy)
 reg.write_text(remoterow('legacy'));out=update().stdout
 assert 'pinned update rejected; manual update required' in out;assert head(legacy)==legacy_before
 result('Legacy host rejects pinned arguments and receives no unpinned retry',f'legacy HEAD stayed {legacy_before}; SSH request transcript records one update request')
 # A real SSH connection remains alive while the endpoint never returns.
 reg.write_text(remoterow('local','blackhole')+remoterow('remote-home','remote'));start=time.monotonic();p=update();elapsed=time.monotonic()-start
 assert 'update step timed out after 4s' in p.stdout and 'remote secondmate remote-home: already current' in p.stdout and elapsed<20
 result('Hung remote SSH update is named and bounded while the next host is still processed',f'elapsed={elapsed:.2f}s; budget=4s; following remote home current at {target}')
 # Stop serving only; keep the real worker heartbeat alive. Stage real remote sync work.
 account=W/'account-remote';state=W/'queue-remote';worker=int((state/'worker.pid').read_text());os.kill(worker,signal.SIGSTOP)
 script='''set -eu
. "$1/bin/fm-remote-job-lib.sh"
fm_remote_job_stage "$2" "$3" "$4" fm-remote-secondmate-control.sh sync remote-home "$5" </dev/null >/dev/null
printf 'queued job=%s state=%s\\n' "$FM_REMOTE_JOB_ID" "$(fm_remote_job_read_state "$FM_REMOTE_JOB_JOBS/$FM_REMOTE_JOB_ID")"
for ((i=0;i<250;i++)); do fm_remote_job_probe "$2" || break; sleep .1; done
! fm_remote_job_probe "$2"
printf 'stale readiness observed while old worker still alive\\n'
fm_remote_job_ensure_worker "$3" "$2" || { echo "$FM_REMOTE_JOB_ERROR"; exit 1; }
fm_remote_job_wait "$2" "$FM_REMOTE_JOB_ID"
cat "$FM_REMOTE_JOB_STDOUT" "$FM_REMOTE_JOB_STDERR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ]
printf 'replacement worker=%s job result=%s\\n' "$(cat "$FM_REMOTE_JOB_STATE/worker.pid")" "$FM_REMOTE_JOB_EXIT"
fm_remote_job_reap "$2" "$FM_REMOTE_JOB_ID"
'''
 p=run(['bash','-c',script,'_',R,account,W/'remote',remotehome,target],extra=queue_env(account,state),show=True,timeout=65)
 replacement=int((state/'worker.pid').read_text());assert replacement!=worker
 try:os.kill(worker,0)
 except ProcessLookupError:pass
 else:raise AssertionError('old serving process survived')
 note((state/'logs/dev.firstmate.remote-job.log').read_text())
 result('Live heartbeat cannot mask a wedged serving loop; replacement drains queued remote work',f'old PID={worker}; replacement PID={replacement}; queued sync completed on {head(remotehome)}')
 # Healthy worker re-use under two concurrent real queue requests.
 procs=[]
 for i in range(2):
  procs.append(subprocess.Popen(['bash',str(R/'.live-validation/queue-call.sh'),str(R),str(account),str(state),str(W/'remote'),str(remotehome),'fm-remote-secondmate-control.sh','sync','remote-home',target],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True))
 for p in procs:
  children.append(p);s,_=p.communicate(timeout=30);note(s);assert p.returncode==0
 assert int((state/'worker.pid').read_text())==replacement
 result('Healthy serving worker accepts concurrent jobs without replacement',f'both sync requests completed; PID remained {replacement}')
except Exception as ex:
 note('FAILED '+repr(ex));results.append({'name':'live driver','result':'fail','detail':repr(ex)});raise
finally:
 stop.set()
 if listener:listener.close()
 for p in children:
  if p.poll() is None:p.terminate()
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired:p.kill();p.wait()
 if 'accept_thread' in globals():accept_thread.join(timeout=3)
 for t in threads:t.join(timeout=5)
 for account,state in set(workers):
  if (state/'worker.pid').exists():
   run(['bash','-c','. "$1/bin/fm-remote-job-lib.sh"; fm_remote_job_stop_worker_tree "$(cat "$2/worker.pid")"','_',R,state],extra=queue_env(account,state),ok=False,show=True,timeout=20)
 (E/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
 note('Disposable SSH server, request children and worker trees stopped.');log.close()
