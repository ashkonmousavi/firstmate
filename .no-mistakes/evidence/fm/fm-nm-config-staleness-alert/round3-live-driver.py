import ctypes, datetime as dt, json, os, pwd, selectors, shlex, signal, socket, subprocess as sp, threading, time
from pathlib import Path
root=Path.cwd(); lab=root/'.staleness-lab'; ev=Path('/home/tegris/.no-mistakes/evidence/01M43P3QK7WHEXNJJNX0D6ME6M')
helper=root/'bin/fm-nm-config-staleness-check.sh'; children=[]; logs=[]; results={}
env=dict(os.environ)
for key in ('FM_TEST_SEAM','FM_NM_PROC_ROOT','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_HOME'):
 env.pop(key,None)

def run(args, **kw): return sp.run(list(map(str,args)),check=True,capture_output=True,text=True,env=env,**kw)
def launch(args, logname, extra=None):
 f=open(ev/logname,'w'); logs.append(f)
 p=sp.Popen(list(map(str,args)),env=extra or env,stdout=f,stderr=f,start_new_session=True); children.append(p); return p
homes={m:lab/m for m in ('pc','server','zenbook','clock')}; starts={}; originals={}; daemons={}
def start(m):
 h=homes[m]; h.mkdir(exist_ok=True)
 p=launch(['no-mistakes','daemon','run','--root',h],f'round3-daemon-{m}-{len(children)}.log'); daemons[m]=p
 deadline=time.monotonic()+10
 while not (h/'socket').exists():
  if p.poll() is not None or time.monotonic()>deadline: raise RuntimeError('daemon launch failed '+m)
  time.sleep(.03)
 r=json.loads((h/'daemon.pid').read_text()); starts[m]=int(dt.datetime.fromisoformat(r['started_at'].replace('Z','+00:00')).timestamp())*10**9
 originals[m]=((h/'daemon.pid').read_bytes(),(h/'config.yaml').read_bytes()); return r

def sample(m, home=None):
 r=json.loads(run([helper,home or homes[m],m]).stdout); print('SAMPLE',m,json.dumps(r),flush=True); return r

def timeconfig(m,delta): os.utime(homes[m]/'config.yaml',ns=(starts[m]+delta,)*2)
def result(name, fn):
 try: fn(); results[name]='pass'; print('PASS',name,flush=True)
 except Exception as e: results[name]='fail'; print('FAIL',name,repr(e),flush=True)

