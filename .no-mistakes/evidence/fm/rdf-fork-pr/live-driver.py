import os,json,subprocess,time,sys,threading
from pathlib import Path
R=Path.cwd(); B=R/'.test-tmp/live'; B.mkdir()
E=Path('~/.no-mistakes/evidence/01M5DAEA0XEBTV9XW0AZETYNBG')
env=dict(os.environ,TMPDIR=str(R/'.test-tmp'),PYTHONDONTWRITEBYTECODE='1')
for k in list(env):
 if k.startswith('FM_') and k.endswith('_OVERRIDE'): env.pop(k)
def exe(p,s): p.write_text(s);p.chmod(0o755)
def cmd(a,**kw):
 p=subprocess.run([str(x) for x in a],env=env,capture_output=True,text=True,timeout=30,**kw)
 if p.returncode: raise RuntimeError(str(a)+'\n'+p.stderr+p.stdout)
 return p.stdout
home=B/'home'; remote=B/'remote'; code=B/'code'; shim=B/'path'
for p in (remote/'state',code/'bin',shim):p.mkdir(parents=True)
cmd(['bash',R/'bin/fm-lab-home.sh','create',home]);env['FM_HOME']=str(home)
state=home/'state'; log=remote/'state/parent-replies.status'
(state/'.last-watcher-beat').touch(); (state/'q-server.status').write_text('done [at=1000]: local\n')
# Local transport bridge: real filesystem reader executables, no fabricated protocol replies.
exe(code/'bin/fm-on.sh',f'''#!/bin/bash
shift
reader=$1
shift
export FM_HOME={remote}
exec {R}/bin/"$reader" "$@"
''')
exe(code/'bin/fm-inbox.sh', f'#!/bin/bash\nexec {R}/bin/fm-inbox.sh "$@"\n')
# All product Herdr requests remain confined to helper's named lab.
exe(shim/'herdr',f'''#!/bin/bash
export PATH={os.environ['PATH']}
exec bash {R}/bin/fm-herdr-lab.sh run fm-lab-bs-gate "$@"
''')
env['PATH']=str(shim)+':'+os.environ['PATH'];env['FM_HERDR_LAB_STATE_DIR']=str(R/'.test-tmp/herdr-state')
def memory():return json.loads((state/'.main-backstop.json').read_text())
def notes():return '\n'.join(p.read_text() for p in (state/'inbox').glob('*.note'))
def check(label):
 print('\n### '+label,flush=True)
 print(cmd(['python3',R/'bin/fm-main-backstop.py','--home',home,'--code-root',code,'--mate','q-server']),end='',flush=True)
