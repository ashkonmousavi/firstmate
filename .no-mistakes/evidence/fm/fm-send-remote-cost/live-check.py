import os, pathlib, subprocess, time, json, resource
root=pathlib.Path.cwd(); evidence=pathlib.Path('~/.no-mistakes/evidence/01M6GYJX9JSY0C9XHJ98G8ZWSF')
lab=root/'.validation/home'
subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'HERDR_')) or k=='TMUX': env.pop(k,None)
env.update(FM_HOME=str(lab),FM_GUARD_READ_ONLY='1',TMUX=subprocess.check_output(['tmux','-S','.validation/tmux.sock','display-message','-p','#{socket_path},#{pid},0'],text=True).strip())
state=lab/'state'; inbox=state/'history.inbox'; handled=inbox/'handled'; handled.mkdir(parents=True)
(state/'history.meta').write_text('window=lab:bash\nkind=ship\nharness=claude\nbackend=tmux\n')
for i in range(1,2049): (handled/f'{i:04}.msg').write_text('historical record\n')
(inbox/'009.msg').write_text('pending\n'); (inbox/'not-a-sequence.msg').write_text('junk\n')
lib=str(root/'bin/fm-task-inbox-lib.sh')
def call(fn,*args, library=lib):
    p=subprocess.run(['bash','-c','. "$1"; shift; "$@"','_',library,fn,*map(str,args)],env=env,text=True,capture_output=True)
    if p.returncode: raise RuntimeError(f'{fn}: {p.returncode}: {p.stderr}')
    return p.stdout
rows=[]
with (evidence/'live-local-cli.log').open('w') as log:
    log.write('Real fm-send CLI, real private tmux shell endpoint (120x40), disposable marked home. Enqueue proof only; no model acknowledgement or remote-server proof.\n')
    for i in range(1,11):
        body=f'cost validation {i}\nexact unicode: café; $literal `text`\n'
        start=time.monotonic(); p=subprocess.run(['bin/fm-send.sh','history','--one-way',body],env=env,text=True,capture_output=True,timeout=30); wall=time.monotonic()-start
        rec=inbox/f'{2048+i}.msg'
        log.write(f'SEND {i} exit={p.returncode} wall={wall:.3f}s record={rec.name}\n{p.stdout}{p.stderr}')
        assert p.returncode==0,(i,p.stderr)
        assert rec.exists(),rec
        assert call('fm_task_inbox_body',rec)==body,(rec,call('fm_task_inbox_body',rec))
        log.write(f'BODY {i} byte-exact: {body!r}\n')
        rec.rename(handled/rec.name)
        rows.append(dict(send=i,exit=p.returncode,wall_seconds=wall,sequence=2048+i,body_exact=True,acknowledgement='manual fixture move; no worker acknowledgement claimed'))
    # Independent ordering example: decimal order 9,10,100; lexical order is 009,0100,10.
    ordered=state/'ordered.inbox'; (ordered/'handled').mkdir(parents=True)
    for name in ['009.msg','10.msg','0100.msg','invalid.msg']:
        (ordered/name).write_text('schema=fm-task-inbox.v1\n--\ntracked\n')
    (ordered/'001.msg').write_text('schema=fm-task-inbox.v1\ndelivery=fire-and-forget\n--\nuntracked\n')
    for expected in ['009.msg','10.msg','0100.msg']:
        got=pathlib.Path(call('fm_task_inbox_oldest_unhandled',state,'ordered'))
        assert got.name==expected,(got,expected)
        log.write(f'OLDEST expected={expected} actual={got.name}; acknowledged by fixture move\n')
        got.rename(ordered/'handled'/got.name)
    p=subprocess.run(['bash','-c','. "$1"; fm_task_inbox_oldest_unhandled "$2" ordered','_',lib,str(state)],env=env,capture_output=True,text=True)
    assert p.returncode==1 and not p.stdout,(p.returncode,p.stdout)
    log.write('OLDEST: acknowledged history, junk, and fire-and-forget skipped; empty tracked inbox exits 1.\n')
    log.write('All local CLI sequence/body and public-reader ordering assertions passed.\n')
(evidence/'live-local-results.json').write_text(json.dumps(rows,indent=2)+'\n')
# Benchmark actual public writer on identical histories, unchanged base versus target.
basebin=root/'.validation/base-bin'; basebin.mkdir()
for file in (root/'bin').iterdir():
    if file.is_file(): (basebin/file.name).symlink_to(file)
(basebin/'fm-task-inbox-lib.sh').unlink()
(basebin/'fm-task-inbox-lib.sh').write_bytes(subprocess.check_output(['git','show','914dff6ffc374ba053bf00a329b462add27250fa:bin/fm-task-inbox-lib.sh']))
bench=[]
for variant,library in [('base',str(basebin/'fm-task-inbox-lib.sh')),('target',lib)]:
    for run in range(1,4):
        s=root/f'.validation/benchmark-{variant}-{run}'
        h=s/'task.inbox/handled'; h.mkdir(parents=True)
        for i in range(1,2049): (h/f'{i:04}.msg').write_text('historical\n')
        before=resource.getrusage(resource.RUSAGE_CHILDREN); start=time.monotonic()
        rec=pathlib.Path(call('fm_task_inbox_write',s,'task','benchmark exact body',library=library))
        wall=time.monotonic()-start; after=resource.getrusage(resource.RUSAGE_CHILDREN)
        assert rec.name=='2049.msg' and call('fm_task_inbox_body',rec)=='benchmark exact body'
        bench.append(dict(variant=variant,run=run,wall_seconds=wall,user_seconds=after.ru_utime-before.ru_utime,system_seconds=after.ru_stime-before.ru_stime,sequence=rec.name,body_exact=True))
(evidence/'allocator-benchmark.json').write_text(json.dumps(bench,indent=2)+'\n')
print(json.dumps({'local_sends':rows,'benchmark':bench},indent=2))
