import os, pathlib, subprocess, time, signal, json, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6NB5GZ0JJXHQ1W6PXYBHV7C')
lab=root/'.v'
log=(evidence/'live-tmux-transcript.log').open('w',buffering=1)
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'HERDR_', 'CMUX_', 'TASKS_AXI_')) or k in ('TMUX','TMUX_PANE','GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN'):
        env.pop(k,None)
env.update(FM_HOME=str(lab), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GH_CONFIG_DIR=str(lab/'gh'), TMPDIR=str(lab/'tmp'), TMUX_TMPDIR=str(lab/'tmux'))
server=None
results=[]
def run(args, timeout=150, check=True, extra=None):
    e=env.copy()
    if extra: e.update(extra)
    start=time.monotonic()
    p=subprocess.run(args,cwd=root,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    log.write('$ '+repr(args)+'\n'+p.stdout+f'EXIT={p.returncode} ELAPSED={time.monotonic()-start:.3f}s\n')
    if check and p.returncode: raise RuntimeError(p.stdout)
    return p

def shell(code, **kw): return run(['bash','-c',code],**kw)
def record(name,start,**details):
    r=dict(name=name,elapsed_seconds=round(time.monotonic()-start,3),**details)
    results.append(r)
    log.write(json.dumps(r)+'\n')
try:
    run(['bash','bin/fm-lab-home.sh','create',str(lab)])
    for d in ('tmp','tmux','gh','repo'): (lab/d).mkdir()
    run(['git','-C',str(lab/'repo'),'init','-q','-b','main'])
    (lab/'repo'/'README').write_text('disposable clean task copy\n')
    run(['git','-C',str(lab/'repo'),'add','README'])
    run(['git','-C',str(lab/'repo'),'-c','user.name=Phase Test','-c','user.email=test@example.invalid','commit','-qm','initial'])
    tm=['tmux','-L','fm-lab']
    run(tm+['-f','/dev/null','new-session','-d','-x','120','-y','40','-s','recovery','-n','task-00','bash --noprofile --norc'])
    server=int(run(tm+['display-message','-p','#{pid}']).stdout.strip())
    socket=run(tm+['display-message','-p','#{socket_path}']).stdout.strip()
    env['TMUX']=f'{socket},{server},0'
    for i in range(1,69):
        run(tm+['new-window','-d','-t','recovery','-n',f'task-{i:02d}','bash --noprofile --norc'])
    for i in range(69):
        (lab/'state'/f'task-{i:02d}.meta').write_text(f'kind={"ship" if i%2==0 else "scout"}\nbackend=tmux\nwindow=recovery:task-{i:02d}\nworktree={lab}/repo\nharness=codex\n')
    inventory=run(tm+['list-windows','-t','recovery','-F','#{window_name}']).stdout.splitlines()
    assert len(inventory)==69,inventory
    # Read the real shell and absent endpoint through the changed timed helper.
    p=shell('. bin/fm-crew-recovery-lib.sh\nprintf "shell="\nfm_crew_recovery_read_agent_state tmux recovery:task-00\nprintf "absent="\nfm_crew_recovery_read_agent_state tmux recovery:absent')
    assert p.stdout=='shell=dead\nabsent=missing\n',p.stdout
    original={p.name:p.read_bytes() for p in (lab/'state').glob('*.meta')}
    affinity=min(os.sched_getaffinity(0))
    prefix=['taskset','-c',str(affinity)]
    # Run the actual deferred stage with a genuine current-harness lock in the lab.
    lock=run(['bash','bin/fm-lock.sh'],check=False)
    assert lock.returncode==0,'Could not acquire isolated lab lock: '+lock.stdout
    start=time.monotonic()
    stage=run(prefix+['bash','bin/fm-startup-network.sh','run','--locked','1'])
    report=run(['bash','bin/fm-startup-network.sh','report'])
    state=(lab/'state'/'.startup-network.status').read_text()
    timing=(lab/'state'/'.startup-network.timings').read_text()
    log.write('PERSISTED STATUS\n'+state+'PERSISTED TIMINGS\n'+timing)
    assert 'state=done\n' in state and 'locked=1\n' in state and 'rc=0\n' in state,state
    assert '\tcrew-recovery\t' in timing,timing
    assert time.monotonic()-start<120
    assert 'CREW_RECOVERY:' not in report.stdout,report.stdout
    record('69 real shell endpoints: deferred stage finishes on one CPU with crew-recovery timing',start,cpu=affinity,records=69,stage_status='done',metadata_preserved=True)
    # Freeze only the owned lab server: actual tmux clients now block in IPC.
    os.kill(server,signal.SIGSTOP)
    start=time.monotonic()
    probe=shell('. bin/fm-crew-recovery-lib.sh\nfm_crew_recovery_read_agent_state tmux recovery:task-00',timeout=10)
    assert probe.stdout=='unreadable\n',probe.stdout
    assert time.monotonic()-start<6
    record('Unresponsive real backend read becomes unreadable in bounded time',start,output=probe.stdout.strip())
    start=time.monotonic()
    sweep=run(prefix+['bash','-c','. bin/fm-crew-recovery-lib.sh\nfm_crew_recovery_sweep'],timeout=90)
    assert sweep.stdout=='',sweep.stdout
    assert time.monotonic()-start<90
    assert original=={p.name:p.read_bytes() for p in (lab/'state').glob('*.meta')}
    record('All 69 real backend reads hang: sweep finishes without recovery or metadata changes',start,records=69)
    os.kill(server,signal.SIGCONT)
    # Direct eligibility recheck used by control must still see a changed endpoint.
    run(tm+['new-window','-d','-t','recovery','-n','busy','sleep 300'])
    (lab/'repo'/'unlanded').write_text('preserve me\n')
    (lab/'state'/'candidate.meta').write_text(f'kind=ship\nbackend=tmux\nwindow=recovery:task-00\nworktree={lab}/repo\nharness=codex\n')
    start=time.monotonic()
    eligible=shell('. bin/fm-crew-recovery-lib.sh\nfm_crew_recovery_agent_state "$FM_HOME/state" candidate',timeout=20)
    assert eligible.stdout=='dead\n',eligible.stdout
    (lab/'state'/'candidate.meta').write_text(f'kind=ship\nbackend=tmux\nwindow=recovery:busy\nworktree={lab}/repo\nharness=codex\n')
    rejected=shell('. bin/fm-crew-recovery-lib.sh\nfm_crew_recovery_agent_state "$FM_HOME/state" candidate',timeout=20,check=False)
    assert rejected.returncode==1 and rejected.stdout=='',rejected.stdout
    assert (lab/'repo'/'unlanded').read_text()=='preserve me\n'
    record('Fresh direct eligibility accepts a dead dirty task and refuses its busy replacement',start,unlanded_file_preserved=True)
finally:
    if server:
        try: os.kill(server,signal.SIGCONT)
        except ProcessLookupError: pass
        run(['tmux','-L','fm-lab','kill-server'],check=False,timeout=10)
    shutil.rmtree(lab,ignore_errors=True)
    (evidence/'live-tmux-results.json').write_text(json.dumps(results,indent=2)+'\n')
    log.write('CLEANUP: private tmux stopped; disposable lab removed.\n')
    log.close()
