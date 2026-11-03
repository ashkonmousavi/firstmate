import os, pathlib, subprocess, shutil, time, hashlib, json, signal
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M6GJ8YJKZ2XE36Z9WMW993A5')
LAB=ROOT/'.v'
LOG=(E/'live-owner-park.log').open('w', buffering=1)
children=[]
results=[]
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'REX_', 'TASKS_AXI_')) and k not in ('TMUX','NO_MISTAKES_GATE')}
env.update(FM_HOME=str(LAB/'p'), FM_BACKEND='tmux', TMUX_TMPDIR=str(LAB/'t'), TMPDIR=str(LAB/'tmp'), GH_CONFIG_DIR=str(LAB/'gh'))
def run(args, expected=0, e=None, stdin=None, timeout=60):
    LOG.write('$ '+ ' '.join(map(str,args))+'\n')
    p=subprocess.run(list(map(str,args)),cwd=ROOT,env=e or env,input=stdin,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    LOG.write(p.stdout+f'[exit {p.returncode}]\n')
    assert p.returncode==expected,(args,p.returncode,p.stdout)
    return p.stdout

def script(name,*args,**kw): return run([ROOT/'bin'/name,*args],**kw)
def spawn(args,e=None):
    p=subprocess.Popen(list(map(str,args)),cwd=ROOT,env=e or env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
    children.append(p)
    return p

def finish(p,expected=0):
    out=p.communicate(timeout=30)[0]
    LOG.write(out+f'[child exit {p.returncode}]\n')
    assert p.returncode==expected,(p.returncode,out)
    return out

def waitfile(path,contains=None,timeout=20):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if path.exists() and (contains is None or contains in path.read_text(errors='replace')): return
        time.sleep(.1)
    raise AssertionError(f'timed out waiting for {path} {contains}')

def passed(name):
    results.append(dict(name=name,result='pass',live=True))
    LOG.write('SCENARIO PASS: '+name+'\n')

def holder(state,lock,tag,e):
    pathlib.Path(lock).parent.mkdir(parents=True,exist_ok=True)
    ready=LAB/(tag+'.ready'); release=LAB/(tag+'.release')
    cmd='. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; touch "$3"; while [ ! -e "$4" ]; do sleep .05; done'
    p=spawn(['bash','-c',cmd,'_',ROOT,lock,ready,release],e)
    waitfile(ready)
    return p,release

try:
    LAB.mkdir()
    (LAB/'tmp').mkdir()
    script('fm-lab-home.sh','create',LAB/'p')
    (LAB/'t').mkdir()
    p=LAB/'p'; mate=LAB/'m'
    script('fm-lab-home.sh','create',mate)
    (mate/'.fm-secondmate-home').write_text('eel-web\n')
    (mate/'AGENTS.md').write_text('# Disposable secondmate\n')
    (mate/'bin').symlink_to(ROOT/'bin',target_is_directory=True)
    (mate/'data/charter.md').write_text('Disposable CLI validation; no project work.\n')
    (p/'data/secondmates.md').write_text(f'- eel-web - Disposable mate (home: {mate}; scope: isolated verification; projects: none; added 2026-11-03)\n')
    meta=p/'state/eel-web.meta'
    meta.write_text(f'window=primary:fm-eel-web\nkind=secondmate\nharness=claude\nbackend=tmux\nworktree={mate}\nproject={mate}\nhome={mate}\n')
    run(['tmux','-L','fm-lab','new-session','-d','-x','100','-y','30','-s','primary','-n','anchor','-c',ROOT,'/bin/sh'])
    env['TMUX']=run(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path},#{pid},0']).strip()
    script('fm-secondmate-park.sh','status','eel-web',expected=1)
    script('fm-secondmate-park.sh','park','eel-web')
    record=p/'config/secondmate-parked/eel-web'
    assert record.read_text()=='owner '+time.strftime('%Y-%m-%d',time.gmtime())+'\n'
    assert record.stat().st_mode & 0o777==0o600
    assert record.parent.stat().st_mode & 0o777==0o700
    LOG.write('Persisted owner record: '+record.read_text()+'Permissions: file 0600, directory 0700\n')
    script('fm-secondmate-park.sh','status','eel-web')
    passed('Park a registered secondmate and read its durable private UTC-dated owner record')
    script('fm-secondmate-restart.sh','eel-web',expected=3)
    be=env|{'FM_BOOTSTRAP_NETWORK':'only'}
    out=script('fm-bootstrap.sh',e=be,timeout=90)
    assert 'SECONDMATE_LIVENESS: secondmate eel-web: owner park' in out
    assert not (p/'state/.secondmate-relaunch-eel-web').exists()
    assert 'fm-eel-web' not in run(['tmux','-L','fm-lab','list-windows','-t','primary','-F','#{window_name}'])
    script('fm-secondmate-park.sh','status','eel-web')
    passed('Run restart and the session-start recovery sweep; a parked missing mate remains stopped with no launch attempt')
    # Run the actual watcher, then stop its own process group after its liveness report is retained.
    we=env|{'FM_POLL':'1','FM_SECONDMATE_LIVENESS_SECS':'1','FM_CHECK_INTERVAL':'999999','FM_HEARTBEAT':'999999'}
    w=spawn([ROOT/'bin/fm-watch.sh'],we)
    end=time.monotonic()+30; found=None
    while time.monotonic()<end and w.poll() is None:
        for path in (p/'state').glob('*triage*'):
            if path.is_file() and 'owner park' in path.read_text(errors='replace'): found=path; break
        if found: break
        time.sleep(.2)
    if not found:
        LOG.write('Watcher diagnostic files: '+str(list((p/'state').iterdir()))+'\n')
    assert found,'watcher did not publish owner-park triage'
    LOG.write('Actual watcher triage:\n'+found.read_text())
    os.killpg(w.pid,signal.SIGTERM)
    out=w.communicate(timeout=15)[0]; LOG.write(out+f'[watcher stopped: {w.returncode}]\n')
    assert w.returncode in (0,143,-15)
    assert not (p/'state/.secondmate-relaunch-eel-web').exists()
    assert not (p/'state/.secondmate-relaunch-bound-eel-web').exists()
    passed('Ordinary monitoring refuses recovery without creating a crash-loop marker or relaunch ledger')
    run(['tmux','-L','fm-lab','new-window','-d','-t','primary','-n','fm-eel-web','/bin/sh'])
    for name,args in [('fm-spawn.sh',['eel-web','--secondmate']),('fm-spawn.sh',['eel-web','--relaunch']),('fm-control.sh',['eel-web','relaunch'])]:
        out=script(name,*args,expected=1)
        assert 'owner-park' in out or 'owner park' in out
    with meta.open('a') as f: f.write('remote_host=disposable-host\n')
    out=script('fm-remote-secondmate-relaunch.sh','eel-web','claude','default','default',expected=1)
    assert 'owner-park' in out
    passed('Explicit fresh spawn, replacement, control relaunch and remote relaunch all refuse a parked mate')
    # Rearming the independent crash-loop marker must never remove the owner decision.
    (p/'state/.secondmate-relaunch-bound-eel-web').write_text('1\tdead\n')
    run(['bash','-c','. "$1/bin/fm-secondmate-liveness-lib.sh"; STATE="$FM_HOME/state"; fm_secondmate_liveness_rearm eel-web','_',ROOT])
    assert not (p/'state/.secondmate-relaunch-bound-eel-web').exists() and record.exists()
    script('fm-secondmate-park.sh','status','eel-web')
    script('fm-secondmate-park.sh','unpark','eel-web')
    script('fm-secondmate-park.sh','status','eel-web',expected=1)
    script('fm-secondmate-park.sh','unpark','eel-web')
    passed('Crash-loop rearm preserves owner park and only explicit unpark clears it')
    h,release=holder(p/'state',p/'state/.spawn-eel-web.lock','local',env)
    parker=spawn([ROOT/'bin/fm-secondmate-park.sh','park','eel-web'])
    time.sleep(.5)
    assert parker.poll() is None and not record.exists()
    LOG.write('park remains pending while a real spawn transaction lock is held\n')
    release.touch(); finish(h); finish(parker)
    assert record.exists()
    passed('Park publication waits for an in-flight local spawn transaction to finish')
    # Record contract adversaries, driven through public CLI only.
    script('fm-secondmate-park.sh','park','unregistered',expected=1)
    assert not (record.parent/'unregistered').exists()
    record.write_text('owner 2026-02-31\n')
    script('fm-secondmate-park.sh','status','eel-web',expected=2)
    out=script('fm-spawn.sh','eel-web','--secondmate',expected=1); assert 'owner-park' in out
    record.unlink(); outside=p/'config/sentinel'; outside.write_text('preserve\n'); record.symlink_to(outside)
    script('fm-secondmate-park.sh','unpark','eel-web',expected=2)
    script('fm-secondmate-park.sh','status','eel-web',expected=2)
    assert record.is_symlink() and outside.read_text()=='preserve\n'
    record.unlink(); script('fm-secondmate-park.sh','park','eel-web')
    passed('Unregistered ids and malformed or symlink park records cannot authorize a launch or remove unrelated data')
    # The actual remote receiver, with no SSH or backend substitutes.
    re=env|{'FM_HOME':str(mate),'FM_ROOT_OVERRIDE':str(mate)}
    remote=mate/'config/secondmate-parked/eel-web'
    payload=record.read_text(); size=str(len(payload.encode())); digest=hashlib.sha256(payload.encode()).hexdigest()
    h,release=holder(mate/'state/parent-route',mate/'state/parent-route/.control-eel-web.lock','remote',re)
    recv=subprocess.Popen([str(ROOT/'bin/fm-remote-inherit.sh'),'put','config/secondmate-parked/eel-web',size,digest,'10'],cwd=ROOT,env=re,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
    children.append(recv); recv.stdin.write(payload); recv.stdin.close(); recv.stdin=None
    time.sleep(.5); assert recv.poll() is None and not remote.exists()
    LOG.write('Remote park remains pending until the remote control transaction completes\n')
    release.touch(); finish(h); out=finish(recv); assert 'pushed:' in out and remote.read_text()==payload
    out=script('fm-spawn.sh','eel-web','--secondmate',e=env|{'FM_HOME':str(mate)},expected=1)
    assert 'owner-park' in out and not (mate/'state/parent-route/eel-web.meta').exists()
    empty=hashlib.sha256(b'').hexdigest()
    script('fm-remote-inherit.sh','absent','config/secondmate-parked/eel-web','0',empty,'11',e=re,stdin='')
    out=script('fm-remote-inherit.sh','put','config/secondmate-parked/eel-web',size,digest,'10',e=re,stdin=payload,expected=1)
    assert 'superseded' in out and not remote.exists()
    script('fm-remote-inherit.sh','put','config/secondmate-parked/sibling',size,digest,'12',e=re,stdin=payload,expected=1)
    passed('Remote publication waits for launch exclusion, blocks a late spawn in the receiving home, and rejects stale or wrong-mate updates')
finally:
    for child in children:
        if child.poll() is None:
            os.killpg(child.pid,signal.SIGTERM)
            try: child.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid,signal.SIGKILL); child.communicate()
    if (LAB/'t').exists():
        p=subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        LOG.write('Private tmux cleanup: '+str(p.returncode)+' '+p.stdout+'\n')
    shutil.rmtree(LAB,ignore_errors=True)
    (E/'live-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
    LOG.close()
