import os, pathlib, subprocess, json, time, shutil
W=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M68RDV1CW6E2AMQX2N5CQ690')
P=W/'.test-disposable/product'; L=W/'.l'; S=W/'.s'
log=(E/'live-spawn.log').open('w'); results=[]; children=[]
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('TMUX','TMUX_PANE','NO_MISTAKES_GATE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_PANE_ID'): env.pop(k,None)
env.update(FM_HOME=str(L), FM_ROOT_OVERRIDE=str(P), FM_BACKEND='tmux', TMPDIR=str(W/'.test-disposable/tmp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', FM_SEND_SETTLE='0')
def run(args, timeout=50, check=True, extra=None):
    x=env.copy(); x.update(extra or {})
    p=subprocess.run([str(a) for a in args],env=x,cwd=W,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    log.write('$ '+' '.join(str(a) for a in args)+'\n'+p.stdout+f'[exit {p.returncode}]\n');log.flush()
    if check and p.returncode: raise RuntimeError(p.stdout)
    return p

def tm(*args,**kw): return run(['tmux','-L','fm-lab',*args],extra={'TMUX_TMPDIR':str(L/'tmux')},**kw)
def probe():
    return run(['bash','-c','. "$1/bin/fm-secondmate-liveness-lib.sh"; fm_secondmate_liveness_probe "$FM_HOME/state/sm.meta" sm poll; printf "endpoint=%s status=%s\\n" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_STATUS"','_',str(P)]).stdout.strip()
def msgs(): return sorted((L/'state/sm.inbox').glob('*.msg'))
def clear_notices():
    shutil.rmtree(L/'state/sm.inbox',ignore_errors=True)
    for p in (S/'state').glob('.fm-inherited-config-reread*'):
        if p.is_dir(): shutil.rmtree(p)
        else:p.unlink()
def push(label,value,skip):
    (L/'config/crew-harness').write_text(value+'\n')
    out=run([P/'bin/fm-config-push.sh']).stdout
    assert (S/'config/crew-harness').read_text().strip()==value
    assert ('parked, skipped' in out)==skip, out
    assert bool(msgs()) != skip, (label,[str(m) for m in msgs()])
    log.write(f'OBSERVE {label}: config={value}, inbox_messages={len(msgs())}, skip={skip}\n');log.flush()
    if msgs():log.write('PERSISTED STEERING MESSAGE:\n'+msgs()[-1].read_text()+'\n');log.flush()
    results.append({'scenario':label,'result':'pass','live':True})

def boot(label,value,skip):
    (L/'config/crew-harness').write_text(value+'\n')
    # Hold the production liveness lock so this convergence check does not
    # automatically relaunch the stopped endpoint before inspecting the push.
    script='. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$STATE/.secondmate-liveness-sm.lock"; trap \'fm_lock_release "$STATE/.secondmate-liveness-sm.lock"\' EXIT; "$1/bin/fm-bootstrap.sh"'
    out=run(['bash','-c',script,'_',str(P)],extra={'STATE':str(L/'state'),'FM_BOOTSTRAP_NETWORK':'only'},timeout=100).stdout
    assert (S/'config/crew-harness').read_text().strip()==value
    assert ('parked, skipped' in out)==skip,out
    assert bool(msgs()) != skip,(label,out)
    log.write(f'OBSERVE {label}: config={value}, inbox_messages={len(msgs())}, skip={skip}\n');log.flush()
    if msgs():log.write('PERSISTED STEERING MESSAGE:\n'+msgs()[-1].read_text()+'\n');log.flush()
    results.append({'scenario':label,'result':'pass','live':True})
try:
    run([W/'bin/fm-lab-home.sh','create',L]); (L/'tmux').mkdir();(L/'config/supervision-host').touch()
    run(['git','-C',P,'worktree','add','--detach',S,'HEAD'])
    for d in ('state','data','config','projects'): (S/d).mkdir(exist_ok=True)
    (S/'.fm-secondmate-home').write_text('sm\n'); (S/'data/charter.md').write_text('Disposable live config-push verification.\n')
    (S/'preserved-work.txt').write_text('unsaved work must survive\n')
    (L/'config/backend').write_text('tmux\n');(L/'config/crew-harness').write_text('codex\n')
    (L/'state/sm.meta').write_text(f'window=firstmate:fm-sm\nkind=secondmate\nharness=codex\nbackend=tmux\nhome={S}\nworktree={S}\nproject={P}\nendpoint_task_id=sm\n')
    tm('new-session','-d','-s','firstmate','-n','fm-sm','-x','120','-y','40','-c',S,'bash --noprofile --norc')
    socket=tm('display-message','-p','#{socket_path}').stdout.strip()
    pid=tm('display-message','-p','#{pid}').stdout.strip();env['TMUX']=f'{socket},{pid},0'
    assert 'endpoint=dead' in probe()
    # Exercise the actual watcher transition after its existing attempt budget
    # has been consumed; no test double supplies the parked verdict or marker.
    now=int(time.time());(L/'state/.secondmate-relaunch-sm').write_text(''.join(f'{now}\tattempt\n' for _ in range(3)))
    watcher_env=env.copy();watcher_env.update(FM_POLL='1',FM_SECONDMATE_LIVENESS_SECS='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
    with (E/'live-watch.log').open('w') as f:
        watcher=subprocess.Popen([str(P/'bin/fm-watch.sh')],cwd=W,env=watcher_env,stdout=f,stderr=subprocess.STDOUT);children.append(watcher)
        try: rc=watcher.wait(timeout=35)
        except subprocess.TimeoutExpired: watcher.terminate();rc=watcher.wait(timeout=10)
    log.write(f'watcher exit={rc}\n'+(E/'live-watch.log').read_text());log.flush()
    marker=L/'state/.secondmate-relaunch-bound-sm'
    assert marker.exists(),'watcher did not establish parked lifecycle state'
    park_record=marker.read_text();log.write('WATCHER PARK RECORD: '+park_record);log.flush()
    push('parked config push updates files without a notice','codex',True)
    push('repeated parked config push never refills inbox','claude',True)
    boot('bootstrap parked convergence updates files without a notice','codex',True)
    # The real spawn now replaces the parked endpoint and must rearm before
    # the following config push. Keep an unrelated private window so the
    # isolated server survives removal of the recorded worker window.
    tm('new-window','-d','-n','keeper','bash --noprofile --norc')
    tm('kill-window','-t','firstmate:fm-sm')
    old=L/'state/sm.inbox/001.msg'; old.parent.mkdir(exist_ok=True)
    old.write_text('schema=fm-task-inbox.v1\nat=2026-10-31T00:00:00Z\n--\nCONFIG_REREAD: retained queued steer\n')
    launched=run([P/'bin/fm-spawn.sh','sm',S,'--secondmate','--harness','codex','--backend','tmux'],timeout=80,check=False)
    assert launched.returncode==0,launched.stdout
    assert not marker.exists(),'successful spawn retained park marker'
    assert old.exists(),'spawn archived an existing queued steer'
    for _ in range(60):
        if 'endpoint=alive' in probe():break
        time.sleep(.25)
    else:raise RuntimeError('spawn did not start a real agent')
    clear_notices();push('successful secondmate spawn clears park state and restores push notices','claude',False)
    results.append({'scenario':'successful launch preserves previously queued steer','result':'pass','live':True})
    tm('kill-window','-t','firstmate:fm-sm')
    # Retain the genuine watcher record while injecting an unwritable ledger.
    # Run the real spawn: the process starts before rearming reports failure.
    ledger=L/'state/.secondmate-relaunch-sm'; ledger.unlink();ledger.mkdir()
    marker.write_text(park_record)
    launched=run([P/'bin/fm-spawn.sh','sm',S,'--secondmate','--harness','codex','--backend','tmux'],timeout=80,check=False)
    assert launched.returncode==1 and '.secondmate-relaunch-sm' in launched.stdout,launched.stdout
    assert marker.exists()
    for _ in range(60):
        if 'endpoint=alive' in probe():break
        time.sleep(.25)
    else:raise RuntimeError('failed rearm did not leave actual running agent')
    clear_notices();push('actual launch with failed ledger rearm still receives push notice','codex',False)
    clear_notices();boot('actual launch with failed ledger rearm still receives bootstrap notice','claude',False)
except Exception as e:
    log.write('DRIVER ERROR: '+repr(e)+'\n'); log.flush()
    results.append({'scenario':'driver','result':'fail','error':repr(e)})
    raise
finally:
    for p in children:
        if p.poll() is None:p.terminate();p.wait(timeout=10)
    if (L/'tmux').exists():tm('kill-server',check=False)
    if S.exists():run(['git','-C',P,'worktree','remove','--force',S],check=False)
    if L.exists():
        for d,_,_ in os.walk(L):os.chmod(d,os.stat(d).st_mode|0o700)
        shutil.rmtree(L)
    (E/'live-spawn-results.json').write_text(json.dumps(results,indent=2)+'\n');log.close()
