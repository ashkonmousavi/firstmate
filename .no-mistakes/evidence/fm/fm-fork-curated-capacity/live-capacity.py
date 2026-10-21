import os, pathlib, subprocess, json, shutil, time
root=pathlib.Path.cwd(); lab=root/'.l'; evidence=pathlib.Path('~/.no-mistakes/evidence/01M5G33VFEPFJSDW5QD92BJ881')
assert not lab.exists()
log=[]
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TMUX','NO_MISTAKES_GATE','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
        env.pop(key,None)
env['FM_HOME']=str(lab)
def run(args, code=0, custom=None):
    p=subprocess.run([str(a) for a in args],env=custom or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    log.append('$ '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
    assert p.returncode==code,log[-1]
    return p.stdout
cap=[root/'bin/fm-capacity.sh']
def config(value): (lab/'config/lane-capacity').write_text(value+'\n')
def facts(): return json.loads(run(cap+['--json']))
def meta(home,name,**values):
    (home/'state'/f'{name}.meta').write_text(''.join(f'{k}={v}\n' for k,v in values.items()))
try:
    run([root/'bin/fm-lab-home.sh','create',lab])
    config('2 0')
    f=facts(); assert f['reason']=='ok' and f['free_lanes']==2 and f['headroom_kb']>=0
    run(cap+['--admit'])
    # Real kernel oracle: each finite high excludes reclaimable file cache.
    balances=[]; cg=pathlib.Path('/sys/fs/cgroup')
    membership=next(x.split(':',2)[2] for x in pathlib.Path('/proc/self/cgroup').read_text().splitlines() if x.startswith('0::'))
    current=cg/membership.lstrip('/')
    while True:
        high=current/'memory.high'
        if high.exists() and high.read_text().strip()!='max':
            stats=dict(x.split() for x in (current/'memory.stat').read_text().splitlines())
            balances.append((int(high.read_text())-int(stats['anon'])-int(stats['shmem']))//1024)
        if current==cg: break
        current=current.parent
    # Kernel values vary between reads: report the independent reading, without equality on a moving probe.
    log.append('Independent live kernel memory balances (KiB): '+repr(balances)+'\n')
    if not balances: assert f['mem_available_kb']>0
    config('2 999999'); run(cap+['--admit'],75); assert facts()['reason']=='memory'
    config('2'); run(cap+['--admit'],75)
    (lab/'config/lane-capacity').unlink(); run(cap+['--admit'],75)
    config('2 0')
    # Machine-wide sibling records, including a PR handoff, must retain unknown seats.
    mate=lab/'mate'
    for d in ('config','state','data'): (mate/d).mkdir(parents=True,exist_ok=True)
    (lab/'data/secondmates.md').write_text(f'- mate - local (home: {mate}; scope: tests; projects: a; added 2026-09-01)\n')
    (mate/'.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={lab}\n')
    meta(lab,'unknown',kind='ship',project='a')
    meta(mate,'ready-pr',kind='scout',project='b',pr='https://github.com/example/test/pull/1')
    meta(lab,'mate',kind='secondmate')
    run(cap+['--admit'],75); f=facts(); assert (f['lanes'],f['secondmates'],f['reason'])==(2,1,'full')
    envmate=env.copy(); envmate['FM_HOME']=str(mate)
    nested=json.loads(run(cap+['--json'],custom=envmate)); assert nested['lanes']==2 and nested['target']==2
    (lab/'state/unknown.meta').unlink(); (mate/'state/ready-pr.meta').unlink()
    # Real spawn must defer before allocating a worker or launching a CLI.
    project=lab/'project'; project.mkdir()
    run(['git','init','-q',project])
    run(['git','-C',project,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','--allow-empty','-qm','lab'])
    (lab/'config/backlog-backend').write_text('manual\n')
    (lab/'config/crew-harness').write_text('codex\n')
    (lab/'data/admission').mkdir()
    (lab/'data/admission/brief.md').write_text("# Task\n## Captain's intent\nExercise admission without starting work.\n\n## Firstmate spec\nDisposable capacity validation.\n\n# Definition of done\nDelivery contract: mode=local-only\n")
    spawn=[root/'bin/fm-spawn.sh','admission',project,'--mode','local-only','--yolo','off','--harness','codex','--backend','tmux']
    for declaration in ('0 0','2 999999','2'):
        config(declaration)
        run(spawn,75)
        assert not (lab/'state/admission.meta').exists()
        assert not (lab/'data/admission/launch-brief.md').exists()
        assert len(run(['git','-C',project,'worktree','list','--porcelain']).split('worktree '))==2
    config('2 0')
    # Private real tmux endpoint: no default socket is inspected or mutated.
    sock=lab/'s'; tmux=['tmux','-S',sock]
    run(tmux+['new-session','-d','-s','fm-lab-capacity','-n','fm-stopped','-x','100','-y','30','-c',lab,'bash --noprofile --norc'])
    env['TMUX']=str(sock)+',0,0'
    wt=lab/'work'; wt.mkdir()
    meta(lab,'stopped',kind='ship',backend='tmux',window='fm-lab-capacity:fm-stopped',worktree=wt)
    time.sleep(.3)
    assert facts()['lanes']==0
    proc=subprocess.Popen(['sleep','120'],cwd=wt,env=env)
    try:
        assert facts()['lanes']==1
        config('1 0'); run(cap+['--admit'],75)
    finally:
        proc.terminate(); proc.wait()
    assert facts()['lanes']==0
    run(cap+['--admit'])
    # Relaunch shares fresh admission and preserves the stopped record.
    (lab/'data/stopped').mkdir()
    (lab/'data/stopped/brief.md').write_text((lab/'data/admission/brief.md').read_text())
    meta(lab,'stopped',kind='ship',backend='tmux',window='fm-lab-capacity:fm-stopped',worktree=project,project=project,harness='codex',mode='local-only',yolo='off',branch='fm/stopped')
    meta(lab,'competitor',kind='ship',project='other')
    config('1 0')
    before=(lab/'state/stopped.meta').read_bytes()
    run([root/'bin/fm-spawn.sh','stopped','--relaunch'],75)
    assert (lab/'state/stopped.meta').read_bytes()==before
    run([root/'bin/fm-control.sh','stopped','relaunch','--note','Validate admission with another occupied seat.'],75)
    assert (lab/'state/stopped.meta').read_bytes()==before
    (lab/'state/competitor.meta').unlink()
    # Public reports and publications use the same facts, placement rejects old and failed reports.
    config('2 0')
    run([root/'bin/fm-fleet-view.sh','--capacity'])
    ledger=json.loads(run([root/'bin/fm-fleet-ledger.sh','capacity','--json'])); assert ledger['lanes']==0 and ledger['free_lanes']==2
    published=json.loads(run(cap+['--publish'])); assert json.loads((lab/'state/lane-capacity.json').read_text())==published
    run([root/'bin/fm-place.sh',lab/'state/lane-capacity.json'])
    stale=published.copy(); stale['generated_epoch']=1
    (lab/'stale.json').write_text(json.dumps(stale)); run([root/'bin/fm-place.sh',lab/'stale.json'],75)
    (lab/'config/lane-capacity').unlink(); run(cap+['--publish'],1)
    assert json.loads((lab/'state/lane-capacity.json').read_text())['readable']==False
    run([root/'bin/fm-place.sh',lab/'state/lane-capacity.json'],75)
    log.append('All live capacity/report/placement assertions passed.\n')
finally:
    if (lab/'s').exists():
        subprocess.run(['tmux','-S',str(lab/'s'),'kill-server'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    shutil.rmtree(lab,ignore_errors=True)
    (evidence/'live-capacity.log').write_text('\n'.join(log))
