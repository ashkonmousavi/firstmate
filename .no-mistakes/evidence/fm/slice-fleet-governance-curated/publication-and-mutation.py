import os,pathlib,tempfile,subprocess,shutil,time,json,signal
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M6QTPTMK4BHKP80JC21WTY8N')
T=pathlib.Path(tempfile.mkdtemp(prefix='.live-publication-',dir=R)); children=[]
B={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','TMUX'))}
B.update(FM_POLL='1',FM_CHECK_INTERVAL='0',FM_HEARTBEAT='999999',FM_SIGNAL_GRACE='1')
logs=[]
def command(root,h,script,*args,**opts):
    p=subprocess.Popen(['bash',str(root/'bin'/script),*args],env=dict(B,FM_HOME=str(h),**opts),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True);children.append(p)
    return p

def finish(p,label,timeout=20):
    out,err=p.communicate(timeout=timeout)
    logs.append(dict(label=label,exit=p.returncode,stdout=out,stderr=err))
    return p.returncode,out,err

def hmake(name):
    h=T/name; rc,out,err=finish(command(R,h,'fm-lab-home.sh','create',str(h)),name+' create');assert rc==0,(out,err);return h

def check(h,name,budget,body):
    p=h/'state'/f'{name}.check.sh';p.write_text(f'#!/usr/bin/env bash\n# FM_CHECK_TIMEOUT={budget}\n'+body+'\n');p.chmod(0o700)
    rc,out,err=finish(command(R,h,'fm-check-register.sh',name),name+' register');assert rc==0,(out,err)

try:
    h=hmake('publication')
    # Real command delays TERM completion by one second, putting its timeout result
    # beyond the 3-second quiet boundary. The real queue lock delays publication.
    check(h,'delayed-cut',3,'trap \'sleep 1; exit 0\' TERM\ntouch "$FM_HOME/entered"\nprintf "before cutoff\\n"\nsleep 20')
    started=time.monotonic();p=command(R,h,'fm-watch-checkpoint.sh','--seconds','3')
    deadline=time.monotonic()+8
    while not (h/'entered').exists() and time.monotonic()<deadline:
        if p.poll() is not None: break
        time.sleep(.02)
    assert (h/'entered').exists(),'3s check not admitted'
    holder_body='. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$FM_HOME/state/.wake-queue.lock" || exit 1; touch "$FM_HOME/lock-held"; sleep 5; fm_lock_release "$FM_HOME/state/.wake-queue.lock"'
    holder=subprocess.Popen(['bash','-c',holder_body,'_',str(R)],env=dict(B,FM_HOME=str(h)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True);children.append(holder)
    rc,out,err=finish(p,'3s checkpoint delayed cut and contended publication')
    elapsed=time.monotonic()-started
    hrc,hout,herr=finish(holder,'queue lock holder');assert hrc==0,(hout,herr)
    q=(h/'state'/'.wake-queue').read_text();(E/'publication-queue.txt').write_text(q)
    assert rc==0 and 'failing tool: delayed-cut' in q and 'before cutoff' in q,(rc,out,err,q)
    assert elapsed>5 and elapsed<10 and (h/'lock-held').exists(),elapsed
    assert not (h/'state'/'.watch.lock'/'pid').exists()
    logs.append(dict(label='publication observation',seconds=round(elapsed,3),quiet_seconds=3,lock_hold_seconds=5,queue=q,result='pass'))
    print('PASS: admitted timeout published after 3s quiet boundary despite 5s lock contention; elapsed %.3fs'%elapsed,flush=True)
    # Restore lexical scheduling only in a disposable executable copy. Oracle:
    # the recorded owner decision requires ascending budget, ties by name.
    mutant=T/'mutant';shutil.copytree(R/'bin',mutant/'bin')
    w=mutant/'bin'/'fm-watch.sh';s=w.read_text();old='sort -t "$(printf \'\\t\')" -k1,1n -k2,2';assert s.count(old)==1
    w.write_text(s.replace(old,'sort -t "$(printf \'\\t\')" -k2,2'));w.chmod(0o755)
    h=hmake('lexical-mutant')
    for name,budget in [('a-slow',100),('c-fast',20),('b-fast',20)]:
        check(h,name,budget,f'printf "%s\\n" {name} >> "$FM_HOME/order"\nprintf "%s\\n" {name}')
    rc,out,err=finish(command(mutant,h,'fm-watch-checkpoint.sh','--seconds','180'),'lexical-order mutant')
    order=(h/'order').read_text();expected='b-fast\nc-fast\na-slow\n'
    assert rc==0,(rc,out,err)
    assert order=='a-slow\nb-fast\nc-fast\n' and order!=expected,order
    logs.append(dict(label='executable mutation oracle',expected=expected,observed=order,mutant_rejected=True))
    print('PASS: executable lexical-order mutant rejected: observed '+repr(order)+'; required '+repr(expected),flush=True)
finally:
    for p in children:
        if p.poll() is None:
            p.terminate()
            try:p.communicate(timeout=6)
            except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.communicate()
    (E/'publication-and-mutation.json').write_text(json.dumps(logs,indent=2,ensure_ascii=False))
    shutil.rmtree(T)