def has(s):assert s in notes(),s
log.write_text('done [at=1000]: café\r\n');check('healthy Unicode bootstrap');assert not notes()
log.write_bytes(log.read_bytes()+b'done [at=1900]: threshold\n');check('900 seconds stays quiet');assert not notes()
with log.open('ab') as f:f.write('done [at=1901]: café\r\n'.encode())
check('901 seconds creates durable lag and failed-recovery notes');has('REPLY DELIVERY LAG q-server: 901s');has('BACKSTOP FAILURE')
assert memory()['readers']['q-server']['offset']==log.stat().st_size
incident=memory()['episodes']['lag-q-server']; before=len(list((state/'inbox').glob('*.note')))
log.rename(remote/'state/hidden');check('one unreadable pass is noise');assert 'read-q-server' not in memory()['episodes']
check('two unreadable passes alarm');has('REPLY DELIVERY UNVERIFIED')
(remote/'state/hidden').rename(log);check('recovered read keeps unresolved lag identity');assert memory()['episodes']['lag-q-server']==incident
(state/'q-server.status').write_text('done [at=1901]: local\n');check('caught up clears lag incident');assert 'lag-q-server' not in memory()['episodes']
with log.open('ab') as f:f.write(b'working [at=2000]: backlog\n'*5000+b'done [at=4000]: latest\n')
check('multiple chunks reach latest tail');assert memory()['readers']['q-server']['stamp']==4000;assert memory()['readers']['q-server']['offset']==log.stat().st_size
with log.open('ab') as f:f.write(b'working [at=4100]: backlog\n'*22000+b'done [at=6000]: latest\n')
check('bounded incomplete scan records failure');assert 'q-server' in memory()['read_fails']
check('second incomplete scan stays unverified');assert 'read-q-server' in memory()['episodes']
check('later scan reaches tail');assert memory()['readers']['q-server']['stamp']==6000;assert 'q-server' not in memory()['read_fails']
log.write_text('working [at=1000]: café\n'*50000+'done [at=7000]: tail\n');check('oversized replaced Unicode log bootstraps tail');assert memory()['readers']['q-server']['stamp']==7000;assert memory()['readers']['q-server']['offset']==log.stat().st_size
(state/'q-server.status').write_text('done [at=7000]: local\n');check('healthy delivery before runner check')
pe=state/'procevent';pe.mkdir(exist_ok=True);src=pe/'remote-reply-q-server.source';pidfile=src.with_suffix('.runner');src.touch();pidfile.write_text('')
check('empty runner registration tolerated once');assert 'runner-q-server' not in memory()['episodes']
check('second missing runner alarms');has('REPLY RUNNER DOWN q-server');rid=memory()['episodes']['runner-q-server']
check('persistent dead runner deduplicates');assert memory()['episodes']['runner-q-server']==rid
src.unlink();check('unregister closes runner incident');assert 'runner-q-server' not in memory()['episodes']
state.chmod(0o700); pe.chmod(0o700)
print('\n### Actual fm-procevent runner registration/start',flush=True)
print(cmd(['bash',R/'bin/fm-procevent.sh','register','remote-reply','remote-reply-q-server','--','sleep','300']),flush=True)
runner=subprocess.Popen(['bash',str(R/'bin/fm-procevent.sh'),'start','remote-reply-q-server'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
try:
 deadline=time.monotonic()+15
 while not pidfile.exists() or not pidfile.read_text().strip():
  if time.monotonic()>deadline:raise RuntimeError('real runner did not register')
  time.sleep(.1)
 pidtext=pidfile.read_text(); print('Real runner PID: '+pidtext.strip(),flush=True)
 check('actual healthy runner clears prior transient');assert 'q-server' not in memory()['runner_fails']
 pidfile.write_text('')
 thread=threading.Thread(target=lambda:(time.sleep(.04),pidfile.write_text(pidtext)))
 thread.start();check('empty record restored by concurrent writer is reread');thread.join()
 assert 'q-server' not in memory()['runner_fails']
 pidfile.unlink();check('record absent for one poll is transient');assert 'q-server' in memory()['runner_fails']
 pidfile.write_text(pidtext);check('real runner recovery clears transient');assert 'q-server' not in memory()['runner_fails']
finally:
 print(cmd(['bash',R/'bin/fm-procevent.sh','retire','remote-reply-q-server']),flush=True)
 try:runner.communicate(timeout=10)
 except subprocess.TimeoutExpired:
  import signal
  os.killpg(runner.pid,signal.SIGTERM);runner.communicate(timeout=5)
# Reproduce an actual stalled watcher, with no live primary available.
(state/'lab.check.sh').write_text('# lab work\n');os.utime(state/'.last-watcher-beat',(time.time()-600,)*2)
check('stalled watcher without primary retains durable recovery');has('watcher silent')
(state/'lab.check.sh').unlink()
print('\n### Durable note delivered through real wake drain',flush=True)
print(cmd(['bash',R/'bin/fm-wake-drain.sh']),flush=True)
(E/'live-state.json').write_text(json.dumps(memory(),indent=2)+'\n')
(E/'live-notes.txt').write_text(notes())
print('All assertions passed; local transport bridge used, no SSH or harness discovery claimed.',flush=True)
