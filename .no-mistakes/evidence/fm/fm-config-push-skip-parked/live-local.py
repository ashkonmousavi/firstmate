import os, pathlib, subprocess, json, time, shutil
W=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M68RDV1CW6E2AMQX2N5CQ690')
P=W/'.test-disposable/product'; L=W/'.l'; S=W/'.s'
log=(E/'live-local.log').open('w'); results=[]; children=[]
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
    log.write('WATCHER PARK RECORD: '+marker.read_text());log.flush()
    push('parked config push updates files without a notice','codex',True)
    push('repeated parked config push never refills inbox','claude',True)
    boot('bootstrap parked convergence updates files without a notice','codex',True)
    # Start the installed, real harness in the existing private endpoint.
    tm('send-keys','-t','firstmate:fm-sm',f'''codex --no-daemon -c 'projects."{S}".trust_level="trusted"' ''','Enter')
    for _ in range(60):
        if 'endpoint=alive' in probe(): break
        time.sleep(.25)
    else:raise RuntimeError('installed Codex did not start')
    time.sleep(2)
    screen=tm('capture-pane','-p','-t','firstmate:fm-sm').stdout
    (E/'live-codex-pane.txt').write_text(screen)
    assert marker.exists()
    # Failed bookkeeping record plus real running endpoint must retain notices.
    (L/'state/.secondmate-relaunch-sm').unlink();(L/'state/.secondmate-relaunch-sm').mkdir()
    clear_notices();push('running agent with stale park marker and failed ledger receives push notice','claude',False)
    clear_notices();boot('running agent with stale park marker receives bootstrap notice','codex',False)
    assert marker.exists(),'read-only classification changed marker'
    # Ask the public control plane to stop the actual process, preserving work.
    tm('send-keys','-t','firstmate:fm-sm','C-u')
    time.sleep(.5)
    stopped=run([P/'bin/fm-control.sh','sm','exit'],check=False,timeout=45)
    results.append({'scenario':'deliberate exit preserves work and sends next notice','result':'pending','control_exit':stopped.returncode})
    assert stopped.returncode==0,stopped.stdout
    assert 'endpoint=dead' in probe(); assert (S/'preserved-work.txt').read_text()=='unsaved work must survive\n'
    # This marker belongs to the prior watcher park; rearm it as a normal
    # successful launch would, before checking the no-marker exit contract.
    marker.unlink()
    clear_notices();push('deliberately exited mate without park proof keeps its notice','claude',False)
    results[-2]['result']='pass'
except Exception as e:
    log.write('DRIVER ERROR: '+repr(e)+'\n'); log.flush()
    results.append({'scenario':'driver','result':'fail','error':repr(e)})
    raise
finally:
    for p in children:
        if p.poll() is None:p.terminate();p.wait(timeout=10)
    if (L/'tmux').exists():tm('kill-server',check=False)
    if S.exists():run(['git','-C',P,'worktree','remove','--force',S],check=False)
    if L.exists():shutil.rmtree(L)
    (E/'live-local-results.json').write_text(json.dumps(results,indent=2)+'\n');log.close()
