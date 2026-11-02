import pathlib, os, sys, subprocess, socket, threading, shlex, time, json, shutil
W=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M68RDV1CW6E2AMQX2N5CQ690'); P=W/'.test-disposable/product'; F=W/'.test-disposable/ssh'; R=W/'.r'; Q=W/'.q'; J=F/'jobs'
sys.path.insert(0,str(W/'.test-disposable/deps')); import paramiko
F.mkdir(); log=(E/'live-remote.log').open('w'); results=[]; threads=[]; processes=[]; stop=threading.Event()
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('NO_MISTAKES_GATE','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_PANE_ID'):env.pop(k,None)
env.update(FM_HOME=str(R),FM_ROOT_OVERRIDE=str(P),TMPDIR=str(W/'.test-disposable/tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',FM_BOOTSTRAP_NETWORK='only',FM_SECONDMATE_CONVERGENCE_TIMEOUT='150')
def run(args,timeout=100,check=True,extra=None):
 e=env.copy();e.update(extra or {})
 p=subprocess.run([str(a) for a in args],env=e,cwd=W,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 log.write('$ '+' '.join(str(a) for a in args)+'\n'+p.stdout+f'[exit {p.returncode}]\n');log.flush()
 if check and p.returncode:raise RuntimeError(p.stdout)
 return p
key=paramiko.RSAKey.generate(2048); hostkey=paramiko.RSAKey.generate(2048)
key.write_private_key_file(str(F/'key'));os.chmod(F/'key',0o600)
listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(30);listener.settimeout(.25);port=listener.getsockname()[1]
(F/'known_hosts').write_text(f'[127.0.0.1]:{port} {hostkey.get_name()} {hostkey.get_base64()}\n')
(F/'config').write_text(f'Host fm-lab-ssh\n HostName 127.0.0.1\n Port {port}\n User lab\n IdentityFile {F}/key\n IdentitiesOnly yes\n StrictHostKeyChecking yes\n UserKnownHostsFile {F}/known_hosts\n GlobalKnownHostsFile /dev/null\n')
(F/'ssh').write_text(f'#!/bin/sh\nexec /usr/bin/ssh -F {shlex.quote(str(F/"config"))} "$@"\n');(F/'ssh').chmod(0o700);env['FM_SSH_BIN']=str(F/'ssh');env['FM_PROCEVENT_CLAIM_ROOT']=str(F/'claims')
class Server(paramiko.ServerInterface):
 def __init__(self):self.command=None;self.ready=threading.Event()
 def check_auth_publickey(self,user,k):return paramiko.AUTH_SUCCESSFUL if user=='lab' and k==key else paramiko.AUTH_FAILED
 def get_allowed_auths(self,user):return 'publickey'
 def check_channel_request(self,kind,chanid):return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
 def check_channel_exec_request(self,ch,command):self.command=command.decode();self.ready.set();return True

def handle(conn):
 t=paramiko.Transport(conn); t.add_server_key(hostkey);s=Server()
 try:
  t.start_server(server=s);ch=t.accept(10)
  if ch is None or not s.ready.wait(10):return
  argv=shlex.split(s.command)
  assert argv[0]=='fm-remote-entrypoint.sh',argv
  data=b''
  while True:
   b=ch.recv(65536)
   if not b:break
   data+=b
  e=env.copy();e['FM_REMOTE_JOB_STATE_ROOT']=str(J)
  p=subprocess.Popen([str(P/'bin/fm-remote-entrypoint.sh'),*argv[1:]],cwd=W,env=e,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE);processes.append(p)
  out,err=p.communicate(data,timeout=160)
  if out:ch.sendall(out)
  if err:ch.sendall_stderr(err)
  ch.send_exit_status(p.returncode);ch.shutdown_write();ch.close()
  deadline=time.monotonic()+10
  while t.is_active() and time.monotonic()<deadline:time.sleep(.01)
 except Exception as ex:
  log.write('SSH FIXTURE ERROR: '+repr(ex)+'\n');log.flush()
 finally:t.close();conn.close()
def serve():
 while not stop.is_set():
  try:c,_=listener.accept()
  except socket.timeout:continue
  except OSError:break
  t=threading.Thread(target=handle,args=(c,));t.start();threads.append(t)
server=threading.Thread(target=serve);server.start()
try:
 run([W/'bin/fm-lab-home.sh','create',R]);os.chmod(R/'state',0o700);run(['git','clone','--quiet','--no-hardlinks',P,Q])
 (Q/'.fm-secondmate-home').write_text('sm\n')
 for d in ('state','data','config','projects'):(Q/d).mkdir(exist_ok=True)
 (Q/'state').chmod(0o700)
 (R/'data/secondmates.md').write_text(f'- sm - Disposable SSH lab (host: fm-lab-ssh; root: {P}; home: {Q}; scope: live validation; projects: alpha; added 2026-10-31)\n')
 (R/'state/sm.meta').write_text(f'window=remote:sm\nkind=secondmate\nharness=codex\nbackend=herdr\nhome={Q}\nworktree={Q}\nproject={P}\nremote_host=fm-lab-ssh\nremote_root={P}\nremote_backend=herdr\nremote_herdr_session=fm-remote\nremote_target=fm-remote:w1:p1\n')
 # This fixture has no remote endpoint record: the real host-local state verb
 # proves missing without addressing any Herdr session, pane or default fleet.
 out=run([P/'bin/fm-on.sh','sm','fm-remote-secondmate-control.sh','state','sm']).stdout
 assert out.strip()=='missing',out
 now=int(time.time());(R/'state/.secondmate-relaunch-sm').write_text(''.join(f'{now}\tattempt\n' for _ in range(3)))
 (R/'config/supervision-host').touch()
 we=env.copy();we.update(FM_POLL='1',FM_SECONDMATE_LIVENESS_SECS='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
 with (E/'live-remote-watch.log').open('w') as f:
  p=subprocess.Popen([str(P/'bin/fm-watch.sh')],cwd=W,env=we,stdout=f,stderr=subprocess.STDOUT);processes.append(p);rc=p.wait(timeout=50)
 assert rc==0
 marker=R/'state/.secondmate-relaunch-bound-sm';assert marker.exists()
 log.write('REAL WATCHER PARK RECORD: '+marker.read_text());log.flush()
 for script,value in [('fm-config-push.sh','codex'),('fm-bootstrap.sh','claude')]:
  # An owed reread from before parking must be discharged, never retried.
  run(['bash','-c','. "$1/bin/fm-secondmate-nudge-lib.sh"; fm_secondmate_nudge_write "$FM_HOME/state" sm "$2" "" remote "$FM_REMOTE_SECOND_MATE_NUDGE_MESSAGE" 1 1','_',str(P),str(Q)])
  (R/'config/crew-harness').write_text(value+'\n')
  if script=='fm-bootstrap.sh':
   args=['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$STATE/.secondmate-liveness-sm.lock"; trap \'fm_lock_release "$STATE/.secondmate-liveness-sm.lock"\' EXIT; "$1/bin/fm-bootstrap.sh"','_',str(P)]
  else:args=[P/'bin'/script]
  out=run(args,timeout=180,extra={'STATE':str(R/'state')}).stdout
  assert 'parked, skipped' in out,out
  assert (Q/'config/crew-harness').read_text().strip()==value
  assert not list((Q/'state').rglob('*.msg')),'parked remote steering inbox was filled'
  assert not (R/'state/.secondmate-nudge-pending/sm.pending').exists(),'remote retry marker retained'
  log.write(f'OBSERVE {script}: remote config={value}; remote inbox messages=0; pending retry removed; parked notice skipped\n');log.flush()
  results.append({'scenario':f'{script} updates a remote parked home over real SSH without a notice or retry','result':'pass','live':True})
 # With an invalid endpoint record the real state consumer must return
 # unverified. Configuration still converges; failed notification retains an
 # owed retry rather than losing it by treating the park marker as sufficient.
 (Q/'state/parent-route').mkdir(exist_ok=True)
 (Q/'state/parent-route/sm.meta').write_text('invalid endpoint record\n')
 for script,value in [('fm-config-push.sh','codex'),('fm-bootstrap.sh','claude')]:
  (R/'config/crew-harness').write_text(value+'\n')
  if script=='fm-bootstrap.sh':
   args=['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$STATE/.secondmate-liveness-sm.lock"; trap \'fm_lock_release "$STATE/.secondmate-liveness-sm.lock"\' EXIT; "$1/bin/fm-bootstrap.sh"','_',str(P)]
  else:args=[P/'bin'/script]
  p=run(args,timeout=180,check=False,extra={'STATE':str(R/'state')})
  assert 'parked, skipped' not in p.stdout,p.stdout
  assert (Q/'config/crew-harness').read_text().strip()==value
  retry=R/'state/.secondmate-nudge-pending/sm.pending'
  assert retry.exists(),list((R/'state/.secondmate-nudge-pending').glob('*'))
  assert 'owed=1' in retry.read_text(),retry.read_text()
  log.write(f'OBSERVE {script}: unverified endpoint was not skipped; remote config={value}; reread attempted; durable obligation retained:\n'+retry.read_text());log.flush()
  results.append({'scenario':f'{script} retains the reread obligation when a remote endpoint is uncertain','result':'pass','live':True})
except Exception as ex:
 log.write('DRIVER ERROR: '+repr(ex)+'\n');log.flush();results.append({'scenario':'driver','result':'fail','error':repr(ex)});raise
finally:
 # Stop the disposable remote job supervisor through its identity-checked owner.
 if (J/'worker.lock').exists():
  run(['bash','-c','. "$1/bin/fm-remote-job-lib.sh"; if fm_remote_job_recorded_owner_alive "$2/worker.lock"; then fm_remote_job_stop_worker_tree "$FM_REMOTE_JOB_RECORDED_PID"; fi','_',str(P),str(J)],check=False,timeout=20)
 if R.exists():run([P/'bin/fm-procevent.sh','sweep-home'],check=False,timeout=20)
 stop.set();listener.close();server.join(timeout=10)
 for t in threads:t.join(timeout=10)
 for p in processes:
  if p.poll() is None:p.terminate();p.wait(timeout=10)
 (E/'live-remote-results.json').write_text(json.dumps(results,indent=2)+'\n')
 for root in (R,Q,F):
  if root.exists():
   for d,_,_ in os.walk(root):os.chmod(d,os.stat(d).st_mode|0o700)
   shutil.rmtree(root)
 log.close()
