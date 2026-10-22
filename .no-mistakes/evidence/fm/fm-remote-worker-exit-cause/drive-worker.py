import os, pathlib, tempfile, subprocess as sp, shutil, signal, time, json
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M5GMD1NHC865MTNQ7BNSH88E')
BASE='20be4e3499411851161ae9215bb4ea402786a3f4'
def until(f, timeout=15):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        v=f()
        if v: return v
        time.sleep(.05)
    raise AssertionError('timed out: '+str(f))
def read(p):
    try: return p.read_text().strip()
    except FileNotFoundError: return ''
class Lab:
    def __init__(self,name,baseline=False):
        self.name=name; self.d=pathlib.Path(tempfile.mkdtemp(prefix='.worker-live-',dir=ROOT)); self.root=self.d/'root'; self.home=self.d/'account'; self.state=self.d/'state'; self.remote=self.d/'remote'
        for p in [self.root/'bin', self.home,self.remote]: p.mkdir(parents=True)
        for fn in ['fm-remote-job-lib.sh','fm-remote-job-worker.sh']:
            shutil.copy2(ROOT/'bin'/fn,self.root/'bin'/fn)
        if baseline: (self.root/'bin/fm-remote-job-worker.sh').write_bytes(sp.check_output(['git','show',BASE+':bin/fm-remote-job-worker.sh']))
        (self.root/'AGENTS.md').write_text('Disposable remote worker test root\n')
        (self.root/'bin/fm-live-job.sh').write_text('#!/bin/bash\nprintf "started\\n" > "$1"\nsleep "$2"\nprintf "completed exactly once\\n" >> "$3"\nprintf "job completed\\n"\n')
        (self.root/'bin/fm-live-job.sh').chmod(0o755)
        self.env=dict(os.environ,HOME=str(self.home),FM_ROOT_OVERRIDE=str(self.root),FM_REMOTE_JOB_STATE_ROOT=str(self.state),FM_REMOTE_JOB_PLATFORM_OVERRIDE='Linux',FM_REMOTE_JOB_QUEUE_TIMEOUT='30',FM_REMOTE_JOB_TIMEOUT='30')
        for key in ['FM_HOME','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_STATE_OVERRIDE','FM_PROJECTS_OVERRIDE']: self.env.pop(key,None)
        self.env['FM_HOME']=str(self.remote)
        for args in [['init','-q','-b','main'],['add','.'],['-c','user.name=Test','-c','user.email=test@example.com','commit','-qm','fixture']]: sp.run(['git','-C',str(self.root)]+args,check=True,env=self.env,stdout=sp.DEVNULL)
        self.log=open(E/(name+'-worker.log'),'w')
        self.p=sp.Popen([str(self.root/'bin/fm-remote-job-worker.sh')],env=self.env,stdout=self.log,stderr=self.log,start_new_session=True)
        until(lambda: read(self.state/'worker.pid'))
    def shell(self,code,*args):
        r=sp.run(['bash','-c','. "$1/bin/fm-remote-job-lib.sh"; shift; '+code,'driver',str(self.root),*map(str,args)],env=self.env,text=True,capture_output=True,timeout=40)
        if r.returncode: raise AssertionError(r.stdout+r.stderr)
        return r.stdout.strip()
    def owner(self): return int(read(self.state/'worker.pid') or '0')
    def hb(self,owner):
        ps=sp.check_output(['ps','-ax','-o','pid=,ppid=,args='],text=True)
        for l in ps.splitlines():
            parts=l.strip().split(None,2)
            if len(parts)==3 and int(parts[1])==owner and 'fm-remote-job-worker.sh' in parts[2] and '--lane' not in parts[2]: return int(parts[0])
    def killhb(self):
        owner=self.owner(); hb=until(lambda:self.hb(owner)); os.kill(hb,signal.SIGKILL)
        return owner,hb
    def replace(self,old): return until(lambda: (p if (p:=self.hb(self.owner())) and p!=old else None))
    def stage(self,secs):
        jid=self.shell('fm_remote_job_stage "$HOME" "$FM_ROOT_OVERRIDE" "$FM_HOME" fm-live-job.sh "$1" "$2" "$3" </dev/null >/dev/null || { echo "$FM_REMOTE_JOB_ERROR" >&2; exit 1; }; echo "$FM_REMOTE_JOB_ID"',self.d/'started',secs,self.d/'side-effect')
        until(lambda:read(self.state/'jobs'/jid/'state')=='running')
        return jid
    def result(self,jid):
        result=self.shell('fm_remote_job_wait "$HOME" "$1" || { echo "$FM_REMOTE_JOB_ERROR" >&2; exit 1; }; printf "exit=%s\\n" "$FM_REMOTE_JOB_EXIT"; cat "$FM_REMOTE_JOB_STDOUT" "$FM_REMOTE_JOB_STDERR"',jid)
        return dict(result=result,side_effect=read(self.d/'side-effect'),owner=self.owner())
    def close(self):
        try: os.killpg(self.p.pid,signal.SIGTERM)
        except ProcessLookupError: pass
        try:self.p.wait(timeout=8)
        except sp.TimeoutExpired: os.killpg(self.p.pid,signal.SIGKILL);self.p.wait()
        self.log.close(); shutil.rmtree(self.d)
reports=[]
def run(name,fn,baseline=False):
    lab=Lab(name,baseline)
    try:
        r=fn(lab); reports.append(dict(name=name,**r)); print(json.dumps(reports[-1]),flush=True)
    finally:lab.close()
def single(l):
    jid=l.stage(6); owner,hb=l.killhb(); r=l.result(jid)
    if l.name=='baseline': assert 'exit=125' in r['result'] and 'remote job worker stopped before this job completed' in r['result'],r
    else:
        assert r['result']=='exit=0\njob completed' and r['owner']==owner and r['side_effect']=='completed exactly once',r
        l.shell('fm_remote_job_probe "$HOME" || exit 1')
        assert l.hb(owner)!=hb
    return dict(killed_heartbeat=hb,original_owner=owner,**r)
run('baseline',single,True)
run('heartbeat-loss-active-job',single)
def bound(l):
    owner=l.owner(); killed=[]
    for n in range(6):
        o,h=l.killhb(); assert o==owner; killed.append(h)
        if n<5:l.replace(h)
    until(lambda:l.owner()>0 and l.owner()!=owner)
    log=(E/(l.name+'-worker.log')).read_text()
    assert 'readiness heartbeat process stopped' in log
    jid=l.stage(1); r=l.result(jid); assert r['result']=='exit=0\njob completed',r
    return dict(original_owner=owner,killed_heartbeats=killed,restarted_owner=l.owner(),**r)
run('rapid-death-bound-and-restart',bound)
def stable(l):
    owner=l.owner(); killed=[]
    for group in range(2):
        for n in range(4):
            o,h=l.killhb(); assert o==owner; killed.append(h); l.replace(h)
        if group==0: time.sleep(7)
    jid=l.stage(1); r=l.result(jid)
    assert r['owner']==owner and r['result']=='exit=0\njob completed',r
    return dict(original_owner=owner,killed_heartbeats=killed,healthy_interval_seconds=7,**r)
run('stable-heartbeat-resets-failure-budget',stable)
(E/'worker-scenarios.json').write_text(json.dumps(reports,indent=2)+'\n')
