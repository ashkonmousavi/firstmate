import json, os, pathlib, re, shutil, signal, subprocess, tempfile, time
ROOT=pathlib.Path.cwd()
EVIDENCE=pathlib.Path(__file__).parent
lab=pathlib.Path(tempfile.mkdtemp(prefix='.live-check-lab-',dir=ROOT))
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_')) and k not in ('TMUX','HERDR_SESSION')}
env.update(FM_HOME=str(lab),FM_POLL='0.05',FM_CHECK_INTERVAL='0',FM_HEARTBEAT='999999',FM_SIGNAL_GRACE='0')
records=[]
log=open(EVIDENCE/'check-wakes-transcript.txt','w')
def note(s):
    print(s,flush=True); print(s,file=log,flush=True)
def command(name,*args):
    p=subprocess.run([str(ROOT/'bin'/name),*args],env=env,text=True,capture_output=True,timeout=20)
    note('$ bin/'+name+' '+' '.join(args)+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]')
    assert p.returncode==0
    return p

def install(name,body):
    p=lab/'state'/(name+'.check.sh'); p.write_text('#!/usr/bin/env bash\n'+body+'\n'); p.chmod(0o700)
    command('fm-check-register.sh',name)

def sweep(label,expected,timeout=1,fallback=0):
    local=env|{'FM_CHECK_TIMEOUT':str(timeout),'FM_CHECK_FORCE_FALLBACK':str(fallback)}
    start=time.monotonic()
    p=subprocess.Popen([str(ROOT/'bin/fm-watch.sh')],env=local,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    try:
        out,err=p.communicate(timeout=20)
    except BaseException:
        os.killpg(p.pid,signal.SIGTERM)
        try: p.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid,signal.SIGKILL); p.communicate()
        raise
    elapsed=time.monotonic()-start
    state=lab/'state'
    queue=(state/'.wake-queue').read_text() if (state/'.wake-queue').exists() else ''
    payloads=[line.split('\t',4)[4] for line in queue.splitlines() if line.split('\t',4)[2]=='check']
    delivery=(state/'.watch-deliveries.log').read_text()
    note(f'\n{label}: FM_CHECK_TIMEOUT={timeout} FM_CHECK_FORCE_FALLBACK={fallback}\nstdout:\n{out}stderr:\n{err}exit={p.returncode}; wall={elapsed:.3f}s\nDURABLE QUEUE:\n{queue}DELIVERY LOG:\n{delivery}')
    assert p.returncode==0,(label,p.returncode,err)
    expected(payloads,out)
    assert not list(state.glob('.fm-custom-check-snapshot.*'))
    assert not list(state.glob('.fm-check-output.*'))
    records.append({'name':label,'pass':True,'wall_seconds':round(elapsed,3),'stdout':out,'queue':queue,'delivery_log':delivery})
    d=command('fm-wake-drain.sh')
    m=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',d.stderr)
    assert m, d.stderr
    command('fm-wake-drain.sh','--ack-through',m[1],'--recovery-generation',m[2])
    assert not (state/'.wake-queue').read_text().strip()

try:
    command('fm-lab-home.sh','create',str(lab))
    # Fresh published summary avoids unrelated detached publication work.
    (lab/'state/home-summary.json').write_text('{}\n')
    for fallback in (0,1):
        backend='GNU timeout' if fallback==0 else 'Perl fallback'
        install('slow','echo partial-output-before-timeout; sleep 20')
        expected=f'check: {lab}/state/slow.check.sh: timed out after 1s (FM_CHECK_TIMEOUT)'
        def timed(payloads,out):
            assert payloads==[expected],payloads
            assert out.strip()==expected,out
        sweep(backend+' first timeout',timed,fallback=fallback)
        sweep(backend+' consecutive timeout',timed,fallback=fallback)
        command('fm-check-unregister.sh','slow')
        # Reusing the same id must not inherit timeout suppression.
        install('slow','sleep 20')
        sweep(backend+' re-registered timeout',timed,fallback=fallback)
        command('fm-check-unregister.sh','slow')
        for name,body,code in [('exit-one','sleep 2; exit 1',1),('output-failure',"printf 'diagnostic detail\\n'; exit 7",7),('term',"exec perl -e 'kill 15, $$'",143),('kill',"exec perl -e 'kill 9, $$'",137)]:
            install(name,body)
            def failure(payloads,out,name=name,code=code):
                assert len(payloads)==1,payloads
                m=re.fullmatch(re.escape(f'check: {lab}/state/{name}.check.sh: exited {code} after ')+r'(\d+)s'+(': diagnostic detail' if name=='output-failure' else ''),payloads[0])
                assert m,payloads
                if name=='exit-one': assert int(m[1])>=2,payloads
                assert out.strip()==payloads[0],out
            sweep(backend+' '+name,failure,timeout=10,fallback=fallback)
            command('fm-check-unregister.sh',name)
        install('quiet',f"printf 'executed\\n' >> '{lab}/state/quiet-runs'; exit 0")
        install('z-success',"printf 'first line\\nsecond line\\n'")
        def success(payloads,out):
            assert (lab/'state/quiet-runs').read_text()=='executed\n'
            assert payloads==[f'check: {lab}/state/z-success.check.sh: first line second line'],payloads
            assert out==f'check: {lab}/state/z-success.check.sh: first line\nsecond line\n',out
        sweep(backend+' quiet-success and printed-success',success,timeout=10,fallback=fallback)
        command('fm-check-unregister.sh','quiet'); command('fm-check-unregister.sh','z-success')
        (lab/'state/quiet-runs').unlink()
    note('All live checks passed.')
finally:
    (EVIDENCE/'check-wakes-results.json').write_text(json.dumps(records,indent=2)+'\n')
    shutil.rmtree(lab)
    note('Disposable lab removed.')
    log.close()
