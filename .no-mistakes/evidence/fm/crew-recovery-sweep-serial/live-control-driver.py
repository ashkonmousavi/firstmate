import os,pathlib,subprocess,signal,time,shutil,json
root=pathlib.Path.cwd(); lab=root/'.v'
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_','HERDR_','CMUX_','TASKS_AXI_')) or k in ('TMUX','TMUX_PANE'): env.pop(k,None)
env.update(FM_HOME=str(lab),TMPDIR=str(lab/'tmp'),TMUX_TMPDIR=str(lab/'tmux'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null')
def run(args,check=True):
    p=subprocess.run(args,env=env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=20)
    print('$',repr(args),flush=True);print(p.stdout,end='',flush=True);print('EXIT',p.returncode,flush=True)
    if check: assert p.returncode==0,p.stdout
    return p
server=None;holder=None
try:
    run(['bash','bin/fm-lab-home.sh','create',str(lab)])
    for d in ('tmp','tmux','repo'): (lab/d).mkdir()
    run(['git','-C',str(lab/'repo'),'init','-q','-b','main'])
    (lab/'repo'/'unlanded').write_text('keep this work\n')
    tm=['tmux','-L','fm-lab']
    run(tm+['-f','/dev/null','new-session','-d','-x','120','-y','40','-s','recovery','-n','shell','bash --noprofile --norc'])
    server=int(run(tm+['display-message','-p','#{pid}']).stdout.strip())
    socket=run(tm+['display-message','-p','#{socket_path}']).stdout.strip()
    env['TMUX']=f'{socket},{server},0'
    for name in ('a-first','b-later','c-last','00-released','01-secondmate'):
        kind='secondmate' if name=='01-secondmate' else 'ship'
        (lab/'state'/f'{name}.meta').write_text(f'kind={kind}\nbackend=tmux\nwindow=recovery:shell\nworktree={lab}/repo\nharness=codex\nspawn_gen=s1000.1.1\n')
    (lab/'state'/'00-released.released').write_text('fm-lane-release-v1\ntask=00-released\nspawn_gen=s1000.1.1\nresult=released\n')
    (lab/'state'/'02-link.meta').symlink_to(lab/'state'/'a-first.meta')
    original={p.name:p.read_bytes() for p in (lab/'state').glob('*.meta')}
    holder=subprocess.Popen(['bash','-c','. bin/fm-wake-lib.sh\nfm_lock_try_acquire "$FM_HOME/state/.control-a-first.lock" || exit 1\ntrap \'fm_lock_release "$FM_HOME/state/.control-a-first.lock"\' EXIT\ntouch "$FM_HOME/ready"\nsleep 60'],cwd=root,env=env,start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    for _ in range(100):
        if (lab/'ready').exists(): break
        if holder.poll() is not None: raise RuntimeError(holder.communicate())
        time.sleep(.02)
    assert (lab/'ready').exists()
    direct=run(['bash','bin/fm-control.sh','a-first','relaunch','--if-recoverable'],check=False)
    assert direct.returncode==75 and 'another lifecycle action is already running for task a-first' in direct.stdout,direct.stdout
    start=time.monotonic()
    out=run(['bash','-c','. bin/fm-crew-recovery-lib.sh\nfm_crew_recovery_sweep']).stdout
    expected='CREW_RECOVERY: a-first: relaunch deferred after dead: another lifecycle action is already running for task a-first\n'
    assert out.startswith('CREW_RECOVERY: a-first: relaunch deferred after dead: ') and len(out.splitlines())==1,out
    assert original=={p.name:p.read_bytes() for p in (lab/'state').glob('*.meta')}
    assert (lab/'repo'/'unlanded').read_text()=='keep this work\n'
    assert not list((lab/'state').glob('b-later.*'))==[]
    assert not (lab/'state'/'.control-b-later.lock').exists()
    assert not (lab/'state'/'.control-c-last.lock').exists()
    print(json.dumps(dict(result='pass',elapsed_seconds=round(time.monotonic()-start,3),first_task='a-first',deferred=True,later_tasks_untouched=True,excluded_released_secondmate_symlink=True,unlanded_work_preserved=True)),flush=True)
finally:
    if holder:
        os.killpg(holder.pid,signal.SIGTERM)
        holder.communicate(timeout=5)
    if server: run(['tmux','-L','fm-lab','kill-server'])
    shutil.rmtree(lab,ignore_errors=True)
    print('CLEANUP: owned lifecycle-lock holder exited; private tmux stopped; disposable lab removed.',flush=True)
