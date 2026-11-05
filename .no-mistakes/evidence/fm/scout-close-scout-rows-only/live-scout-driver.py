import os, pathlib, subprocess, json, shutil, signal, time
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6PMP5XS3RS0RTB7NANXCK57')
lab=root/'.gate-test-tmp/live-home'
log=(evidence/'live-scout-cli.log').open('w', buffering=1)
results=[]
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) or k in ('TMUX','TERM_PROGRAM'):
        env.pop(k,None)
env.update(FM_HOME=str(lab), HOME=str(lab/'user'), TMPDIR=str(root/'.gate-test-tmp'), TERM='xterm-256color')
def run(args, ok=True, extra=None):
    e=env| (extra or {})
    p=subprocess.run([str(x) for x in args],cwd=root,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    log.write('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+f'[exit {p.returncode}]\n')
    if ok and p.returncode: raise RuntimeError(p.stdout)
    return p

def cli(*args, **kw): return run(['bash',root/'bin/fm-tasks-axi.sh',*args],**kw)
def state(i):
    p=cli('show',i,'--full').stdout
    return next(x.split(': ',1)[1] for x in p.splitlines() if x.startswith('  state: ')),p

def meta(i,endpoint=True):
    (lab/'data'/i).mkdir(exist_ok=True)
    (lab/'data'/i/'report.md').write_text('Prep findings: durable evidence for '+i+'\n')
    (lab/'data'/i/'prep.md').write_text('Completed prep\n')
    (lab/'data'/i/'brief.md').write_text('Disposable prep scout\n')
    (lab/'data'/i/'autolaunch-prep').write_text('project=phase\nkind=scout\n')
    (lab/'state'/f'{i}.meta').write_text(f'window=fm-lab:fm-{i}\nendpoint_task_id={i}\nbackend=tmux\nworktree={lab}/absent-{i}\nproject={lab}/projects/phase\nharness=claude\nkind=scout\nmode=local-only\nyolo=off\nspawn_gen=lab-{i}\ndecisions_reviewed=1\n')
    if endpoint: run(['tmux','-S',sock,'new-window','-d','-t','fm-lab','-n','fm-'+i,'sleep 600'])

def record(name,**d):
    results.append(dict(name=name,**d)); log.write('OBSERVED '+json.dumps(results[-1])+'\n')

sock=''
try:
    run(['bash',root/'bin/fm-lab-home.sh','create',lab])
    (lab/'user').mkdir(); (lab/'tmux').mkdir(); (lab/'projects/phase').mkdir()
    (lab/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\ndone_keep = 100\n')
    (lab/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    # /proc alias shortens the unix socket name while its bytes stay in the worktree.
    fd=os.open(lab/'tmux',os.O_RDONLY)
    sock=f'/proc/{os.getpid()}/fd/{fd}/sock'
    run(['tmux','-S',sock,'new-session','-d','-s','fm-lab','-n','anchor','-x','100','-y','30','sleep 600'])
    pid=run(['tmux','-S',sock,'display-message','-p','-t','fm-lab','#{pid}']).stdout.strip()
    env['TMUX']=f'{sock},{pid},0'
    for i,k,b in [('legacy-build',None,''),('task-build','task',''),('ship-build','ship',''),('owner-scout','scout','SLICE: main/owner | role=owner'),('plain-scout','scout',''),('other-row','bug','')]:
        if k is None:
            p=lab/'data/backlog.md'
            p.write_text(p.read_text().replace('## Queued\n',f'## Queued\n- [ ] {i} - legacy BUILD data/{i}/report.md blocked-by: dep-a blocked-by: dep-b\n'))
        else:
            cli('add',i,'Disposable row','--kind',k)
            if b: cli('update',i,'--body',b)
        cli('start',i)
        meta(i)
        before,shown=state(i)
        deps=next((x for x in shown.splitlines() if x.startswith('  deps:')),None)
        cli('done',i,'--report',f'data/{i}/report.md')
        after,shown=state(i)
        expected='done' if i=='plain-scout' else 'in_flight'
        assert after==expected,(i,after,expected)
        assert deps==next((x for x in shown.splitlines() if x.startswith('  deps:')),None)
        run(['bash',root/'bin/fm-lease.sh','claim',i])
        run(['bash',root/'bin/fm-teardown.sh',i])
        after,shown=state(i)
        assert after==('done' if i=='plain-scout' else 'queued'),(i,after)
        assert f'data/{i}/report.md' in shown
        assert not (lab/'state'/f'{i}.meta').exists()
        assert (lab/'data'/i/'report.md').exists()
        assert not (lab/'data'/i/'autolaunch-prep').exists() if i!='plain-scout' else True
        windows=run(['tmux','-S',sock,'list-windows','-t','fm-lab','-F','#{window_name}']).stdout.splitlines()
        assert 'fm-'+i not in windows
        record(i,result='pass',completion_state=expected,cleanup_state=after,dependencies=deps,report_retained=True,endpoint_removed=True)
    # Kill the real teardown process after its durable intent marker is published.
    i='interrupted-build'; cli('add',i,'Interrupted BUILD','--kind','task'); cli('start',i); meta(i)
    marker=lab/'state'/f'{i}.backlog-close'
    log.write('$ fm-teardown.sh interrupted-build [SIGKILL after pending-close publication]\n')
    p=subprocess.Popen(['bash',str(root/'bin/fm-teardown.sh'),i],cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    deadline=time.monotonic()+45
    while time.monotonic()<deadline and p.poll() is None and not marker.exists(): time.sleep(.001)
    assert marker.exists(), 'cleanup never published its pending-close marker'
    os.killpg(p.pid,signal.SIGSTOP)
    assert (lab/'state'/f'{i}.meta').exists(), 'missed interruption window'
    os.killpg(p.pid,signal.SIGKILL)
    rc=p.wait(timeout=10)
    log.write(f'[interrupted cleanup exit {rc}]\n'+marker.read_text())
    assert rc==-signal.SIGKILL
    before=state(i)[0]; assert before=='in_flight'
    # Same production replay used by bootstrap, driven without unrelated startup work.
    replay='. "$1/bin/fm-tasks-axi-lib.sh"\n. "$1/bin/fm-backlog-transition-lib.sh"\nfm_backlog_close_marker_replay "$2/state" "$2/state/$3.backlog-close" "$2/data" || { echo "$FM_BACKLOG_TRANSITION_ERROR"; exit 1; }\nprintf \'Replay result: %s\\n\' "$FM_BACKLOG_CLOSE_REPLAY_RESULT"\n'
    run(['bash','-c',replay,'_',root,lab,i])
    after,shown=state(i)
    assert after=='queued' and not marker.exists() and not (lab/'state'/f'{i}.meta').exists()
    assert 'scout phase finished' in shown and f'data/{i}/report.md' in shown
    assert (lab/'data'/i/'report.md').exists() and not (lab/'data'/i/'autolaunch-prep').exists()
    record(i,result='pass',interrupted_exit=rc,state_before_replay=before,state_after_replay=after,marker_retired=True)
    # A legacy close-mode record carrying only a report also retains the BUILD.
    i='report-replay-build'; cli('add',i,'Report replay BUILD','--kind','task'); cli('start',i); meta(i,False)
    stage='. "$1/bin/fm-tasks-axi-lib.sh"\n. "$1/bin/fm-backlog-transition-lib.sh"\nfm_backlog_close_marker_stage "$2/state/$3.backlog-close" "$3" "$2/data" "lab-$3" "$2/state" 0 --report "data/$3/report.md"\n'
    run(['bash','-c',stage,'_',root,lab,i])
    (lab/'state'/f'{i}.meta').unlink()
    run(['bash','-c',replay,'_',root,lab,i])
    after,shown=state(i); assert after=='queued' and f'data/{i}/report.md' in shown
    assert not (lab/'state'/f'{i}.backlog-close').exists()
    record(i,result='pass',state_after_replay=after,metadata_absent=True,report_retained=True)
    # Exercise actual read failure, not an invented show payload.
    i='unreadable-build'; cli('add',i,'Unreadable outcome','--kind','task'); meta(i)
    backlog=lab/'data/backlog.md'; prior=backlog.read_bytes(); backlog.chmod(0)
    try:
        p=run(['setpriv','--bounding-set=-dac_override,-dac_read_search','bash',root/'bin/fm-tasks-axi.sh','done',i,'--report',f'data/{i}/report.md'],ok=False)
        assert p.returncode!=0
        p2=run(['setpriv','--bounding-set=-dac_override,-dac_read_search','bash',root/'bin/fm-teardown.sh',i],ok=False)
        assert p2.returncode!=0
    finally: backlog.chmod(0o644)
    assert backlog.read_bytes()==prior
    assert state(i)[0]=='queued'
    assert (lab/'state'/f'{i}.meta').exists()
    assert 'fm-'+i in run(['tmux','-S',sock,'list-windows','-t','fm-lab','-F','#{window_name}']).stdout.splitlines()
    record(i,result='pass',done_exit=p.returncode,cleanup_exit=p2.returncode,state='queued',backlog_unchanged=True,endpoint_preserved=True)
    (evidence/'live-scout-results.json').write_text(json.dumps(results,indent=2)+'\n')
finally:
    if sock: run(['tmux','-S',sock,'kill-server'],ok=False)
    shutil.rmtree(lab,ignore_errors=True)
    log.close()
