import os, json, pathlib, subprocess, sys, shutil, time
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M6NJNWM2YZHE7J8AAMK0ZD4F')
lab=ROOT/'.test-tmp'/'live-lab'
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) or k in ('TMUX','TMUX_PANE','GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','REX_SESSION','REX_BLOCK','TERM_PROGRAM'):
        env.pop(k,None)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
def run(args, **kw):
    return subprocess.run([str(a) for a in args],env=env,text=True,capture_output=True,**kw)
def must(args, **kw):
    r=run(args,**kw)
    if r.returncode: raise RuntimeError(f'{args}: {r.returncode}\n{r.stdout}\n{r.stderr}')
    return r.stdout
must(['bin/fm-lab-home.sh','create',lab])
socket=must(['bin/fm-lab-home.sh','tmux-dir',lab]).strip()
env.update(FM_HOME=str(lab),HOME=str(lab/'user-home'),TREEHOUSE_ROOT=str(lab/'pool'),TMUX_TMPDIR=socket,FM_TEST_SEAM='1',FM_ACTIVITY_READER=str(ROOT/'tests/fixtures/activity.sh'),FM_CAPACITY_MEMINFO=str(ROOT/'tests/captures/capacity-meminfo'),FM_RESOURCE_CGROUP_FILE='/dev/null',FM_CAPACITY_PRESSURE_FILE=str(ROOT/'tests/captures/capacity-pressure'))
(lab/'user-home').mkdir()
(lab/'.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\n')
(lab/'config/lane-capacity').write_text('999999 0\n')
(lab/'config/machine-admission.json').write_text(json.dumps(dict(schema='fm-machine-admission.v1',memory_floor_gib=0,memory_full_avg60_max=100,disk_floor_gib=0,disk_paths=[str(lab)])))
(lab/'state/.last-watcher-beat').touch()
(lab/'data/projects.md').write_text('- proj [local-only] - disposable\n- other [local-only] - disposable\n')
for name in ('proj','other'):
    p=lab/'projects'/name
    must(['git','init','-q','-b','main',p]); (p/'README.md').write_text('Disposable slice-admission task.\n')
    must(['git','-C',p,'add','README.md']); must(['git','-C',p,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','initial'])
cat=lab/'catalog.json'
rows=[dict(id='ops/demo',kind='operational',journey='operational',step='demo',entrance='operational',outcome='demo outcome',owner='lab:demo',checkpoint='lab',acceptance_source='rollout contract'),dict(id='ops/other',kind='operational',journey='operational',step='other',entrance='operational',outcome='other outcome',owner='lab:other',checkpoint='lab',acceptance_source='rollout contract')]
cat.write_text(json.dumps(dict(schema='slice-catalog.v1',revision='r1',slices=rows)))
validator='~/.config/skills-master/.agents/skills/vertical-slicing/scripts/slicing.py'
policy=lab/'config/slicing.json'
# Supported raw launch executes real bash in a real Treehouse worktree; no CLI or terminal stub.
raw='printf "LIVE_SLICE_WORKER_READY\\n"; exec bash --noprofile --norc'
results=[]
def scenario(name,mode='enforce',line='',prep=None,body=None,project='proj',expected=True,reason=None,validator_path=validator,scout=False,projects=None,revision='r1',malformed=False):
    if mode is None:
        policy.unlink(missing_ok=True)
    else:
        pol=dict(schema='slice-policy.v1',mode=mode,projects=['proj'] if projects is None else projects,catalog=str(cat),revision=revision,activated_at='2026-11-05T00:00:00Z',home='lab')
        if malformed: pol.pop('catalog')
        policy.write_text(json.dumps(pol))
    body=('Disposable task.\n'+line) if body is None else body
    added=must([ROOT/'bin/fm-tasks-axi.sh','add',name,'--mint','--kind','scout' if scout else 'ship','--repo',project,'--body',body,'--json'])
    (E/(name+'-task.json')).write_text(added)
    task=json.loads(added); task=task.get('task',task); tid=task['id']
    d=lab/'data'/tid; d.mkdir(exist_ok=True)
    (d/'brief.md').write_text('# Task\n## Captain\'s intent\nExercise disposable slice admission.\n\n## Firstmate spec\nRun the supplied shell command only.\n'+line+'\n')
    if prep is not None: (d/'prep.md').write_text('# Prep\n'+prep+'\n')
    out=E/(name+'.log'); status=lab/(name+'.status')
    cmd=[str(ROOT/'bin/fm-spawn.sh'),tid,str(lab/'projects'/project),raw]
    cmd+=['--scout'] if scout else ['--mode','local-only','--yolo','off']
    import shlex
    script=lab/(name+'.sh')
    script.write_text('#!/usr/bin/env bash\nexport FM_SLICE_VALIDATOR='+shlex.quote(validator_path)+'\n'+shlex.join(cmd)+' > '+shlex.quote(str(out))+' 2>&1\nprintf "%s\\n" "$?" > '+shlex.quote(str(status))+'\n')
    must(['tmux','-L','fm-lab','new-window','-d','-t','primary','-n','driver-'+name,'-c',ROOT,'bash',script])
    deadline=time.monotonic()+100
    while not status.exists() and time.monotonic()<deadline: time.sleep(.2)
    if not status.exists(): raise RuntimeError('spawn timed out: '+name+'\n'+out.read_text())
    rc=int(status.read_text()); output=out.read_text()
    meta=lab/'state'/(tid+'.meta')
    capture=''
    if meta.exists():
        capture=must(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-'+tid,'-S','-100'])
    state=must([ROOT/'bin/fm-tasks-axi.sh','show',tid,'--full'])
    with out.open('a') as f:
        f.write('\nOBSERVABLE STATE\n'+json.dumps(dict(exit_status=rc,task_record=meta.exists(),task_id=tid))+'\n'+state+'\nWORKER TERMINAL\n'+capture)
        if meta.exists(): f.write('\nPERSISTED TASK METADATA\n'+meta.read_text())
    ok=((rc==0)==expected and meta.exists()==expected and (not expected or 'LIVE_SLICE_WORKER_READY' in capture) and (reason is None or reason in output))
    results.append(dict(name=name,result='pass' if ok else 'fail',live=True,evidence=str(out),reason='' if ok else f'Expected launch={expected}, reason={reason}; got rc={rc}, record={meta.exists()}, worker-ready={"LIVE_SLICE_WORKER_READY" in capture}'))
    print(json.dumps(results[-1]),flush=True)
    (E/'followup-results.json').write_text(json.dumps(results,indent=2))
    return tid
try:
    must(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',ROOT,'bash','--noprofile','--norc'])
    line='SLICE: ops/demo | demo outcome'
    tid=scenario('recovery-setup-observe',mode='observe',reason='missing-slice')
    meta=lab/'state'/(tid+'.meta')
    before=dict(l.split('=',1) for l in meta.read_text().splitlines() if '=' in l)
    policy.write_text(json.dumps(dict(schema='slice-policy.v1',mode='enforce',projects=['proj'],catalog=str(cat),revision='r1',activated_at='2026-11-05T00:00:00Z')))
    status=lab/'recovery.status'; log=E/'recovery-relaunch.log'
    import shlex
    cmd=[str(ROOT/'bin/fm-spawn.sh'),tid,'--relaunch','--harness',raw]
    script=lab/'recover.sh'
    script.write_text('#!/usr/bin/env bash\nexport FM_SLICE_VALIDATOR='+shlex.quote(str(lab/'absent.py'))+'\n'+shlex.join(cmd)+' > '+shlex.quote(str(log))+' 2>&1\nprintf "%s\n" "$?" > '+shlex.quote(str(status))+'\n')
    must(['tmux','-L','fm-lab','new-window','-d','-t','primary','-n','recovery','-c',ROOT,'bash',script])
    deadline=time.monotonic()+100
    while not status.exists() and time.monotonic()<deadline: time.sleep(.2)
    if not status.exists(): raise RuntimeError('relaunch timed out: '+log.read_text())
    rc=int(status.read_text()); after=dict(l.split('=',1) for l in meta.read_text().splitlines() if '=' in l)
    capture=must(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-'+tid,'-S','-100'])
    ok=rc==0 and before['worktree']==after['worktree'] and before['spawn_gen']!=after['spawn_gen'] and 'LIVE_SLICE_WORKER_READY' in capture
    with log.open('a') as f: f.write('\nBEFORE METADATA\n'+json.dumps(before)+'\nAFTER METADATA\n'+json.dumps(after)+'\nWORKER TERMINAL\n'+capture)
    results.append(dict(name='recovery-relaunch',result='pass' if ok else 'fail',live=True,evidence=str(log),reason='' if ok else f'relaunch rc={rc}; before/after retained in log'))
    print(json.dumps(results[-1]),flush=True)
    crash=lab/'crashing-validator.py'; crash.write_text('raise SystemExit(2)\n')
    for mode in ('enforce','observe'):
        scenario('listed-no-result-'+mode,mode=mode,validator_path=str(crash),expected=mode=='observe',reason='could not check')
        scenario('unreadable-project-list-'+mode,mode=mode,projects='other',validator_path=str(lab/'absent.py'),expected=mode=='observe',reason='could not check')
    (E/'recovery-results.json').write_text(json.dumps(results,indent=2))

finally:
    stopped=run(['tmux','-L','fm-lab','kill-server'])
    teardown=run([ROOT/'bin/fm-lab-home.sh','teardown',lab])
    (E/'lab-cleanup.log').write_text(f'tmux kill-server exit={stopped.returncode}\nlab teardown exit={teardown.returncode}\n{teardown.stdout}{teardown.stderr}')
    if teardown.returncode==0:
        for folder, dirs, files in os.walk(lab):
            os.chmod(folder,os.stat(folder).st_mode | 0o700)
        shutil.rmtree(lab)
        with (E/'lab-cleanup.log').open('a') as f: f.write('lab home removed='+str(not lab.exists())+'\n')
    else: raise RuntimeError('lab socket cleanup failed')
if any(r['result']!='pass' for r in results): sys.exit(1)
