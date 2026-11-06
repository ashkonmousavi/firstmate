import os, pathlib, subprocess, tempfile, shutil, time, re, json, signal
ROOT = pathlib.Path.cwd()
E = pathlib.Path('~/.no-mistakes/evidence/01M6QTPTMK4BHKP80JC21WTY8N')
BASE = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'TMUX'))}
BASE.update(FM_POLL='1', FM_SIGNAL_GRACE='1', FM_CHECK_INTERVAL='0', FM_HEARTBEAT='999999')
LABROOT = pathlib.Path(tempfile.mkdtemp(prefix='.live-check-budget-', dir=ROOT))
children=[]; results=[]
def env(home, **extra): return dict(BASE, FM_HOME=str(home), **extra)
def run(home, script, *args, timeout=50, **extra):
    start=time.monotonic()
    p=subprocess.Popen(['bash',str(ROOT/'bin'/script),*args],cwd=ROOT,env=env(home,**extra),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    children.append(p)
    try: out,err=p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.terminate()
        try: out,err=p.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid,signal.SIGKILL); out,err=p.communicate()
        raise AssertionError(f'{script} exceeded {timeout}s: {out} {err}')
    record={'command':['bash',f'bin/{script}',*args], 'home':home.name,'settings':extra,'exit':p.returncode,'seconds':round(time.monotonic()-start,3),'stdout':out,'stderr':err}
    with (E/'live-cli.jsonl').open('a') as f: f.write(json.dumps(record,ensure_ascii=False)+'\n')
    return p.returncode,out,err

def home(name):
    h=LABROOT/name
    rc,out,err=run(h,'fm-lab-home.sh','create',str(h)); assert rc==0,(out,err)
    return h

def check(h,name,body,budget=None,register=True):
    p=h/'state'/f'{name}.check.sh'
    p.write_text('#!/usr/bin/env bash\n'+('' if budget is None else f'# FM_CHECK_TIMEOUT={budget}\n')+body+'\n'); p.chmod(0o700)
    if register:
        rc,out,err=run(h,'fm-check-register.sh',name); assert rc==0,(out,err)
    return p

def queue(h,label):
    q=(h/'state'/'.wake-queue').read_text()
    (E/f'{label}-queue.txt').write_text(q)
    assert not list((h/'state').glob('.check-run-*')), 'unrequested run-record persistence'
    return q

def scenario(name,fn):
    try: detail=fn(); result='pass'
    except Exception as e: detail=f'{type(e).__name__}: {e}'; result='fail'
    results.append(dict(name=name,result=result,live=True,detail=detail))
    (E/'live-results.json').write_text(json.dumps(results,indent=2,ensure_ascii=False))
    print(json.dumps(results[-1],ensure_ascii=False),flush=True)

def registration():
    h=home('registration')
    for val in ['', '0','-1','1.5','01','86401','$(touch FORGED)','4 extra','3\n# FM_CHECK_TIMEOUT=4']:
        check(h,'invalid','touch "$FM_HOME/executed"',val,False)
        rc,out,err=run(h,'fm-check-register.sh','invalid')
        assert rc==2 and 'malformed custom check budget' in err,(val,rc,out,err)
        assert not (h/'state'/'invalid.check-trust').exists()
    assert not (ROOT/'FORGED').exists() and not (h/'executed').exists()
    run(h,'fm-check-unregister.sh','invalid')
    check(h,'default','printf "default child budget=%s\\n" "$FM_CHECK_TIMEOUT"')
    rc,out,err=run(h,'fm-watch.sh'); assert rc==0 and 'default child budget=30' in out,(rc,out,err)
    queue(h,'registration')
    rc,out,err=run(h,'fm-check-unregister.sh','default'); assert rc==0,(out,err)
    assert not (h/'state'/'default.check.sh').exists() and not (h/'state'/'default.check-trust').exists()
    return 'All malformed/duplicate declarations refused with exit 2 and no trust; absent declaration exported 30; unregister removed script and trust.'

def beyond30():
    h=home('beyond30')
    check(h,'research-sources','sleep 31\nprintf "research completed; budget=%s\\n" "$FM_CHECK_TIMEOUT"',36)
    rc,out,err=run(h,'fm-watch.sh',timeout=45)
    assert rc==0 and 'research completed; budget=36' in out and 'timed out' not in out,(rc,out,err)
    queue(h,'beyond30')
    return 'Real registered check completed after 31s under its authenticated 36s budget, exceeding the unchanged 30s default.'

def cuts():
    for fallback in ['0','1']:
        h=home('timeout-'+fallback)
        check(h,'a-cut','printf "partial before cutoff\\n"\nsleep 5\nprintf "FORBIDDEN AFTER CUTOFF\\n"',2)
        check(h,'b-fast','printf "later fast default=%s\\n" "$FM_CHECK_TIMEOUT"')
        rc,out,err=run(h,'fm-watch.sh',FM_CHECK_FORCE_FALLBACK=fallback)
        q=queue(h,'timeout-'+fallback)
        assert rc==0,(out,err)
        assert 'partial before cutoff' in q and 'FORBIDDEN AFTER CUTOFF' not in q
        assert re.search(r'timed out after 2s \(measured [1-9][0-9]*s;.*failing tool: a-cut',q),q
        assert 'later fast default=30' in q,q
    return 'Installed timeout and portable Perl paths retained partial output, cut late output, named tool/budget/positive measured seconds, then ran the later check with default 30.'

