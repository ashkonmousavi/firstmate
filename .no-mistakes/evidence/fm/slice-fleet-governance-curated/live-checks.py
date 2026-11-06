import os, pathlib, subprocess, time, shutil, json, re, signal
root=pathlib.Path.cwd(); evidence=pathlib.Path('~/.no-mistakes/evidence/01M6Q54Q4G4CN30RECS2RQBD3B')
lab=root/'.gate-live-checks'; lab.mkdir()
base={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE')}
# This private, absent socket prevents even read-only queries reaching fleet tmux.
base.update(TMUX='.gate-live-checks/absent,0,0',FM_BACKEND='tmux',FM_POLL='1',FM_CHECK_INTERVAL='0',FM_HEARTBEAT='999999')
records=[]
log=open(evidence/'live-checks.log','w',buffering=1)
def note(s): print(s,file=log,flush=True)
def home(name):
 p=lab/name
 subprocess.run(['bash','bin/fm-lab-home.sh','create',str(p)],check=True,stdout=subprocess.DEVNULL,env=base)
 return p
def env(h,**extra): return dict(base,FM_HOME=str(h),**extra)
def cmd(h,args,expected=0,**extra):
 t=time.monotonic(); p=subprocess.run(['bash',*args],env=env(h,**extra),text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90)
 note('$ '+' '.join(args)+f' [home={h.name}]\n'+p.stdout+p.stderr+f'exit={p.returncode}; elapsed={time.monotonic()-t:.2f}s\n')
 assert p.returncode==expected,(args,p.returncode,p.stdout,p.stderr)
 return p
def check(h,id,body):
 p=h/'state'/f'{id}.check.sh'; p.write_text('#!/usr/bin/env bash\n'+body); p.chmod(0o700)
 return p
def register(h,id): cmd(h,['bin/fm-check-register.sh',id])
def queue(h):
 p=h/'state/.wake-queue'; s=p.read_text() if p.exists() else ''; note('durable wake queue:\n'+s); return s
def scenario(name,fn):
 note('\nSCENARIO: '+name)
 try: fn(); records.append(dict(name=name,result='pass'))
 except Exception as ex: records.append(dict(name=name,result='fail',error=str(ex))); note('FAIL: '+repr(ex)); raise
children=[]
try:
 def registration():
  h=home('registration')
  for id,declaration in [('zero','# FM_CHECK_TIMEOUT=0'),('leading','# FM_CHECK_TIMEOUT=02'),('large','# FM_CHECK_TIMEOUT=86401'),('junk','# FM_CHECK_TIMEOUT=abc'),('duplicate','# FM_CHECK_TIMEOUT=2\n# FM_CHECK_TIMEOUT=3')]:
   check(h,id,declaration+'\ntouch "$FM_HOME/forbidden"\n'); cmd(h,['bin/fm-check-register.sh',id],expected=2)
   assert not (h/'state'/f'{id}.check-trust').exists()
  p=check(h,'tamper','# FM_CHECK_TIMEOUT=2\ntouch "$FM_HOME/tamper-ran"\n'); register(h,'tamper')
  p.write_text(p.read_text().replace('=2','=20')); p.chmod(0o700)
  out=cmd(h,['bin/fm-watch.sh']); assert 'rejected unauthenticated' in out.stdout
  assert not (h/'tamper-ran').exists(); queue(h)
 scenario('Malformed, duplicate, and edited budgets cannot gain execution trust',registration)
 def default_timeout():
  h=home('default'); check(h,'default','printf "default budget=%s\\n" "$FM_CHECK_TIMEOUT"\nsleep 40\nprintf "too late\\n"\n'); register(h,'default')
  out=cmd(h,['bin/fm-watch.sh']); q=queue(h)
  assert 'default budget=30' in q and 'timed out after 30s' in q and 'failing tool: default' in q and 'too late' not in q
 scenario('An undeclared check retains the 30-second default and publishes a named timeout',default_timeout)
 def extended():
  h=home('extended'); check(h,'research-sources','# FM_CHECK_TIMEOUT=40\nprintf "entered budget=%s\\n" "$FM_CHECK_TIMEOUT"\ntouch "$FM_HOME/entered"\nsleep 32\nprintf "completed beyond 30 seconds\\n"\n'); register(h,'research-sources')
  out=open(h/'watch.out','w'); err=open(h/'watch.err','w')
  p=subprocess.Popen(['bash','bin/fm-watch.sh'],env=env(h,FM_WATCHER_STALL_BOUND='4'),stdout=out,stderr=err); children.append(p)
  deadline=time.monotonic()+30
  while not (h/'entered').exists():
   assert time.monotonic()<deadline and p.poll() is None; time.sleep(.1)
  time.sleep(6)
  before=(h/'state/.last-watcher-beat').stat().st_mtime
  r=cmd(h,['bin/fm-watch.sh'],FM_WATCHER_STALL_BOUND='4')
  assert f'already running pid {p.pid}' in r.stdout and p.poll() is None
  note(f'heartbeat age during admitted long check: {time.time()-before:.2f}s; same owner pid={p.pid}')
  assert time.time()-before<4
  rc=p.wait(timeout=60); out.close(); err.close(); note((h/'watch.out').read_text()+(h/'watch.err').read_text()+f'exit={rc}')
  assert rc==0
  q=queue(h); assert 'completed beyond 30 seconds' in q and 'timed out' not in q and 'entered budget=40' in q
  assert not list((h/'state').glob('.check-run-*'))
 scenario('A 40-second authenticated budget survives 32 seconds and re-arm preserves its healthy owner',extended)
 def portable():
  h=home('portable')
  check(h,'a-timeout','# FM_CHECK_TIMEOUT=2\nprintf "partial before cut\\n"\nsleep 10\nprintf "forbidden after cut\\n"\n')
  check(h,'b-default','printf "next default budget=%s\\n" "$FM_CHECK_TIMEOUT"\n')
  for id in ['a-timeout','b-default']: register(h,id)
  cmd(h,['bin/fm-watch.sh'],FM_CHECK_FORCE_FALLBACK='1'); q=queue(h)
  assert re.search(r'timed out after 2s \(measured [1-9][0-9]*s;.*failing tool: a-timeout',q)
  assert 'partial before cut' in q and 'forbidden after cut' not in q and 'next default budget=30' in q
  cmd(h,['bin/fm-check-unregister.sh','a-timeout']); assert not (h/'state/a-timeout.check.sh').exists() and not (h/'state/a-timeout.check-trust').exists()
 scenario('Portable timeout preserves partial output, reports positive elapsed time, resets the next budget, and unregisters',portable)
 def checkpoint():
  h=home('checkpoint')
  for id,budget in [('a-slow',100),('c-fast',20),('b-fast',20),('a-oversized',300)]:
   body=f'# FM_CHECK_TIMEOUT={budget}\nprintf "%s\\n" {id} >> "$FM_HOME/order"\nprintf "%s\\n" {id}\n'
   if id=='a-oversized': body='# FM_CHECK_TIMEOUT=300\ntouch "$FM_HOME/slow-entered"\nsleep 200\n'
   check(h,id,body); register(h,id)
  r=cmd(h,['bin/fm-watch-checkpoint.sh','--seconds','180']); q=queue(h)
  order=(h/'order').read_text(); note('persisted execution order:\n'+order)
  assert order=='b-fast\nc-fast\na-slow\n' and not (h/'slow-entered').exists()
  assert re.search(r'a-oversized.check.sh: deferred \(budget 300s > remaining \d+s\)',r.stderr)
  assert all(id in q for id in ['b-fast','c-fast','a-slow'])
 scenario('Foreground checkpoints run fitting checks by budget and name and report oversized deferral',checkpoint)
 def publication():
  h=home('publication')
  check(h,'late','# FM_CHECK_TIMEOUT=3\ntrap \'sleep 2; printf "cleanup after timeout\\n"; exit 0\' TERM\nprintf "partial before boundary\\n"\nsleep 20\n')
  register(h,'late'); t=time.monotonic()
  r=cmd(h,['bin/fm-watch-checkpoint.sh','--seconds','4']); elapsed=time.monotonic()-t; q=queue(h)
  assert elapsed>4 and elapsed<14 and 'failing tool: late' in q and 'timed out after 3s' in q and 'partial before boundary' in q
  note(f'Late timeout durably published after quiet boundary: elapsed={elapsed:.2f}s, quiet=4s')
 scenario('An admitted timeout completing past the quiet boundary still publishes its wake',publication)
finally:
 for p in children:
  if p.poll() is None: p.terminate()
  try: p.wait(timeout=10)
  except subprocess.TimeoutExpired: p.kill(); p.wait()
 (evidence/'live-results.json').write_text(json.dumps(records,indent=2)+'\n')
 shutil.rmtree(lab)
 note('Disposable homes removed; all owned watcher children reaped.'); log.close()