clockrows=[]; clockthread=None
try:
 for m in homes: start(m)
 timeconfig('clock',1)
 clockraw=originals['clock'][0]; clockpid=json.loads(clockraw)['pid']; clockticks=Path(f'/proc/{clockpid}/stat').read_text().rsplit(') ',1)[1].split()[19]
 def trackclock():
  for i in range(70):
   boot=int(next(l.split()[1] for l in Path('/proc/stat').read_text().splitlines() if l.startswith('btime ')))
   r=json.loads(run([helper,homes['clock'],'pc']).stdout)
   fixed=(homes['clock']/'daemon.pid').read_bytes()==clockraw and (homes['clock']/'config.yaml').stat().st_mtime_ns==starts['clock']+1 and Path(f'/proc/{clockpid}/stat').read_text().rsplit(') ',1)[1].split()[19]==clockticks
   clockrows.append(dict(sample=i,btime=boot,status=r['status'],identity_and_config_fixed=fixed,observation=r))
   if r['status']!='stale': break
   time.sleep(1)
 clockthread=threading.Thread(target=trackclock); clockthread.start()
 def compare():
  for delta,expect in ((1,'stale'),(0,'current'),(-1,'current')):
   timeconfig('pc',delta); assert sample('pc')['status']==expect
 result('strict newer equal older',compare)
 def readonly():
  libc=ctypes.CDLL(None,use_errno=True); fd=libc.inotify_init1(os.O_NONBLOCK); assert fd>=0
  for name in ('config.yaml','socket'): assert libc.inotify_add_watch(fd,os.fsencode(homes['pc']/name),0x20|0x1|0x2)>=0
  try:
   for m in ('pc','server','zenbook'): sample(m)
   try: events=os.read(fd,65536)
   except BlockingIOError: events=b''
   assert not events
  finally: os.close(fd)
  print('No OPEN/ACCESS/MODIFY inotify events on config or daemon control socket',flush=True)
 result('sampler read only',readonly)
 def negative():
  h=homes['pc']; good=originals['pc'][0]; r=json.loads(good)
  bad=[b'123',json.dumps({'pid':-1,'started_at':r['started_at']}).encode(),json.dumps({'pid':r['pid'],'started_at':'invalid'}).encode(),json.dumps({'pid':r['pid'],'started_at':'2000-01-01T00:00:00Z'}).encode(),json.dumps({'pid':os.getpid(),'started_at':r['started_at']}).encode(),json.dumps({'pid':2147483647,'started_at':r['started_at']}).encode()]
  try:
   for b in bad: (h/'daemon.pid').write_bytes(b); assert sample('pc')['status']=='unavailable'
  finally: (h/'daemon.pid').write_bytes(good)
  cfg=h/'config.yaml'
  cfg.chmod(0); assert sample('pc')['status']=='unavailable'; cfg.chmod(0o600)
  cfg.rename(h/'saved'); cfg.symlink_to(h/'saved')
  try: assert sample('pc')['status']=='unavailable'
  finally: cfg.unlink(); (h/'saved').rename(cfg)
  (h/'daemon.pid').unlink()
  try: assert sample('pc')['status']=='unavailable'
  finally: (h/'daemon.pid').write_bytes(good)
 result('untrusted metadata unavailable',negative)
 def race():
  h=homes['pc']; cfg=h/'config.yaml'; stop=threading.Event()
  def mutate():
   while not stop.is_set():
    os.utime(cfg,ns=(starts['pc']+1,)*2); os.utime(cfg,ns=(starts['pc']+2,)*2)
  t=threading.Thread(target=mutate); t.start()
  try: observed=[sample('pc')['status'] for _ in range(12)]
  finally: stop.set(); t.join()
  assert 'unavailable' in observed; print('Racing metadata results:',observed,flush=True)
 result('changing config unavailable',race)
 # Establish two disposable SSH servers with fixture-owned keys/configuration.
 for name in ('client-key','host-key'): run(['ssh-keygen','-q','-t','ed25519','-N','','-f',lab/name])
 ports={}; user=pwd.getpwuid(os.getuid()).pw_name
 for m in ('server','zenbook'):
  with socket.socket() as s: s.bind(('127.0.0.1',0)); ports[m]=s.getsockname()[1]
  wrapper=lab/(m+'-ssh-command.sh')
  wrapper.write_text('#!/bin/bash\nprintf "%s\\n" "$SSH_ORIGINAL_COMMAND" >> '+shlex.quote(str(lab/'ssh-command.log'))+'\nif [ -f '+shlex.quote(str(lab/('hang-'+m)))+' ]; then\n case "$SSH_ORIGINAL_COMMAND" in *fm-nm-config-staleness-check*) phase=metadata;; *) phase=health;; esac\n echo $$ > '+shlex.quote(str(lab/('pending-'+m)))+'-$phase\n sleep 60\nfi\nexec /bin/bash -c "$SSH_ORIGINAL_COMMAND"\n'); wrapper.chmod(0o700)
  cfg=lab/(m+'-sshd.conf'); cfg.write_text(f'Port {ports[m]}\nListenAddress 127.0.0.1\nHostKey {lab}/host-key\nPidFile {lab}/{m}-sshd.pid\nAuthorizedKeysFile {lab}/client-key.pub\nStrictModes no\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nAllowUsers {user}\nForceCommand {wrapper}\n')
  sshenv=dict(env,LD_LIBRARY_PATH=f'{lab}/ssh/lib/x86_64-linux-gnu:{lab}/ssh/usr/lib/x86_64-linux-gnu')
  p=launch([lab/'ssh/usr/sbin/sshd','-D','-e','-f',cfg],f'round3-sshd-{m}.log',sshenv); time.sleep(.2); assert p.poll() is None
 client=lab/'ssh-client.conf'; client.write_text(''.join(f'Host fixture-{m}\n HostName 127.0.0.1\n Port {ports[m]}\n User {user}\n IdentityFile {lab}/client-key\n IdentitiesOnly yes\n UserKnownHostsFile {lab}/known-hosts\n StrictHostKeyChecking accept-new\n' for m in ports))
 for m in ports:
  r=run(['ssh','-F',client,'-o','BatchMode=yes','fixture-'+m,f'{helper} {homes[m]} {m}']); print('AUTHENTICATED LOOPBACK SSH',m,r.stdout.strip(),flush=True)
 home=lab/'home'; run(['bash',root/'bin/fm-lab-home.sh','create',home]); state=home/'state'
 (state/'lane.meta').write_text('disposable\n'); (state/'lane.status').write_text('working: disposable lab\n')
 content=(root/'tests/fixtures/server-idle-watch.check.sh').read_text()
 content=content.replace('ssh -o BatchMode=yes',f'ssh -F {shlex.quote(str(client))} -o BatchMode=yes').replace('sudo -n -u qcrew ','').replace('pgrep -u qcrew',f'pgrep -u {os.getuid()}').replace('pgrep -u zcrew',f'pgrep -u {os.getuid()}')
 for a,b in (('/fixture-server/fm-home/state',state),('/fixture-server/firstmate/bin/fm-nm-config-staleness-check.sh',helper),('/fixture-zenbook/firstmate/bin/fm-nm-config-staleness-check.sh',helper),('/fixture-server/.no-mistakes',homes['server']),('/fixture-zenbook/.no-mistakes',homes['zenbook'])): content=content.replace(a,str(b))
 check=state/'server-idle-watch.check.sh'; check.write_text(content); check.chmod(0o700)
 checkenv=dict(env,FM_HOME=str(home),STATE=str(state),NM_HOME=str(homes['pc']),NM_HELPER=str(helper))
 p=sp.run(['bash',str(root/'bin/fm-check-register.sh'),'server-idle-watch'],env=checkenv,capture_output=True,text=True,check=True); print(p.stdout,flush=True)
 script=f'. {shlex.quote(str(root/"bin/fm-pr-lib.sh"))}; . {shlex.quote(str(root/"bin/fm-check-lib.sh"))}; fm_custom_check_snapshot_prepare "$STATE" server-idle-watch || exit; bash "$FM_CUSTOM_CHECK_SNAPSHOT"; r=$?; fm_custom_check_snapshot_cleanup; exit "$r"'
 prefix='server-idle-watch: no-mistakes config newer than running daemon on: '
 def checkrun(name):
  (state/'.server-idle-watch-last-run').unlink(missing_ok=True)
  r=sp.run(['timeout','-k','1','30','bash','-c',script],env=checkenv,capture_output=True,text=True,timeout=35)
  print('CHECK',name,'exit',r.returncode,'\n'+r.stdout,flush=True); assert r.returncode==0,r.stderr
  for l in r.stdout.splitlines():
   if l.startswith(prefix): assert l[len(prefix):].split(', ')==sorted(set(l[len(prefix):].split(', ')))
  return r.stdout
 def episodes():
  for m,d in (('pc',1),('server',-1),('zenbook',0)): timeconfig(m,d)
  assert checkrun('pc stale server older zenbook equal').strip()==prefix+'pc'
  assert not checkrun('unchanged pc')
  timeconfig('server',2); assert prefix+'pc, server' in checkrun('server stale too')
  assert not checkrun('unchanged pc server')
  timeconfig('pc',-1); out=checkrun('pc clear server retained'); assert prefix+'server' in out and prefix+'pc' not in out
  assert not checkrun('unchanged retained server')
  timeconfig('server',-1); assert not checkrun('all clear')
  timeconfig('pc',3); assert prefix+'pc' in checkrun('later stale evidence')
  assert not checkrun('later unchanged')
 result('registered check sorted dedup clear rewarning',episodes)
 def restart():
  timeconfig('pc',3); timeconfig('server',3); checkrun('arm before pc replacement')
  old=daemons['pc']; os.killpg(old.pid,signal.SIGTERM); old.wait(timeout=4)
  oldpid=json.loads(originals['pc'][0])['pid']; r=start('pc'); assert r['pid']!=oldpid; timeconfig('pc',-1)
  out=checkrun('real pc daemon replacement'); assert prefix+'server' in out and prefix+'pc' not in out
 result('real daemon replacement clears only pc',restart)
 def partial():
  for m in ('pc','server'): timeconfig(m,3)
  good=(homes['zenbook']/'daemon.pid').read_bytes(); (homes['zenbook']/'daemon.pid').write_bytes(b'legacy-pid\n')
  (state/'.server-idle-watch-nm-config-episode').unlink(missing_ok=True)
  try:
   out=checkrun('zenbook unavailable'); assert prefix+'pc, server' in out and 'observation unavailable on: zenbook' in out
  finally: (homes['zenbook']/'daemon.pid').write_bytes(good)
 result('unknown remote preserves stale peers',partial)
 for m in ('server','zenbook'):
  def hang(m=m):
   # Refresh disposable identities to keep unrelated host clock movement separate.
   for name in ('pc','server','zenbook'):
    p=daemons[name]; os.killpg(p.pid,signal.SIGTERM); p.wait(timeout=4); start(name); timeconfig(name,3)
   for name in ('.server-idle-watch-nm-config-episode','.server-idle-watch-last-run'): (state/name).unlink(missing_ok=True)
   flag=lab/('hang-'+m); flag.touch(); began=time.monotonic()
   p=sp.Popen(['timeout','-k','1','30','bash','-c',script],env=checkenv,stdout=sp.PIPE,stderr=sp.PIPE,start_new_session=True); children.append(p)
   early=b''; other='zenbook' if m=='server' else 'server'; expected=(prefix+'pc, '+other).encode()
   with selectors.DefaultSelector() as sel:
    sel.register(p.stdout,selectors.EVENT_READ)
    while time.monotonic()-began<5 and expected+b'\n' not in early:
     if sel.select(.1):
      chunk=os.read(p.stdout.fileno(),4096)
      if not chunk: break
      early+=chunk
   prompt=time.monotonic()-began; pending=[]
   for phase in ('health','metadata'):
    try: os.kill(int((lab/('pending-'+m+'-'+phase)).read_text()),0); pending.append(phase)
    except (OSError,ValueError): pass
   rest,err=p.communicate(timeout=30); out=(early+rest).decode(); finished=time.monotonic()-began; flag.unlink()
   print(f'HANG {m}: stdout {prompt:.3f}s; live pending phases={pending}; complete {finished:.3f}s; exit={p.returncode}\n{out}',flush=True)
   assert expected+b'\n' in early and len(pending)==2 and p.returncode==0 and finished<20 and f'observation unavailable on: {m}' in out
  result('prompt stdout pending '+m,hang)
 def readonlycollector():
  for m in ('pc','server','zenbook'): assert (homes[m]/'config.yaml').read_bytes()==originals[m][1]
  commands=(lab/'ssh-command.log').read_text(); print('SSH command transcript:\n'+commands,flush=True)
  assert not any(x in commands for x in ('daemon restart','daemon start','daemon stop','daemon update','cat config.yaml'))
  print('Config bytes unchanged and SSH command log contains metadata/health reads only',flush=True)
 result('collector read only',readonlycollector)
 clockthread.join(timeout=75)
 print('CLOCK OBSERVATIONS\n'+json.dumps(clockrows,indent=2),flush=True)
 if any(r['status']!='stale' and r['identity_and_config_fixed'] for r in clockrows): results['unchanged daemon host clock']='fail'
 else: results['unchanged daemon host clock']='untested (no sufficiently large natural clock movement)'
 # Independently re-drive the public episode using the current clock observation.
 r=clockrows[-1]['observation']; obs=json.dumps(r)+'\n'+''.join(json.dumps(dict(schema='fm-nm-config-age/1',machine=m,status='unavailable'))+'\n' for m in ('server','zenbook'))
 r=run([helper,'--episode',lab/'clock-episode'],input=obs); print('CLOCK FRESH EPISODE\n'+r.stdout,flush=True)
finally:
 if clockthread is not None and clockthread.is_alive(): clockthread.join(timeout=75)
 for p in reversed(children):
  if p.poll() is None:
   try: os.killpg(p.pid,signal.SIGTERM)
   except ProcessLookupError: pass
   try: p.wait(timeout=3)
   except sp.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
 for f in logs: f.close()
 (ev/'round3-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
 print('RESULTS',json.dumps(results),flush=True)