def tamper():
    h=home('tamper')
    p=check(h,'tampered','touch "$FM_HOME/UNSAFE"',2)
    p.write_text(p.read_text().replace('TIMEOUT=2','TIMEOUT=10'))
    rc,out,err=run(h,'fm-watch.sh')
    q=queue(h,'tamper')
    assert rc==0 and 'rejected unauthenticated state checks' in q and not (h/'UNSAFE').exists(),(out,err,q)
    return 'Changing only authenticated budget bytes after registration prevented execution and generated an unauthenticated-check notification.'

def checkpoint():
    h=home('checkpoint')
    for name,budget in [('a-slow',100),('c-fast',20),('b-fast',20),('d-default',None)]:
        check(h,name,f'printf "%s\\n" {name} >> "$FM_HOME/order"\nprintf "%s child budget=%s\\n" {name} "$FM_CHECK_TIMEOUT"',budget)
    check(h,'a-oversized','touch "$FM_HOME/oversized-ran"\nsleep 200',300)
    rc,out,err=run(h,'fm-watch-checkpoint.sh','--seconds','180')
    order=(h/'order').read_text()
    (E/'checkpoint-order.txt').write_text(order)
    assert rc==0 and order=='b-fast\nc-fast\nd-default\na-slow\n',(rc,out,err,order)
    assert not (h/'oversized-ran').exists()
    assert re.search(r'a-oversized.check.sh: deferred \(budget 300s > remaining [0-9]+s\)',err),err
    queue(h,'checkpoint')
    h=home('quiet-deferred')
    check(h,'oversized','touch "$FM_HOME/oversized-ran"',300)
    rc,out,err=run(h,'fm-watch-checkpoint.sh','--seconds','2')
    assert rc==124 and 'no actionable wake within 2s' in out and 'deferred (budget 300s > remaining ' in err,(rc,out,err)
    assert not (h/'oversized-ran').exists()
    h=home('remaining-window')
    check(h,'a-first','sleep 2\nprintf "first finished\\n"',5)
    check(h,'b-second','touch "$FM_HOME/second-ran"',9)
    rc,out,err=run(h,'fm-watch-checkpoint.sh','--seconds','10')
    assert rc==0 and 'first finished' in out and not (h/'second-ran').exists(),(rc,out,err)
    assert re.search(r'b-second.check.sh: deferred \(budget 9s > remaining [0-8]s\)',err),err
    queue(h,'remaining-window')
    h=home('ordinary-full-budget')
    check(h,'oversized','sleep 2\nprintf "ordinary budget=%s\\n" "$FM_CHECK_TIMEOUT"',300)
    rc,out,err=run(h,'fm-watch.sh',FM_CHECK_TIMEOUT='1')
    assert rc==0 and 'ordinary budget=300' in out,(rc,out,err)
    queue(h,'ordinary-full-budget')
    return 'Foreground checks ran by ascending budget then name; oversized 300s check was deferred in the 180s window and in a quiet 2s window; admission rechecked remaining time; ordinary watcher retained 300s.'

def health():
    h=home('health')
    check(h,'slow','touch "$FM_HOME/entered"\nwhile [ ! -e "$FM_HOME/release" ]; do sleep 0.1; done\nprintf "healthy long check completed\\n"',12)
    opts=dict(FM_GUARD_GRACE='3',FM_WATCHER_STALL_BOUND='4')
    p=subprocess.Popen(['bash',str(ROOT/'bin/fm-watch.sh')],cwd=ROOT,env=env(h,**opts),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True);children.append(p)
    deadline=time.monotonic()+10
    while not (h/'entered').exists() and time.monotonic()<deadline: time.sleep(.05)
    assert (h/'entered').exists(), 'check failed to enter'
    time.sleep(5)
    beat_age=time.time()-(h/'state'/'.last-watcher-beat').stat().st_mtime
    rc,out,err=run(h,'fm-watch.sh',**opts)
    assert rc==0 and f'watcher: already running pid {p.pid}' in out and beat_age<3,(out,err,beat_age)
    (h/'release').touch()
    out,err=p.communicate(timeout=15)
    assert p.returncode==0 and 'healthy long check completed' in out,(out,err)
    (E/'health-completion.txt').write_text(f'beacon_age={beat_age:.3f}s; stall_bound=4s; check active >5s\nexit={p.returncode}\n{out}{err}')
    queue(h,'health')
    return 'After 5s of active check execution, a 4s stall bound did not evict the original watcher: duplicate start reported its same PID, beacon age stayed under 3s, and original completed/published.'

try:
    scenario('Malformed declarations refuse; absent budget stays 30; unregister retires',registration)
    scenario('Authenticated check runs longer than former 30s cap',beyond30)
    scenario('Both timeout engines publish named measured cuts and continue the sweep',cuts)
    scenario('Budget tampering invalidates authentication before execution',tamper)
    scenario('Checkpoint ordering, deferral, remaining-window admission and ordinary full budget',checkpoint)
    scenario('Long admitted check retains monitoring health and ownership',health)
finally:
    for p in children:
        if p.poll() is None:
            p.terminate()
            try:p.communicate(timeout=6)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid,signal.SIGKILL);p.communicate()
    shutil.rmtree(LABROOT)
    (E/'live-cleanup.txt').write_text('Disposable homes removed; every launched product process was waited.\n')
raise SystemExit(any(r['result']!='pass' for r in results))
