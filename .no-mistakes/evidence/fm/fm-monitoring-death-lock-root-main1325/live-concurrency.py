import os, pathlib, signal, subprocess, time
root=pathlib.Path.cwd(); lab=root/'.nm-live-lab'; state=lab/'state'
env=os.environ.copy()
for k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_TEST_HARNESS','TASKS_AXI_FILE','TASKS_AXI_BACKEND'): env.pop(k,None)
env['FM_HOME']=str(lab); env['TMUX_TMPDIR']=(state/'.fm-lab-tmux-dir').read_text().strip(); env['FM_SUPERVISION_ACTOR']='main'
env['TMUX']=subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path},#{pid},#{session_id}'],env=env,text=True).strip()
primary=(state/'.lock').read_text().strip(); env['FM_LEASE_HOLDER_PID']=primary; env['FM_TASK_INBOX_LOCK_WAIT_SECS']='20'
children=[]
def spawn(args, name, extra=None):
    e=env.copy(); e.update(extra or {})
    out=open(lab/(name+'.out'),'w'); err=open(lab/(name+'.err'),'w')
    p=subprocess.Popen(args,env=e,stdout=out,stderr=err,start_new_session=True); children.append(p); return p

def wait_until(pred,seconds=8):
    end=time.monotonic()+seconds
    while not pred():
        assert time.monotonic()<end,'condition timed out'; time.sleep(.05)

def run(args,expected=0,extra=None):
    e=env.copy(); e.update(extra or {}); start=time.monotonic()
    p=subprocess.run(args,env=e,capture_output=True,text=True,timeout=5)
    print('$ '+' '.join(args)); print('exit=%s elapsed=%.3fs'%(p.returncode,time.monotonic()-start)); print(p.stdout+p.stderr,end='',flush=True)
    assert p.returncode==expected,(args,p.stdout,p.stderr); return p

def hold_meta(task):
    ready=lab/('meta-'+task+'-ready')
    ready.unlink(missing_ok=True)
    p=spawn(['bash','-c','STATE="$FM_HOME/state"; . bin/fm-wake-lib.sh; fm_lock_acquire_wait "$STATE/.meta-$1.lock"; trap \'fm_lock_release "$STATE/.meta-$1.lock"\' EXIT; echo "$$" > "$FM_HOME/meta-$1-ready"; sleep 60','_',task], 'meta-'+task)
    wait_until(ready.exists); return p

def stop(p):
    if p.poll() is None: os.killpg(p.pid,signal.SIGTERM)
    p.wait(timeout=5)

def unrelated(task):
    branch={'FM_SUPERVISION_ACTOR':'branch'}
    run(['bash','bin/fm-lease.sh','claim',task,'--actor','branch'],extra=branch)
    run(['bash','bin/fm-lease.sh','check',task])
    run(['bash','bin/fm-lease.sh','release-actor','--actor','branch'],extra=branch)
    assert not (state/('.lease-'+task)).exists()
