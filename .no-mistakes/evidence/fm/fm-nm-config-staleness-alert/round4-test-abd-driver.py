import ctypes, datetime as dt, json, os, pwd, selectors, shlex, signal, socket, subprocess as sp, threading, time
from pathlib import Path
root=Path.cwd(); lab=root/'.round4-abd'; ev=Path('/home/tegris/.no-mistakes/evidence/01M43P3QK7WHEXNJJNX0D6ME6M')
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
 p=launch(['no-mistakes','daemon','run','--root',h],f'round4-test-abd-daemon-{m}-{len(children)}.log'); daemons[m]=p
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

lab.mkdir(); (lab/'ssh').symlink_to(root/'.staleness-lab/ssh',target_is_directory=True)
try:
 for m in ('pc','server','zenbook'): start(m)
 # Establish two disposable SSH servers with fixture-owned keys/configuration.
 for name in ('client-key','host-key'): run(['ssh-keygen','-q','-t','ed25519','-N','','-f',lab/name])
 ports={}; user=pwd.getpwuid(os.getuid()).pw_name
 for m in ('server','zenbook'):
  with socket.socket() as s: s.bind(('127.0.0.1',0)); ports[m]=s.getsockname()[1]
  wrapper=lab/(m+'-ssh-command.sh')
  wrapper.write_text('#!/bin/bash\nprintf "%s\\n" "$SSH_ORIGINAL_COMMAND" >> '+shlex.quote(str(lab/'ssh-command.log'))+'\nif [ -f '+shlex.quote(str(lab/('hang-'+m)))+' ]; then\n case "$SSH_ORIGINAL_COMMAND" in *fm-nm-config-staleness-check*) phase=metadata;; *) phase=health;; esac\n echo $$ > '+shlex.quote(str(lab/('pending-'+m)))+'-$phase\n sleep 60\nfi\nexec /bin/bash -c "$SSH_ORIGINAL_COMMAND"\n'); wrapper.chmod(0o700)
  cfg=lab/(m+'-sshd.conf'); cfg.write_text(f'Port {ports[m]}\nListenAddress 127.0.0.1\nHostKey {lab}/host-key\nPidFile {lab}/{m}-sshd.pid\nAuthorizedKeysFile {lab}/client-key.pub\nStrictModes no\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nAllowUsers {user}\nForceCommand {wrapper}\n')
  sshenv=dict(env,LD_LIBRARY_PATH=f'{lab}/ssh/lib/x86_64-linux-gnu:{lab}/ssh/usr/lib/x86_64-linux-gnu')
  p=launch([lab/'ssh/usr/sbin/sshd','-D','-e','-f',cfg],f'round4-test-abd-sshd-{m}.log',sshenv); time.sleep(.2); assert p.poll() is None
 client=lab/'ssh-client.conf'; client.write_text(''.join(f'Host fixture-{m}\n HostName 127.0.0.1\n Port {ports[m]}\n User {user}\n IdentityFile {lab}/client-key\n IdentitiesOnly yes\n UserKnownHostsFile {lab}/known-hosts\n StrictHostKeyChecking accept-new\n' for m in ports))
 for m in ports:
  r=run(['ssh','-F',client,'-o','BatchMode=yes','fixture-'+m,f'{helper} {homes[m]} {m}']); print('AUTHENTICATED LOOPBACK SSH',m,r.stdout.strip(),flush=True)
 home=lab/'home'; run(['bash',root/'bin/fm-lab-home.sh','create',home]); state=home/'state'
 (state/'lane.meta').write_text('disposable\n'); (state/'lane.status').write_text('working: disposable lab\n')
 content=(root/'tests/fixtures/server-idle-watch.check.sh').read_text()
 content=content.replace('/fixture-server/firstmate/bin/fm-remote-job-worker.sh',str(root/'bin/fm-remote-job-worker.sh'))
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

 def abd():
  for m in ('pc','server','zenbook'): timeconfig(m,-100000000000)
  available=int(next(line.split()[1] for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemAvailable:')))//1048576
  print('HOST MemAvailable integer GiB:',available,'; A/B need >6 GiB and cannot be forced by this disposable home',flush=True)
  results['A/B alerts when a host has room']='untested: host has less than 7 GiB available; VM/fleet memory changes out of authority'
  (state/'lane.status').write_text('working: disposable lab\n')
  workers=[]
  for i in range(3):
   account=lab/('worker-account-'+str(i)); account.mkdir()
   jobstate=account/'queue'
   extra=dict(env,HOME=str(account),FM_HOME=str(home),FM_REMOTE_JOB_STATE_ROOT=str(jobstate))
   workers.append(launch(['/bin/bash',root/'bin/fm-remote-job-worker.sh','--serve'],f'round4-test-live-worker-{i}.log',extra))
   for _ in range(100):
    if (jobstate/'worker.ready').exists(): break
    if workers[-1].poll() is not None: raise RuntimeError('real remote worker failed')
    time.sleep(.02)
  counts=run(['pgrep','-u',str(os.getuid()),'-fc','^/bin/bash '+str(root/'bin/fm-remote-job-worker.sh')+' --serve']).stdout.strip()
  print('REAL serving remote-job workers:',counts,flush=True)
  assert int(counts)==3
  out=checkrun('three serving workers alert')
  assert 'remote message helpers jammed: server=3' in out
  assert 'remote message helpers jammed:' not in checkrun('worker storm dedup')
 result('D storm alert and dedup through live SSH and real workers',abd)

finally:
 for p in reversed(children):
  if p.poll() is None:
   try: os.killpg(p.pid,signal.SIGTERM)
   except ProcessLookupError: pass
   try: p.wait(timeout=3)
   except sp.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
 for f in logs: f.close()
 (ev/'round4-test-abd-results.json').write_text(json.dumps(results,indent=2)+'\n')
 print('RESULTS',json.dumps(results),flush=True)
