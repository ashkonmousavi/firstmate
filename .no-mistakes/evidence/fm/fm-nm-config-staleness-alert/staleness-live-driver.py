import ctypes, datetime as dt, hashlib, json, os, pwd, selectors, shlex, shutil, signal, socket, subprocess as sp, sys, threading, time
from pathlib import Path
root=Path.cwd(); lab=root/'.sl'; evidence=Path('/home/tegris/.no-mistakes/evidence/01M43P3QK7WHEXNJJNX0D6ME6M')
helper=root/'bin/fm-nm-config-staleness-check.sh'; children=[]; logs=[]; results=[]
env=dict(os.environ); env.pop('FM_TEST_SEAM',None); env.pop('FM_NM_PROC_ROOT',None)
for key in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_HOME'):
 env.pop(key,None)
def command(args, **kw): return sp.run(list(map(str,args)),check=True,text=True,capture_output=True,env=env,**kw)
def sample(home,machine='pc'):
 r=command([helper,home,machine]); obs=json.loads(r.stdout); print('SAMPLE',machine,r.stdout.strip(),flush=True); return obs
homes={'pc':lab/'nm','server':lab/'server','zenbook':lab/'zenbook'}
def start(machine):
 home=homes[machine]; home.mkdir(exist_ok=True)
 log=open(evidence/f'live-daemon-{machine}.log','w'); logs.append(log)
 p=sp.Popen(['no-mistakes','daemon','run','--root',str(home)],env=env,stdout=log,stderr=log,start_new_session=True); children.append(p)
 deadline=time.monotonic()+12
 while not (home/'socket').exists():
  if p.poll() is not None or time.monotonic()>deadline: raise RuntimeError(f'daemon {machine} unavailable')
  time.sleep(.05)
 return p
