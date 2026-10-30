import os,pathlib,signal,subprocess,time,json
root=pathlib.Path.cwd();state=root/'.lv/dedup/state';inbox=state/'task.inbox';handled=inbox/'handled';handled.mkdir(parents=True)
# Real retained inbox records force a long genuine filesystem scan; no command or product replacement.
body='Please report the build.'
for i in range(12000):
    (handled/f'{i+1:05}.msg').write_text('schema=fm-task-inbox.v1\nat=2026-10-29T00:00:00Z\n--\n'+body)
env={k:v for k,v in os.environ.items() if not k.startswith('FM_')};env['FM_HOME']=str(root/'.lv/l')
cmd=['bash','-c','. bin/fm-task-inbox-lib.sh; fm_task_inbox_write_idempotent "$1" task "$2"','_',str(state),body]
p=subprocess.Popen(cmd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
try:
    deadline=time.monotonic()+10
    while time.monotonic()<deadline:
        scratch=list(inbox.glob('.dedup.*'))
        if len(scratch)==2 and all(x.exists() for x in scratch):
            os.killpg(p.pid,signal.SIGSTOP);break
        if p.poll() is not None: raise RuntimeError('enqueue completed before interruption window')
        time.sleep(.001)
    else: raise RuntimeError('never observed both scratch files')
    print('before SIGTERM:',json.dumps([x.name for x in inbox.glob('.dedup.*')]),flush=True)
    os.killpg(p.pid,signal.SIGTERM);os.killpg(p.pid,signal.SIGCONT)
    out,err=p.communicate(timeout=15)
    for _ in range(100):
        leftovers=list(inbox.glob('.dedup.*'))
        if not leftovers: break
        time.sleep(.05)
    print('enqueue exit=',p.returncode,'stdout=',out.decode(),'stderr=',err.decode(),flush=True)
    print('after SIGTERM:',json.dumps([x.name for x in leftovers]),'unread_records=',len(list(inbox.glob('*.msg'))),flush=True)
    assert p.returncode in (-signal.SIGTERM,143)
    assert not leftovers
    assert not list(inbox.glob('*.msg'))
    # Normal rerun must still deduplicate against the unchanged handled message.
    result=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=30)
    print('normal rerun exit=',result.returncode,'existing record=',result.stdout.strip(),flush=True)
    assert result.returncode==0 and pathlib.Path(result.stdout.strip()).parent==handled
    assert not list(inbox.glob('.dedup.*'))
    print('PASS: interrupted real dedup scan removes both scratch files, preserves handled data and remains retryable.')
finally:
    if p.poll() is None:
        os.killpg(p.pid,signal.SIGCONT);os.killpg(p.pid,signal.SIGTERM);p.wait(timeout=15)
