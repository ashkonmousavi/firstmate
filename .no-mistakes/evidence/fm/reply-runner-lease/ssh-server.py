import os, sys, socket, threading, subprocess, shlex, time
sys.path.insert(0, '.test-phase/python')
import paramiko
from pathlib import Path
base=Path('.test-phase').absolute()
key=paramiko.RSAKey.generate(2048)
client=paramiko.RSAKey.generate(2048)
client.write_private_key_file(str(base/'client-key'))
os.chmod(base/'client-key',0o600)
listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(32)
port=listener.getsockname()[1]
(base/'known_hosts').write_text(f'[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n')
(base/'ssh-config').write_text(f'Host lab-remote\n HostName 127.0.0.1\n Port {port}\n User fm-lab\n IdentityFile {base}/client-key\n IdentitiesOnly yes\n UserKnownHostsFile {base}/known_hosts\n StrictHostKeyChecking yes\n LogLevel ERROR\n')
class Server(paramiko.ServerInterface):
 def check_auth_publickey(self,user,k): return paramiko.AUTH_SUCCESSFUL if user=='fm-lab' and k==client else paramiko.AUTH_FAILED
 def get_allowed_auths(self,user): return 'publickey'
 def check_channel_request(self,kind,i): return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
 def check_channel_exec_request(self,ch,cmd):
  self.cmd=cmd.decode(); self.event.set(); return True
 def __init__(self): self.event=threading.Event()
def serve(sock):
 tr=paramiko.Transport(sock)
 try:
  tr.add_server_key(key); s=Server(); tr.start_server(server=s)
  ch=tr.accept(15)
  if not ch or not s.event.wait(15): return
  args=shlex.split(s.cmd)
  if not args or args[0]!='fm-remote-entrypoint.sh': ch.send_exit_status(64); return
  data=bytearray()
  while True:
   b=ch.recv(65536)
   if not b: break
   data.extend(b)
  env=os.environ.copy()
  for k in list(env):
   if k.startswith(('FM_', 'NO_MISTAKES', 'CLAUDE')): del env[k]
  env.update(FM_REMOTE_JOB_STATE_ROOT=str(base/'remote-jobs'),FM_LAB_ACCOUNT_HOME=str(base/'account'),LD_PRELOAD=str(base/'account-home.so'),TMPDIR=str(base/'tmp'))
  p=subprocess.Popen([str(base/'source/bin/fm-remote-entrypoint.sh'),*args[1:]],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  out,err=p.communicate(bytes(data),timeout=100)
  if out: ch.sendall(out)
  if err: ch.sendall_stderr(err)
  ch.send_exit_status(p.returncode)
 except Exception as ex: print(type(ex).__name__,str(ex),flush=True)
 finally:
  time.sleep(.1); tr.close()
print(f'Listening on loopback SSH port {port}',flush=True)
(base/'ssh-ready').touch()
while True:
 conn,_=listener.accept(); threading.Thread(target=serve,args=(conn,),daemon=True).start()
