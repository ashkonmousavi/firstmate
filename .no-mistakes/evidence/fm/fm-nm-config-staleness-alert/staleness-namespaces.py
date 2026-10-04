import datetime as dt, json, os, pwd, shlex, signal, socket, subprocess as sp, sys, time
from pathlib import Path
root=Path.cwd(); lab=root/'.sl'; ev=Path('/home/tegris/.no-mistakes/evidence/01M43P3QK7WHEXNJJNX0D6ME6M'); helper=root/'bin/fm-nm-config-staleness-check.sh'
# --inside is init in a disposable Linux user/PID/mount namespace. Network is
# shared only to let the test client reach a loopback-only authenticated SSH port.
if len(sys.argv)>1 and sys.argv[1]=='--inside':
 home=Path(sys.argv[2]); cfg=sys.argv[3]; children=[]
 def stop(*args): raise SystemExit(0)
 signal.signal(signal.SIGTERM,stop)
 try:
  p=sp.Popen(['no-mistakes','daemon','run','--root',str(home)]); children.append(p)
  for _ in range(200):
   if (home/'socket').exists(): break
   if p.poll() is not None: raise RuntimeError('namespace daemon failed')
   time.sleep(.05)
  lib=lab/'ssh'; env=dict(os.environ,LD_LIBRARY_PATH=f'{lib}/lib/x86_64-linux-gnu:{lib}/usr/lib/x86_64-linux-gnu')
  children.append(sp.Popen([str(lib/'usr/sbin/sshd'),'-D','-e','-f',cfg],env=env))
  while all(p.poll() is None for p in children): time.sleep(.1)
 finally:
  for p in reversed(children):
   if p.poll() is None: p.terminate()
   try: p.wait(timeout=3)
   except sp.TimeoutExpired: p.kill(); p.wait()
 sys.exit(0)
children=[]; logs=[]
try:
 user=pwd.getpwuid(os.getuid()).pw_name; client=lab/'ns-client.conf'; hosts={}; sections=[]
 for name,short in (('server','u'),('zenbook','v')):
  home=lab/short; home.mkdir(); hosts[name]=home
  with socket.socket() as s: s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
  cfg=lab/f'ns-sshd-{name}.conf'; cfg.write_text(f'Port {port}\nListenAddress 127.0.0.1\nHostKey {lab}/host-key\nPidFile {lab}/ns-sshd-{name}.pid\nAuthorizedKeysFile {lab}/client-key.pub\nStrictModes no\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nAllowUsers {user}\n')
  sections.append(f'Host {name}\n  HostName 127.0.0.1\n  Port {port}\n  User {user}\n  IdentityFile {lab}/client-key\n  IdentitiesOnly yes\n  UserKnownHostsFile {lab}/ns-known-hosts\n  StrictHostKeyChecking accept-new\n')
  log=open(ev/f'namespace-{name}.log','w'); logs.append(log)
  p=sp.Popen(['unshare','--user','--map-current-user','--pid','--fork','--mount-proc','python3',str(Path(__file__)),'--inside',str(home),str(cfg)],stdout=log,stderr=log,start_new_session=True); children.append(p)
  for _ in range(200):
   if (home/'socket').exists(): break
   if p.poll() is not None: raise RuntimeError(f'{name} namespace failed')
   time.sleep(.05)
 client.write_text(''.join(sections)); time.sleep(.5)
 for name,home in hosts.items():
  record=json.loads((home/'daemon.pid').read_text()); start=int(dt.datetime.fromisoformat(record['started_at'].replace('Z','+00:00')).timestamp())*10**9
  os.utime(home/'config.yaml',ns=(start+1,)*2)
  wrong=sp.run([str(helper),str(home),name],text=True,capture_output=True,check=True)
  assert json.loads(wrong.stdout)['status']=='unavailable'; print('PC procfs rejects remote PID:',name,wrong.stdout.strip(),flush=True)
  for delta,status in ((1,'stale'),(0,'current'),(-1,'current')):
   os.utime(home/'config.yaml',ns=(start+delta,)*2)
   r=sp.run(['ssh','-F',str(client),'-o','BatchMode=yes',name,f'{shlex.quote(str(helper))} {shlex.quote(str(home))} {name}'],text=True,capture_output=True,check=True)
   obs=json.loads(r.stdout); assert obs['status']==status and obs['pid']==record['pid']; print('AUTHENTICATED HOST-LOCAL PROCFS:',name,r.stdout.strip(),flush=True)
 assert json.loads((hosts['server']/'daemon.pid').read_text())['pid']==json.loads((hosts['zenbook']/'daemon.pid').read_text())['pid']
 print('PASS independent real Linux PID namespaces reuse identical numeric daemon PID; authenticated host-local comparison succeeds, PC procfs comparison refused',flush=True)
 empty=lab/'empty'; empty.mkdir()
 r=sp.run(['unshare','--user','--map-current-user','--pid','--fork','--mount-proc',str(helper),str(empty),'pc'],text=True,capture_output=True,check=True)
 assert json.loads(r.stdout)['status']=='not_running'; print('VERIFIED ABSENT DAEMON:',r.stdout.strip(),flush=True)
 print('PASS namespace with no daemon is not_running rather than stale',flush=True)
finally:
 for p in children:
  if p.poll() is None:
   os.killpg(p.pid,signal.SIGTERM)
   try: p.wait(timeout=4)
   except sp.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
 for log in logs: log.close()
