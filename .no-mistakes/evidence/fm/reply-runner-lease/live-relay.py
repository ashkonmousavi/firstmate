import os,sys,time,subprocess,json,pathlib
root=pathlib.Path.cwd(); base=root/'.test-phase'; lab=root/(base/'lab-path').read_text().strip(); remote=base/'remote'
os.umask(0o022)
os.chmod(lab/'state',0o755)
claims=base/'live-claims'; claims.mkdir(exist_ok=True,mode=0o700)
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS']:
 env.pop(k,None)
env.update(FM_HOME=str(lab),FM_PROCEVENT_CLAIM_ROOT=str(claims),FM_SSH_BIN=str(base/'ssh'),FM_REMOTE_REPLY_WAIT_SECONDS='10',FM_PROCEVENT_OWNER_LEASE_SECONDS='3',FM_PROCEVENT_OWNER_CHECK_SECONDS='1',TMPDIR=str(base/'tmp'))
pe=root/'bin/fm-procevent.sh'; adapter=root/'bin/fm-procevent-remote-reply.sh'
def run(*args,timeout=30):
 p=subprocess.run([str(x) for x in args],env=env,text=True,capture_output=True,timeout=timeout)
 print('$',' '.join(str(x) for x in args),flush=True); print(p.stdout,end='',flush=True)
 if p.stderr: print(p.stderr,end='',flush=True)
 if p.returncode: raise RuntimeError(f'exit {p.returncode}')
 return p.stdout
def wait(pred,label,seconds=30):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  if pred(): return
  time.sleep(.1)
 raise RuntimeError('Timed out: '+label)
def append(text):
 with (remote/'state/parent-replies.status').open('a') as f: f.write(text+'\n')
 print('REMOTE APPEND:',text,flush=True)
def handled(n): return (lab/f'state/procevent-inbox/remote-reply-relay.{n}.handled').is_file()
def pid(): return (claims/'remote-reply-relay.claim').read_text().splitlines()[1]
def alive(p):
 try:
  stat=pathlib.Path(f'/proc/{p}/stat').read_text(); return stat.split()[2]!='Z'
 except FileNotFoundError:return False
print('Real primary lock:',(lab/'state/.lock').read_text().strip(),flush=True)
print(subprocess.check_output(['codex','--version'],text=True).strip(),flush=True)
run(adapter,'arm','relay'); run(pe,'reconcile')
wait(lambda:(claims/'remote-reply-relay.claim').exists(),'listener claim')
original=pid(); print('Original runner:',original,flush=True)
for n in [1,2,3]:
 append(f'working: live delta {n}')
 wait(lambda:handled(n),f'handled delta {n}',50)
 print('HANDLED',n,'runner',pid(),flush=True)
 assert pid()==original
lease=(lab/'state/procevent/.owner-lease').read_text()
time.sleep(7)
assert (lab/'state/procevent/.owner-lease').read_text()==lease,'runner refreshed own lease'
assert alive(original),'runner died with live owner'
append('needs-decision [key=live-choice]: retained after lease expiry')
wait(lambda:handled(4),'post-lease delta',50)
assert pid()==original
print('POST-LEASE MIRROR:',(lab/'state/relay.status').read_text(),flush=True)
print('LEASE UNCHANGED:',lease.strip(),'now',int(time.time()),flush=True)
run(pe,'start','remote-reply-relay')
run(pe,'reconcile')
assert pid()==original
print('DUPLICATE START kept runner',pid(),flush=True)
# Observe the real remote-worker result before the entrypoint reaps it.
import threading
preemptions=[]
def observe_exits():
 while not preemptions:
  for p in (base/'remote-jobs/jobs').glob('*/exit'):
   try:
    if p.read_text().strip()=='76': preemptions.append(p.parent.name)
   except FileNotFoundError: pass
  time.sleep(.005)
threading.Thread(target=observe_exits,daemon=True).start()
# Let another long-poll start, then queue a genuine file-read job behind it.
time.sleep(3)
run(root/'bin/fm-on.sh','relay','fm-remote-file.sh','get','state/parent-replies.status',timeout=45)
# The actual job result records the remote worker's preemption exit code 76.
wait(lambda:bool(preemptions),'preempted job result',10)
print('REMOTE PREEMPTED RESULTS:',preemptions,flush=True)
append('working: delivered after remote preemption')
wait(lambda:handled(5),'post-preemption delta',50)
assert pid()==original
print('AFTER PREEMPTION:',(lab/'state/relay.status').read_text(),flush=True)
# A real source failure must produce a durable reason instead of disappearing.
run(pe,'register','lavish','failed-source','--','/bin/sh','-c','exit 7')
run(pe,'start','failed-source')
print('FAILED SOURCE EXIT:',(lab/'state/procevent/.failed-source.exits').read_text(),flush=True)
assert 'no-result: source exit 7 with no output' in (lab/'state/procevent/.failed-source.exits').read_text()
# Registration/start refreshed the lease. Age it naturally, with no further reconcile.
time.sleep(5)
socket=(base/'socket-path').read_text().strip(); tmuxenv=env.copy();tmuxenv['TMUX_TMPDIR']=socket
subprocess.run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary'],env=tmuxenv,stdout=open('~/.no-mistakes/evidence/01M5C1241WSKP7RTSG6105D627/real-primary.txt','w'),check=True)
subprocess.run(['tmux','-L','fm-lab','kill-server'],env=tmuxenv,check=True)
wait(lambda:not alive(original),'listener stops after owner exits',12)
exits=(lab/'state/procevent/.remote-reply-relay.exits').read_text()
print('OWNER SHUTDOWN EXIT RECORDS:\n'+exits,flush=True)
assert 'owner-guard-stop' in exits and 'session=stale' in exits and 'status=143' in exits
print('LIVE RELAY SCENARIOS PASSED',flush=True)