records={}; configs={}; starts={}
try:
 for name in ('nm','server','zenbook','home'):
  shutil.rmtree(lab/name,ignore_errors=True)
 for name in ('client-key','client-key.pub','host-key','host-key.pub','known-hosts','ssh-commands.log','hang-server','hang-zenbook'):
  (lab/name).unlink(missing_ok=True)
 for m in ('pc','server','zenbook'): start(m)
 for m,h in homes.items():
  records[m]=(h/'daemon.pid').read_bytes(); configs[m]=(h/'config.yaml').read_bytes()
  starts[m]=int(dt.datetime.fromisoformat(json.loads(records[m])['started_at'].replace('Z','+00:00')).timestamp())*10**9
 def settime(m,delta): os.utime(homes[m]/'config.yaml',ns=(starts[m]+delta,)*2)
 # Real Linux metadata observation, including strict nanosecond boundaries.
 for delta,status in ((1,'stale'),(0,'current'),(-1,'current')):
  settime('pc',delta); assert sample(homes['pc'])['status']==status
 results.append('PASS real daemon strict newer/equal/older comparison')
 # Observe opens of config and control socket during real samples.
 libc=ctypes.CDLL(None,use_errno=True); fd=libc.inotify_init1(os.O_NONBLOCK); assert fd>=0
 for name in ('config.yaml','socket'): assert libc.inotify_add_watch(fd,os.fsencode(homes['pc']/name),0x20|0x1|0x2)>=0
 try:
  for m in homes: sample(homes[m],m)
  try: events=os.read(fd,65536)
  except BlockingIOError: events=b''
  assert not events, 'helper opened/read/modified config or daemon socket'
 finally: os.close(fd)
 print('READ-ONLY: no config/socket open, access or modify events; daemon PID and config bytes unchanged',flush=True)
 results.append('PASS real sampler read-only config and socket inotify guard')
 # Real metadata adversaries with no fake procfs.
 h=homes['pc']; good=records['pc']; pid=json.loads(good)['pid']
 bad=[b'123',json.dumps({'pid':-1,'started_at':'2026-10-04T10:00:00Z'}).encode(),json.dumps({'pid':pid,'started_at':'invalid'}).encode(),json.dumps({'pid':pid,'started_at':'2000-01-01T00:00:00Z'}).encode(),json.dumps({'pid':os.getpid(),'started_at':json.loads(good)['started_at']}).encode(),json.dumps({'pid':2147483647,'started_at':json.loads(good)['started_at']}).encode()]
 for value in bad:
  (h/'daemon.pid').write_bytes(value); assert sample(h)['status']=='unavailable'
 (h/'daemon.pid').write_bytes(good)
 config=h/'config.yaml'; config.chmod(0); assert sample(h)['status']=='unavailable'; config.chmod(0o600)
 config.rename(h/'config.saved'); config.symlink_to(h/'config.saved'); assert sample(h)['status']=='unavailable'; config.unlink(); (h/'config.saved').rename(config)
 (h/'daemon.pid').unlink(); assert sample(h)['status']=='unavailable'; (h/'daemon.pid').write_bytes(good)
 results.append('PASS real malformed/unreadable/symlink/missing/dead/reused/wrong-process metadata unavailable')
 # Race valid file metadata while sampling the actual kernel process.
 running=True
 def mutate():
  while running:
   os.utime(config,ns=(starts['pc']+1,)*2); os.utime(config,ns=(starts['pc']+2,)*2)
 t=threading.Thread(target=mutate); t.start()
 try: statuses=[sample(h)['status'] for _ in range(15)]
 finally: running=False; t.join()
 assert 'unavailable' in statuses; print('RACING CONFIG: statuses',statuses,flush=True)
 results.append('PASS changing real config metadata is unavailable when detected')
 # Disposable SSH host/client authentication, no operator keys or configuration.
 ssh=lab/'ssh'; sshd=ssh/'usr/sbin/sshd'; identity=lab/'client-key'; hostkey=lab/'host-key'
 command(['ssh-keygen','-q','-t','ed25519','-N','','-f',identity]); command(['ssh-keygen','-q','-t','ed25519','-N','','-f',hostkey])
 user=pwd.getpwuid(os.getuid()).pw_name; ports={}
 for m in ('server','zenbook'):
  with socket.socket() as s: s.bind(('127.0.0.1',0)); ports[m]=s.getsockname()[1]
  wrapper=lab/f'{m}-command.sh'
  wrapper.write_text('#!/bin/bash\nprintf "%s\\n" "$SSH_ORIGINAL_COMMAND" >> '+shlex.quote(str(lab/'ssh-commands.log'))+'\nif [ -f '+shlex.quote(str(lab/f'hang-{m}'))+' ]; then sleep 60; fi\nexec /bin/bash -c "$SSH_ORIGINAL_COMMAND"\n'); wrapper.chmod(0o700)
  cfg=lab/f'sshd-{m}.conf'
  cfg.write_text(f'Port {ports[m]}\nListenAddress 127.0.0.1\nHostKey {hostkey}\nPidFile {lab}/sshd-{m}.pid\nAuthorizedKeysFile {identity}.pub\nStrictModes no\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nAllowUsers {user}\nForceCommand {wrapper}\n')
  sshenv=dict(env,LD_LIBRARY_PATH=f'{ssh}/lib/x86_64-linux-gnu:{ssh}/usr/lib/x86_64-linux-gnu')
  log=open(evidence/f'live-sshd-{m}.log','w'); logs.append(log)
  p=sp.Popen([str(sshd),'-D','-e','-f',str(cfg)],env=sshenv,stdout=log,stderr=log,start_new_session=True); children.append(p)
  time.sleep(.2)
  assert p.poll() is None, f'sshd {m} failed; see live-sshd-{m}.log'
 client=lab/'ssh-client.conf'; client.write_text(''.join(f'Host fixture-{m}\n  HostName 127.0.0.1\n  Port {ports[m]}\n  User {user}\n  IdentityFile {identity}\n  IdentitiesOnly yes\n  UserKnownHostsFile {lab}/known-hosts\n  StrictHostKeyChecking accept-new\n' for m in ports))
 for m in ports:
  r=command(['ssh','-F',client,'-o','BatchMode=yes',f'fixture-{m}',f'{helper} {homes[m]} {m}']); print('AUTHENTICATED SSH',m,r.stdout.strip(),flush=True); assert json.loads(r.stdout)['machine']==m
 # Adapt documented private paths/auth transport only. Check logic is unchanged.
 home=lab/'home'; command(['bash',root/'bin/fm-lab-home.sh','create',home]); state=home/'state'
 (state/'lane.meta').write_text('fixture-owned metadata\n'); (state/'lane.status').write_text('working: live disposable lab\n')
 content=(root/'tests/fixtures/server-idle-watch.check.sh').read_text()
 content=content.replace('ssh -o BatchMode=yes',f'ssh -F {shlex.quote(str(client))} -o BatchMode=yes')
 content=content.replace('sudo -n -u qcrew ','').replace('pgrep -u qcrew','pgrep -u '+str(os.getuid())).replace('pgrep -u zcrew','pgrep -u '+str(os.getuid()))
 content=content.replace('/fixture-server/fm-home/state',str(state)).replace('/fixture-server/firstmate/bin/fm-nm-config-staleness-check.sh',str(helper)).replace('/fixture-zenbook/firstmate/bin/fm-nm-config-staleness-check.sh',str(helper)).replace('/fixture-server/.no-mistakes',str(homes['server'])).replace('/fixture-zenbook/.no-mistakes',str(homes['zenbook']))
 check=state/'server-idle-watch.check.sh'; check.write_text(content); check.chmod(0o700)
 checkenv=dict(env,FM_HOME=str(home),STATE=str(state),NM_HOME=str(homes['pc']),NM_HELPER=str(helper))
 sp.run(['bash',str(root/'bin/fm-check-register.sh'),'server-idle-watch'],env=checkenv,check=True,capture_output=True,text=True)
 script=f'. {shlex.quote(str(root/"bin/fm-pr-lib.sh"))}; . {shlex.quote(str(root/"bin/fm-check-lib.sh"))}; fm_custom_check_snapshot_prepare "$STATE" server-idle-watch || exit; bash "$FM_CUSTOM_CHECK_SNAPSHOT"; r=$?; fm_custom_check_snapshot_cleanup; exit "$r"'
 def checkrun(name):
  (state/'.server-idle-watch-last-run').unlink(missing_ok=True)
  r=sp.run(['timeout','-k','1','30','bash','-c',script],env=checkenv,capture_output=True,text=True,timeout=35)
  print('CHECK',name,'exit',r.returncode,'\n'+r.stdout,flush=True); assert r.returncode==0,r.stderr; return r.stdout
 warning='server-idle-watch: no-mistakes config newer than running daemon on: '
 settime('pc',1); settime('server',-1); settime('zenbook',0)
 assert checkrun('pc stale, server older, zenbook equal').strip()==warning+'pc'
 assert not checkrun('unchanged episode')
 settime('server',2); assert warning+'pc, server' in checkrun('server becomes stale')
 assert not checkrun('unchanged two-machine episode')
 settime('pc',-1); assert checkrun('only pc clears').strip()==warning+'server'
 assert not checkrun('remaining server unchanged')
 settime('server',-1); assert not checkrun('all clear')
 settime('pc',3); assert checkrun('later config change').strip()==warning+'pc'
 assert not checkrun('later episode unchanged')
 results.append('PASS real SSH registered check strict comparison, sorted affected set, dedup, independent clear and rewarning')
 # Healthy restart really changes daemon identity and clears only that host.
 settime('server',2); checkrun('arm pc+server before restart')
 pcold=json.loads((homes['pc']/'daemon.pid').read_text())
 os.kill(pcold['pid'],signal.SIGTERM)
 for _ in range(100):
  if not (homes['pc']/'socket').exists(): break
  time.sleep(.05)
 start('pc'); starts['pc']=int(dt.datetime.fromisoformat(json.loads((homes['pc']/'daemon.pid').read_text())['started_at'].replace('Z','+00:00')).timestamp())*10**9; settime('pc',-1)
 assert json.loads((homes['pc']/'daemon.pid').read_text())['pid']!=pcold['pid']
 assert checkrun('actual pc restart clears only pc').strip()==warning+'server'
 results.append('PASS actual daemon restart resets only matching host evidence')
 # Prompt stdout under actual authenticated SSH sessions that stall.
 for m in ('server','zenbook'):
  for host in homes: settime(host,3)
  (state/'.server-idle-watch-nm-config-episode').unlink(missing_ok=True); (state/'.server-idle-watch-last-run').unlink(missing_ok=True)
  (lab/f'hang-{m}').touch(); began=time.monotonic()
  p=sp.Popen(['timeout','-k','1','30','bash','-c',script],env=checkenv,stdout=sp.PIPE,stderr=sp.PIPE,start_new_session=True); children.append(p)
  early=b''; other='zenbook' if m=='server' else 'server'; expected=(warning+'pc, '+other).encode()
  with selectors.DefaultSelector() as sel:
   sel.register(p.stdout,selectors.EVENT_READ)
   while time.monotonic()-began<5 and expected+b'\n' not in early:
    if sel.select(.1): early+=os.read(p.stdout.fileno(),4096)
  prompt=time.monotonic()-began; assert expected+b'\n' in early and p.poll() is None, f'{m} expected {expected!r}, observed {early!r}'
  rest,err=p.communicate(timeout=25); out=(early+rest).decode(); finished=time.monotonic()-began
  (lab/f'hang-{m}').unlink(); assert p.returncode==0 and f'observation unavailable on: {m}' in out and finished<20
  print(f'LIVE SSH HANG {m}: confirmed stdout {prompt:.3f}s, still pending=True, completion {finished:.3f}s\n{out}',flush=True)
 results.append('PASS prompt stale emission and bounded completion with each real SSH remote stalled')
 # Unknown remote identity preserves other confirmed machines.
 for m in homes:
  sample(homes[m],m)
  record=json.loads((homes[m]/'daemon.pid').read_text()); pid=record['pid']; fields=Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split(); ticks=int(fields[19]); boot=int(next(line.split()[1] for line in Path('/proc/stat').read_text().splitlines() if line.startswith('btime '))); birth=boot*10**9+ticks*10**9//os.sysconf('SC_CLK_TCK'); print('IDENTITY DEBUG',m,'record',record,'btime',boot,'ticks',ticks,'birth_ns',birth,'delta_ns',starts[m]-birth,'comm',Path(f'/proc/{pid}/comm').read_text().strip(),'state',fields[0],flush=True)
  print('RECORD',m,(homes[m]/'daemon.pid').read_text(),flush=True)
 (homes['zenbook']/'daemon.pid').write_text('legacy-pid\n'); (state/'.server-idle-watch-nm-config-episode').unlink(missing_ok=True)
 out=checkrun('unavailable zenbook preserves stale pc/server'); print('SERVER DIRECT SSH',command(['ssh','-F',client,'-o','BatchMode=yes','fixture-server',f'{helper} {homes["server"]} server']).stdout,flush=True); assert warning+'pc' in out and 'observation unavailable on: zenbook' in out
 (homes['zenbook']/'daemon.pid').write_bytes(records['zenbook'])
 results.append('PASS real SSH partial unknown remains visible without suppressing confirmed stale pc')
 for m,h in homes.items(): assert (h/'config.yaml').read_bytes()==configs[m]
 cmds=(lab/'ssh-commands.log').read_text(); assert not any(token in cmds for token in ('daemon restart','daemon stop','daemon start','daemon update','cat config.yaml'))
 print('READ-ONLY CHECK: fixture config bytes unchanged; actual SSH command log has no daemon lifecycle or config-value reads',flush=True)
 results.append('PASS real registered check read-only sampling and alerting')
 print('\n'.join(results),flush=True)
finally:
 for p in reversed(children):
  if p.poll() is None:
   try: os.killpg(p.pid,signal.SIGTERM)
   except ProcessLookupError: pass
   try: p.wait(timeout=3)
   except sp.TimeoutExpired:
    os.killpg(p.pid,signal.SIGKILL); p.wait()
 # The first pc daemon was started by the outer test shell.
 path=homes['pc']/'daemon.pid'
 if path.exists():
  try: os.kill(json.loads(path.read_text())['pid'],signal.SIGTERM)
  except (OSError,ValueError): pass
 for f in logs: f.close()
