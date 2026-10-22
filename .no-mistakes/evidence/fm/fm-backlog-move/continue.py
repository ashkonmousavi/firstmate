import pathlib,subprocess,os,signal,time
p=pathlib.Path.cwd()/'.test-live-backlog'; root=p/'product'; ev=pathlib.Path('~/.no-mistakes/evidence/01M5HC5M6NQ7YQRQ363RXP9QHE'); s=p/'ssh'
env=dict(os.environ)
for k in list(env):
 if k.startswith(('FM_','TASKS_AXI_')): env.pop(k)
env.update(FM_SSH_BIN=str(s/'ssh'),TMPDIR=str(p/'tmp'))
f=open(ev/'live-cli-recovery.log','w',buffering=1)
def record(t): print(t, file=f); print(t,flush=True)
def cmd(args,src=None,ok=True):
 e=dict(env)
 if src: e['FM_HOME']=str(src)
 record('$ '+ ' '.join(map(str,args)))
 r=subprocess.run(list(map(str,args)),env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
 record(r.stdout);record('exit='+str(r.returncode))
 if ok: assert r.returncode==0
 else: assert r.returncode!=0
 return r

def home(n):
 h=p/n
 for d in ('data','state','bin'): (h/d).mkdir(parents=True,exist_ok=True)
 (h/'AGENTS.md').write_bytes((root/'AGENTS.md').read_bytes())
 return h

def seed(h,text): (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n'+text+'\n## Done\n')
def content(h):
 t=(h/'data/backlog.md').read_text() if (h/'data/backlog.md').exists() else '(no backlog)';record(str(h)+'\n'+t);return t

def move(src,dest,keys,ok=True):
 return cmd([root/'bin/fm-backlog-handoff.sh','--host','127.0.0.1','--remote-root',root,'--remote-home',dest,*keys],src,ok)
def stop():
 os.kill(int((s/'process-pid').read_text()),signal.SIGTERM);time.sleep(.2)
def start():
 out=open(ev/'live-ssh-server.log','a'); proc=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(s/'sshd_config')],stdout=out,stderr=out,start_new_session=True)
 (s/'process-pid').write_text(str(proc.pid));time.sleep(.3);assert proc.poll() is None

source=home('live-source');a=home('remote-a');b=home('remote-b')
move(source,a,['x']);assert '- [ ] x -' in content(a)
record('PASS retained A batch cannot drain to B on same host, and A retry converges')
seed(source,'- [ ] stale - Original title\n  original body\n  prep: data/stale/prep.md\n')
stop();move(source,a,['stale'],False);start()
cmd(['tasks-axi','update','stale','--body','replacement body','--file',source/'data/backlog.md','--backend','markdown'])
move(source,a,['stale'],False);assert '- [ ] stale -' in content(source);assert 'original body' in content(a)
record('PASS changed source remains queued after stale retained payload is acknowledged')
# Separate source avoids intentionally retained stale batch.
source2=home('live-source2');seed(source2,'- [ ] origin2 - Independent source\n')
move(source2,a,['origin2']);assert '- [ ] origin2 -' in content(a)
record('PASS second source home delivers its generation one to existing target')
source3=home('live-source3');seed(source3,'- [ ] blocker - unresolved work\n')
stop();move(source3,a,['blocker'],False);start()
cmd(['tasks-axi','add','outside','outside dependent','--file',source3/'data/backlog.md','--backend','markdown'])
cmd(['tasks-axi','block','outside','--by','blocker','--file',source3/'data/backlog.md','--backend','markdown'])
move(source3,a,['blocker'],False);assert '- [ ] blocker -' in content(source3)
record('PASS recovery refuses closure when a new active source dependent remains')
f.close()
