import os,pathlib,subprocess,shutil,time,signal
root=pathlib.Path.cwd(); ev=pathlib.Path('~/.no-mistakes/evidence/01M6Q54Q4G4CN30RECS2RQBD3B'); scratch=root/'.gate-checkpoint-mutation'; scratch.mkdir()
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE')}; env.update(TMUX='.gate-checkpoint-mutation/absent,0,0',FM_BACKEND='tmux',FM_POLL='1',FM_CHECK_INTERVAL='0',FM_HEARTBEAT='999999')
log=open(ev/'checkpoint-mutation.log','w',buffering=1)
def note(s): print(s,file=log,flush=True)
def home(name):
 h=scratch/name; subprocess.run(['bash','bin/fm-lab-home.sh','create',str(h)],check=True,stdout=subprocess.DEVNULL,env=env); return h
def put(h,id,budget,body):
 p=h/'state'/f'{id}.check.sh'; p.write_text('#!/usr/bin/env bash\n'+(f'# FM_CHECK_TIMEOUT={budget}\n' if budget else '')+body); p.chmod(0o700)
 r=subprocess.run(['bash','bin/fm-check-register.sh',id],env=dict(env,FM_HOME=str(h)),capture_output=True,text=True); assert r.returncode==0; note(r.stdout)
children=[]
try:
 copy=scratch/'product'; shutil.copytree(root/'bin',copy/'bin')
 # The prior reviewed revision has the accepted clock and health fixes but
 # still admits the oversized lexical-first check.
 for f in ['fm-watch.sh','fm-watch-checkpoint.sh','fm-check-lib.sh']:
  (copy/'bin'/f).write_bytes(subprocess.check_output(['git','show',f'a91ca766:bin/{f}']))
 h=home('red-starvation'); put(h,'a-slow',300,'touch "$FM_HOME/slow-entered"\nsleep 200\n'); put(h,'b-fast',None,'printf "fast check ran\\n"\ntouch "$FM_HOME/fast-ran"\n')
 with open(h/'out','w') as out,open(h/'err','w') as err:
  p=subprocess.Popen(['bash',str(copy/'bin/fm-watch-checkpoint.sh'),'--seconds','180'],env=dict(env,FM_HOME=str(h)),stdout=out,stderr=err); children.append(p)
  limit=time.monotonic()+20
  while not (h/'slow-entered').exists() and p.poll() is None and time.monotonic()<limit: time.sleep(.1)
  assert (h/'slow-entered').exists() and not (h/'fast-ran').exists()
  note('RED a91ca766: --seconds 180 admitted a-slow (budget 300s, sleep 200s) before b-fast; fast output absent. Independent expectation: b-fast runs and a-slow is deferred. Stopped after observing the wrong admission.')
  wp=int((h/'state/.watch.lock/pid').read_text()); os.kill(wp,signal.SIGTERM); rc=p.wait(timeout=15); note(f'baseline checkpoint stopped exit={rc}\n'+(h/'out').read_text()+(h/'err').read_text())
 # Restore target bytes, then hand-mutate only the ordering key. Admission is
 # retained, so an oversized-only assertion would not kill this mutant.
 (copy/'bin/fm-check-lib.sh').write_bytes((root/'bin/fm-check-lib.sh').read_bytes()); (copy/'bin/fm-watch.sh').write_bytes((root/'bin/fm-watch.sh').read_bytes()); (copy/'bin/fm-watch-checkpoint.sh').write_bytes((root/'bin/fm-watch-checkpoint.sh').read_bytes())
 pth=copy/'bin/fm-watch.sh'; s=pth.read_text(); old='-k1,1n -k2,2'; assert s.count(old)==1; pth.write_text(s.replace(old,'-k2,2'))
 h=home('lexical-mutant')
 for id,budget in [('a-slow',100),('c-fast',20),('b-fast',20)]: put(h,id,budget,f'printf "%s\\n" {id} >> "$FM_HOME/order"\nprintf "%s\\n" {id}\n')
 r=subprocess.run(['bash',str(copy/'bin/fm-watch-checkpoint.sh'),'--seconds','180'],env=dict(env,FM_HOME=str(h)),text=True,capture_output=True,timeout=30)
 note(r.stdout+r.stderr+f'exit={r.returncode}'); assert r.returncode==0
 observed=(h/'order').read_text(); expected='b-fast\nc-fast\na-slow\n'; note('Lexical mutant persisted execution order:\n'+observed+'Expected by accepted budget/name contract:\n'+expected)
 assert observed!=expected and observed=='a-slow\nb-fast\nc-fast\n'; note('MUTANT REJECTED by observable execution order. Target green proof is in live-checks.log and targeted-tests.log.')
 h=home('ordinary-full-budget'); put(h,'slow',300,'printf "ordinary watcher budget=%s\\n" "$FM_CHECK_TIMEOUT"\n')
 r=subprocess.run(['bash','bin/fm-watch.sh'],env=dict(env,FM_HOME=str(h)),text=True,capture_output=True,timeout=30); note(r.stdout+r.stderr+f'exit={r.returncode}'); assert r.returncode==0 and 'ordinary watcher budget=300' in r.stdout
finally:
 for p in children:
  if p.poll() is None: p.terminate()
  try:p.wait(timeout=10)
  except subprocess.TimeoutExpired:p.kill();p.wait()
 shutil.rmtree(scratch); note('Disposable product copy and homes removed; child exit statuses collected.'); log.close()
