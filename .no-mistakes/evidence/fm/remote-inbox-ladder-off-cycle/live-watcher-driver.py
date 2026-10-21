import os,pathlib,socket,threading,subprocess,time,signal,json,shutil
root=pathlib.Path.cwd(); lab=root/'.live-inbox'; lab.mkdir(exist_ok=False)
ev=pathlib.Path('~/.no-mistakes/evidence/01M5EDB3MBWCZX063DZJ8QGKGJ')
listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(); listener.settimeout(.2)
connections=[]; stop=False

def accept():
 while not stop:
  try:
   c,_=listener.accept(); connections.append((time.monotonic(),c))
  except socket.timeout: pass
  except OSError: break
threading.Thread(target=accept,daemon=True).start()
procs=[]; report=[]
try:
 home=lab/'home'; subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True,capture_output=True)
 state=home/'state'; (home/'data/secondmates.md').write_text(f'- rsm - isolated stalled SSH (host: inbox-lab; root: {root}; home: {home}; scope: test; projects: alpha; added 2026-10-20)\n')
 (state/'rsm.meta').write_text('kind=secondmate\nharness=claude\nbackend=herdr\nwindow=fm-remote:p1\nremote_host=inbox-lab\nremote_root='+str(root)+'\nremote_backend=herdr\nremote_herdr_session=fm-remote\nremote_target=fm-remote:p1\n')
 cfg=lab/'ssh-config'; cfg.write_text(f'Host inbox-lab\n HostName 127.0.0.1\n Port {listener.getsockname()[1]}\n BatchMode yes\n IdentityAgent none\n IdentityFile none\n UserKnownHostsFile /dev/null\n GlobalKnownHostsFile /dev/null\n ConnectTimeout 18\n')
 wrapper=lab/'ssh'; wrapper.write_text('#!/bin/sh\nexec /usr/bin/ssh -F "'+str(cfg)+'" "$@"\n'); wrapper.chmod(0o755)
 env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}; env.update(FM_HOME=str(home),FM_SSH_BIN=str(wrapper),FM_POLL='1',FM_HOME_SUMMARY_INTERVAL='999999',FM_SECONDMATE_LIVENESS_SECS='99999999',FM_TASK_INBOX_GRACE_SECS='1')
 (state/'home-summary.json').write_text('{}\n')
 # Suppress unrelated liveness/summary collectors, leaving the real remote inbox pass active.
 for name in ['.secondmate-liveness-tick']:(state/name).touch()
 with (ev/'live-watcher.stdout').open('w') as out,(ev/'live-watcher.stderr').open('w') as err:
  p=subprocess.Popen(['bin/fm-watch.sh'],env=env,stdout=out,stderr=err,start_new_session=True); procs.append(p)
  start=time.monotonic(); beats=[]
  while time.monotonic()-start<28:
   beat=state/'.last-watcher-beat'
   if beat.exists():
    stamp=beat.stat().st_mtime_ns
    if not beats or beats[-1]['mtime_ns']!=stamp: beats.append({'elapsed':round(time.monotonic()-start,2),'mtime_ns':stamp,'connections':len(connections)})
   if p.poll() is not None:break
   time.sleep(.15)
  report.append({'scenario':'watcher beacon advances while real SSH is stalled before handshake','connections':len(connections),'beacon_observations':beats,'watcher_running':p.poll() is None,'ladder_lock_exists':(state/'.remote-inbox.lock').exists(),'pass':len(connections)>=1 and len(beats)>=3 and p.poll() is None})
  triage=(state/'.watch-triage.log').read_text() if (state/'.watch-triage.log').exists() else ''
  report.append({'scenario':'failed SSH handshake is logged without a stale wake and later cycles retry','triage':triage,'connections':len(connections),'wake_queue':(state/'.wake-queue').read_text() if (state/'.wake-queue').exists() else '', 'pass':'due check unreachable or failed' in triage and not (state/'.wake-queue').exists() and len(connections)>=2})
  # Capture identities and network stall evidence while the pass is in progress.
  report.append({'processes':subprocess.run(['ps','-eo','pid,ppid,args'],text=True,capture_output=True).stdout.splitlines()})
finally:
 stop=True; listener.close()
 for _,c in connections:c.close()
 for p in procs:
  try:os.killpg(p.pid,signal.SIGTERM)
  except ProcessLookupError:pass
 for p in procs:
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGKILL);p.wait()
 # Keep only owned process lines in reviewer evidence.
 for item in report:
  if 'processes' in item:item['processes']=[s for s in item['processes'] if str(lab) in s and '.live-inbox-check.py' not in s]
 (ev/'live-watcher.json').write_text(json.dumps(report,indent=2)+'\n')
 shutil.rmtree(lab)
print(json.dumps(report,indent=2))
