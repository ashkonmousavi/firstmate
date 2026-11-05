#!/usr/bin/env python3
"""Real MAIN one-way delivery with a disposable offline inbox recipient.

The recipient is an inbox acceptance boundary, not a running agent/primary.
"""
import ctypes,json,os,shutil,signal,subprocess,sys,time
from pathlib import Path
root=Path.cwd(); ev=Path(__file__).parent; lab=root/'.gate-live/r11'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE')}
env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'tmux'),TMUX=str(lab/'private-socket')+',0,0',PYTHONDONTWRITEBYTECODE='1')
ctypes.CDLL(None).prctl(36,1,0,0,0)
engine=root/'bin/fm-autolaunch-steps.py'; scheduler=root/'bin/fm-autolaunch.sh'
args=[sys.executable,str(engine),'controller-effects',str(scheduler),'73','0']
children=[]
def run(args):
 p=subprocess.run(list(map(str,args)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
 print('$',' '.join(map(str,args)),'exit=',p.returncode,p.stdout,p.stderr,flush=True)
 assert p.returncode==0
def dump(path,value): path.write_text(json.dumps(value))
def load(path): return json.loads(path.read_text())
try:
 run(['bash',root/'bin/fm-lab-home.sh','create',lab])
 (lab/'tmux').mkdir()
 state=lab/'state'; journal=state/'autolaunch-controller'; journal.mkdir()
 now=int(time.time()); key='ctl-e-pass-error'; request='1234567890abcdef1234567890abcdef'
 row=dict(key=key,kind='notice',task='',phase='owned',argv=[],rung=0,generation=1,opened=now,overrun=1,
          evidence=str(journal/'evidence.md'),owned_at=now,
          handoff=dict(payload='disposable controller MAIN acceptance test generation=1',request=request,receipt=False))
 path=journal/(key+'.json'); dump(path,row)
 run(args)
 assert not load(path)['handoff']['receipt'] and not (state/'fleet-ops.inbox').exists()
 print('Unresolved lab recipient: send refused and durable pending request retained:',request,flush=True)
 (state/'fleet-ops.meta').write_text('kind=ship\nbackend=tmux\nharness=claude\nwindow=fm-lab-r11:fm-fleet-ops\n')
 # fm-send owns durable acceptance; an offline endpoint only affects doorbell.
 # Kill the actual caller after the real inbox appears, before its send receipt.
 p=subprocess.Popen(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 children.append(p)
 end=time.monotonic()+15; crashed=False
 while time.monotonic()<end:
  records=list((state/'fleet-ops.inbox').glob('*.msg'))
  if records and p.poll() is None:
   os.kill(p.pid,signal.SIGSTOP)
   if not load(path)['handoff']['receipt']:
    os.kill(p.pid,signal.SIGKILL); crashed=True
   else: os.kill(p.pid,signal.SIGCONT)
   break
  if p.poll() is not None: break
  time.sleep(.001)
 out,err=p.communicate(timeout=20)
 print('Caller exit=',p.returncode,'killed-after-real-enqueue=',crashed,out,err,flush=True)
 assert crashed and p.returncode==-signal.SIGKILL,'Could not inject accepted-send/pre-receipt crash'
 assert not load(path)['handoff']['receipt']
 # Wait for accepted send descendants to settle before the restart.
 deadline=time.monotonic()+15
 while time.monotonic()<deadline:
  try: pid,_=os.waitpid(-1,os.WNOHANG)
  except ChildProcessError: break
  if not pid: time.sleep(.05)
 run(args); run(args)
 final=load(path); records=list((state/'fleet-ops.inbox').glob('*.msg'))
 assert final['handoff']['receipt'] and final['handoff']['request']==request
 assert len(records)==1 and 'request-id='+request in records[0].read_text()
 assert not (state/'.wake-queue').exists() or not (state/'.wake-queue').read_text()
 print('Exactly one real accepted inbox record after refused send, killed caller and restarted retries:',flush=True)
 print(records[0].read_text(),flush=True)
 shutil.copyfile(records[0],ev/'live-main-handoff.msg')
 shutil.copyfile(path,ev/'live-main-handoff-row.json')
 print('PASS: real MAIN one-way pending delivery survives failed resolution and accepted-send/pre-receipt caller death, deduplicates by stable request id, and leaves no MAIN wake.',flush=True)
finally:
 for p in children:
  if p.poll() is None: os.killpg(p.pid,signal.SIGTERM)
  p.wait(timeout=10)
 shutil.rmtree(lab,ignore_errors=True)
 print('Disposable MAIN inbox lab removed.',flush=True)