try:
    run(['bash','bin/fm-lease.sh','release-actor','--actor','branch'],extra={'FM_SUPERVISION_ACTOR':'branch'})
    task='send-slow'
    (state/(task+'.meta')).write_text('window=primary:1\nharness=claude\nkind=scout\nworktree='+str(lab)+'\nproject=lab\n')
    holder=hold_meta(task)
    message='Disposable concurrency validation: no action required.'
    sender=spawn(['bash','bin/fm-send.sh',task,message],task)
    wait_until(lambda:(state/('.fm-lease-task-'+task+'.lock/pid')).exists() and (state/('.fm-lease-task-'+task+'.lock/pid')).read_text().strip()==str(sender.pid))
    wait_until(lambda:not (state/'.fm-lease-command.lock').exists())
    assert sender.poll() is None
    assert not (state/'.fm-lease-command.lock').exists()
    print('Real fm-send waiting on the task metadata lock; task guard held; lease-command lock free.',flush=True)
    unrelated('send-other')
    claim=spawn(['bash','bin/fm-lease.sh','claim',task,'--actor','branch'],'send-claim',{'FM_SUPERVISION_ACTOR':'branch'})
    time.sleep(.3); assert claim.poll() is None; assert not (state/('.lease-'+task)).exists()
    print('Competing branch claim remains blocked and publishes no lease while fm-send is pending.',flush=True)
    stop(holder)
    assert sender.wait(timeout=10)==0,(lab/(task+'.err')).read_text()
    assert claim.wait(timeout=10)==0
    records=list((state/(task+'.inbox')).glob('*.msg')); assert len(records)==1
    assert message in records[0].read_text()
    print('fm-send completed with one durable inbox record; competing claim proceeded only afterward:')
    print(records[0].read_text(),flush=True)
    run(['bash','bin/fm-send.sh',task,'must be refused under branch lease'],6)
    assert len(list((state/(task+'.inbox')).glob('*.msg')))==1
    run(['bash','bin/fm-lease.sh','release-actor','--actor','branch'],extra={'FM_SUPERVISION_ACTOR':'branch'})
    task='control-slow'; project=lab/'control-project'; wt=lab/'control-worktree'
    run(['git','init','-q','-b','main',str(project)])
    run(['git','-C',str(project),'-c','user.name=Lab fixture','-c','user.email=fixture@example.invalid','commit','-q','--allow-empty','-m','fixture'])
    run(['git','-C',str(project),'worktree','add','-q','-b','fm-lab-control',str(wt)])
    brief=lab/'data'/task/'brief.md'; brief.parent.mkdir(); brief.write_text('# Disposable concurrency probe\nDo not change files.\n')
    run(['tmux','-L','fm-lab','rename-window','-t','primary:fm-slow','fm-'+task])
    (state/(task+'.meta')).write_text('window=primary:fm-'+task+'\nharness=codex\nkind=scout\nmode=local-only\nyolo=false\nworktree='+str(wt)+'\nproject='+str(project)+'\n')
    run(['tmux','-L','fm-lab','send-keys','-t','primary:fm-'+task,'-l','cd -- '+str(wt)])
    run(['tmux','-L','fm-lab','send-keys','-t','primary:fm-'+task,'Enter'])
    holder=hold_meta(task)
    control=spawn(['bash','bin/fm-control.sh',task,'relaunch','--note','Disposable concurrency test; leave all files alone.'],task)
    journal=state/('.control-'+task+'.journal')
    # The real spawn owner publishes .spawn-<task>.lock before waiting on metadata.
    wait_until(lambda:(state/('.spawn-'+task+'.lock/pid')).exists(),15)
    assert control.poll() is None,(lab/(task+'.err')).read_text()
    assert (state/('.fm-lease-task-'+task+'.lock/pid')).exists()
    assert not (state/'.fm-lease-command.lock').exists()
    print('Real fm-control reached fm-spawn relaunch and is waiting on the held metadata lock; global lease-command lock is free.',flush=True)
    unrelated('control-other')
    claim=spawn(['bash','bin/fm-lease.sh','claim',task,'--actor','branch'],'control-claim',{'FM_SUPERVISION_ACTOR':'branch'})
    time.sleep(.3); assert claim.poll() is None; assert not (state/('.lease-'+task)).exists()
    print('Competing branch claim remains blocked throughout the real relaunch wait.',flush=True)
    stop(control); stop(holder)
    assert claim.wait(timeout=10)==0
    print('After cancellation, the task guard clears and the competing claim proceeds. Control journal/output retained below.',flush=True)
    print((lab/(task+'.out')).read_text()+(lab/(task+'.err')).read_text(),flush=True)
    for p in state.glob('*control-slow*'):
        if p.is_file() and not p.is_symlink():
            print(str(p.relative_to(lab))+':\n'+p.read_text(),flush=True)
    run(['bash','bin/fm-lease.sh','release-actor','--actor','branch'],extra={'FM_SUPERVISION_ACTOR':'branch'})
finally:
    for p in children:
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGTERM)
            try:p.wait(timeout=3)
            except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL); p.wait()
