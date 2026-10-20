import os, pathlib, subprocess, json, time
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M5CC9CSNBN3WKTZPV33Q4FNF')
base=os.environ.copy()
for k in list(base):
 if k.startswith('FM_') or k in ['TMUX','TMUX_TMPDIR']: base.pop(k,None)
report=[]
def run(cmd,env,timeout=45):
 p=subprocess.run(cmd,env=env,text=True,capture_output=True,timeout=timeout)
 if p.returncode: raise RuntimeError(str(cmd)+'\n'+p.stdout+p.stderr)
 return p.stdout,p.stderr
for name in ['sweep','failure','rejection','merged']:
 lab=R/'.test-watch-live'/name
 run(['bin/fm-lab-home.sh','create',str(lab)],base)
 state=lab/'state'
 env=base|{'FM_HOME':str(lab),'TMUX':str(lab/'absent-socket')+',0,0','FM_POLL':'1','FM_SIGNAL_GRACE':'1','FM_CHECK_INTERVAL':'3600','FM_HEARTBEAT':'9999999999'}
 def check(id,body,register=True):
  p=state/(id+'.check.sh'); p.write_text('#!/usr/bin/env bash\n'+body+'\n'); p.chmod(0o700)
  if register: run(['bin/fm-check-register.sh',id],env)
 check('a-news','printf "memory-low\\n"')
 if name=='merged':
  (state/'a-merge.meta').write_text('kind=ship\nmode=no-mistakes\nworktree='+str(R)+'\n')
  (state/'a-merge.meta').chmod(0o600)
  arm=run(['bin/fm-pr-check.sh','a-merge','https://github.com/ashkonmousavi/firstmate/pull/92'],env)
  (E/'merged-arm.txt').write_text(arm[0]+arm[1])
 if name=='failure': check('b-fail','exit 7')
 if name=='rejection': check('b-untrusted','touch "'+str(lab/'UNSAFE')+'"',False)
 # Quiet check observes early result is queued, no wake/cadence yet, no later check yet.
 check('c-quiet',f'''test ! -e '{state}/.last-check' || exit 81
 test ! -e '{lab}/late' || exit 82
 grep -q memory-low '{state}/.wake-queue' || exit 83
 printf 'quiet-ran; early result already queued; cadence absent\\n' > '{lab}/quiet' ''')
 check('z-late',f'''sleep 1
 printf 'late-ran\\n' > '{lab}/late'
 printf 'disk-full\\n' ''')
 out,err=run(['bin/fm-watch.sh'],env)
 queue=(state/'.wake-queue').read_text()
 assert len(out.splitlines())==1,(name,out)
 assert 'memory-low' in queue and 'disk-full' in queue
 assert (lab/'quiet').exists() and (lab/'late').exists()
 assert (state/'.last-check').stat().st_mtime >= (lab/'late').stat().st_mtime
 if name=='failure': assert 'failed with exit 7' in queue
 if name=='rejection': assert 'rejected unauthenticated' in queue and not (lab/'UNSAFE').exists()
 if name=='merged':
  assert 'pull/92' in queue and not (state/'a-merge.check.sh').exists()
  assert 'pr=https://github.com/ashkonmousavi/firstmate/pull/92' in (state/'a-merge.meta').read_text()
 evidence='Watcher stdout (one wake):\n'+out+'\nWatcher stderr:\n'+err+'\nDurable queue:\n'+queue+'\nQuiet check observation:\n'+(lab/'quiet').read_text()+'\nCadence stamped after late check: true\n'
 if name=='sweep':
  old=(lab/'late').stat().st_mtime_ns
  p=subprocess.Popen(['bin/fm-watch.sh'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  time.sleep(3)
  assert old==(lab/'late').stat().st_mtime_ns, 'checks reran inside interval'
  if p.poll() is None: p.terminate()
  o,e=p.communicate(timeout=10)
  evidence+='\nImmediate re-arm observed for 3 seconds: late check not rerun (pending durable wakes may be replayed).\n'+o+e
 (E/(name+'.txt')).write_text(evidence)
 report.append({'scenario':name,'result':'pass'})
print(json.dumps(report,indent=2))
