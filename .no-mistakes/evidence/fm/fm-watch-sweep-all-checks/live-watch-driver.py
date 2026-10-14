import os, pathlib, tempfile, subprocess, json, shutil, shlex, time, re
root=pathlib.Path.cwd()
ev=pathlib.Path('~/.no-mistakes/evidence/01M4X4C124HRZB8H8YV6XNJHQP')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.watch-lab-',dir=root))
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_')) and k not in ('TMUX','TMUX_TMPDIR')}
env.update(FM_HOME=str(lab),TMUX=str(lab/'socket')+',1,0',TMUX_TMPDIR=str(lab),FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='0',FM_HEARTBEAT='999999')
log=[]
def run(args,timeout=35,check=True):
    p=subprocess.run(args,cwd=root,env=env,text=True,capture_output=True,timeout=timeout)
    log.append('$ '+shlex.join(map(str,args))+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
    if check: assert p.returncode==0,log[-1]
    return p

def check(name,body,registered=True):
    f=lab/'state'/(name+'.check.sh')
    f.write_text('#!/usr/bin/env bash\n'+body+'\n');f.chmod(0o700)
    if registered:run(['bin/fm-check-register.sh',name])

def watch(label,timeout=30):
    p=run(['bin/fm-watch.sh'],timeout)
    if p.stdout.strip() == 'check: rearm-resurface':
        drain(label+'-rearm')
        p=run(['bin/fm-watch.sh'],timeout)
    (ev/(label+'-wake.txt')).write_text(p.stdout+p.stderr)
    assert len(p.stdout.strip().splitlines())==1,p.stdout
    return p

def drain(label):
    p=run(['bin/fm-wake-drain.sh'])
    (ev/(label+'-drain.txt')).write_text(p.stdout+p.stderr)
    rows = [l.split('\t') for l in p.stdout.splitlines() if len(l.split('\t'))==5]
    ack=re.search(r'--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)',p.stderr)
    assert ack,p.stderr
    run(['bin/fm-wake-drain.sh','--ack-through',ack[1],'--recovery-generation',ack[2]])
    return rows
try:
    run(['bin/fm-lab-home.sh','create',str(lab)])
    check('a-news','echo memory-low; echo early >> "$FM_HOME/executions"')
    check('b-quiet','echo quiet >> "$FM_HOME/executions"')
    check('c-news','echo disk-full; echo late >> "$FM_HOME/executions"')
    watch('all-checks'); rows=drain('all-checks')
    assert len(rows)==2 and [r[4] for r in rows]==[f'check: {lab}/state/a-news.check.sh: memory-low',f'check: {lab}/state/c-news.check.sh: disk-full'],rows
    assert (lab/'executions').read_text().splitlines()==['early','quiet','late']
    log.append('Observed execution order: '+(lab/'executions').read_text())
    marker=(lab/'state/.last-check').stat().st_mtime_ns
    env['FM_CHECK_INTERVAL']='60'
    p=subprocess.Popen(['bin/fm-watch.sh'],env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:out,err=p.communicate(timeout=3);raise AssertionError('watcher woke before next check interval: '+out+err)
    except subprocess.TimeoutExpired:
        p.terminate();out,err=p.communicate(timeout=10)
    assert not out,out
    assert (lab/'executions').read_text().splitlines()==['early','quiet','late']
    assert (lab/'state/.last-check').stat().st_mtime_ns==marker
    log.append('Cadence: rearmed watcher remained blocking for 3 seconds; no check re-executed and cadence timestamp unchanged.\n')
    env['FM_CHECK_INTERVAL']='0'
    check('b-hostile','touch "$FM_HOME/UNSAFE_EXECUTED"; echo compromised',False)
    watch('rejected-check'); rows=drain('rejected-check')
    assert not (lab/'UNSAFE_EXECUTED').exists()
    assert any(r[3]=='unauthenticated-state-checks' for r in rows),rows
    assert sum(r[4].endswith('disk-full') for r in rows)==1,rows
    log.append('Unregistered check was never executed; late registered check and rejection both appear in durable drain.\n')
    # Remove the disposable unsafe check through the public unregister interface.
    run(['bin/fm-check-unregister.sh','b-hostile'])
    run(['bin/fm-check-unregister.sh','a-news'])
    # Real read-only public GitHub PR, no forge mutation or fabricated poll response.
    (lab/'state/b-merged.meta').write_text('kind=ship\nmode=no-mistakes\nworktree='+str(root)+'\n')
    run(['bin/fm-pr-check.sh','b-merged','https://github.com/cli/cli/pull/1'])
    watch('merged-and-late'); rows=drain('merged-and-late')
    assert any('github.com/cli/cli/pull/1' in r[4] and 'merged' in r[4] for r in rows),rows
    assert any(r[4].endswith('disk-full') for r in rows),rows
    assert not (lab/'state/b-merged.check.sh').exists()
    assert not (lab/'state/b-merged.pr-poll').exists()
    log.append('Real merged GitHub PR retired; late custom check queued in the same sweep.\n')
    # A registered contributions integration publishes its own durable wake.
    check('contributions', '. '+shlex.quote(str(root/'bin/fm-wake-lib.sh'))+'\nfm_wake_append check contributions "check: contributions lab-event"\necho "contribution-wake: check: contributions lab-event"')
    watch('contributions-and-late'); rows=drain('contributions-and-late')
    assert any(r[3]=='contributions' for r in rows),rows
    assert any(r[4].endswith('disk-full') for r in rows),rows
    log.append('Contribution producer wake and late custom check are both durable; one immediate watcher wake.\n')
    run(['bin/fm-check-unregister.sh','c-news'])
    p=watch('contributions-only'); rows=drain('contributions-only')
    assert p.stdout.strip()=='check: contributions lab-event',p.stdout
    assert len(rows)==1 and rows[0][3]=='contributions',rows
    run(['bin/fm-check-unregister.sh','contributions'])
    check('b-hostile','touch "$FM_HOME/UNSAFE_EXECUTED"; echo compromised',False)
    p=watch('rejected-only'); rows=drain('rejected-only')
    assert p.stdout.startswith('check: rejected unauthenticated state checks:'),p.stdout
    assert len(rows)==1 and rows[0][3]=='unauthenticated-state-checks',rows
    assert not (lab/'UNSAFE_EXECUTED').exists()
    log.append('Contribution-only and rejection-only sweeps each wake once and deliver the expected durable record.\n')
    (ev/'live-watch-transcript.txt').write_text('\n'.join(log))
    print('All live watch scenarios passed; transcript and wake/drain outputs saved.')
finally:
    (ev/'live-watch-transcript.txt').write_text('\n'.join(log))
    shutil.rmtree(lab)
