import os,pathlib,subprocess,tempfile,shutil,time,json
ROOT=pathlib.Path.cwd()
EV=pathlib.Path('~/.no-mistakes/evidence/01M669NM1EEECFNSSZGN7B030E')
BASE='b0d11e9ef81168b1e20a7ae8a2c75bf45a92b2f9'
scratch=pathlib.Path(tempfile.mkdtemp(prefix='.fm-timeout-bound-',dir=ROOT))
log=[];results=[]
def note(s): print(s,flush=True);log.append(s)
def run(args,env,limit=15):
    start=time.monotonic()
    p=subprocess.run([str(a) for a in args],env=env,capture_output=True,text=True,timeout=limit)
    note(f'$ {" ".join(str(a) for a in args)}\nexit={p.returncode} elapsed={time.monotonic()-start:.2f}s\n{p.stdout}{p.stderr}')
    return p
try:
    env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE')}
    env.update(PATH='/usr/bin:/bin',TMPDIR=str(scratch))
    old=scratch/'baseline';old.mkdir();shutil.copytree(ROOT/'bin',old/'bin')
    (old/'bin/fm-watch.sh').write_bytes(subprocess.check_output(['git','show',f'{BASE}:bin/fm-watch.sh']))
    def labenv(name):
        lab=scratch/name
        assert run([ROOT/'bin/fm-lab-home.sh','create',lab],env).returncode==0
        (lab/'user').mkdir();(lab/'tmux').mkdir()
        e=env.copy();e.update(FM_HOME=str(lab),HOME=str(lab/'user'),XDG_CONFIG_HOME=str(lab/'user/config'),TMUX=f'{lab}/tmux/private,1,0',TMUX_TMPDIR=str(lab/'tmux'),FM_POLL='0.05',FM_CHECK_INTERVAL='0',FM_HEARTBEAT='9999999999',FM_SIGNAL_GRACE='0')
        return lab,e
    def register(lab,e,ident,body):
        f=lab/'state'/f'{ident}.check.sh';f.write_text('#!/usr/bin/env bash\n'+body);f.chmod(0o700)
        assert run([ROOT/'bin/fm-check-register.sh',ident],e).returncode==0
        return f
    for backend in ('timeout','perl'):
        for version,code in [('base',old),('target',ROOT)]:
            lab,e=labenv(f'{version}-{backend}');e['FM_CHECK_TIMEOUT']='1'
            if backend=='perl':e['FM_CHECK_FORCE_FALLBACK']='1'
            slow=register(lab,e,'slow','exec sleep 60\n')
            register(lab,e,'z-witness','printf "sweep completed\\n"\n')
            p=run([code/'bin/fm-watch.sh'],e)
            assert p.returncode==0
            queue=(lab/'state/.wake-queue').read_text()
            note(f'{version} {backend} persisted queue:\n{queue}')
            expected=f'check: {slow}: timed out after 1s (FM_CHECK_TIMEOUT)'
            if version=='base':
                assert str(slow) not in queue and 'timed out' not in p.stdout
                note('BEFORE FIX: slow check was killed silently; only the subsequent witness check woke.')
            else:
                assert expected in p.stdout and expected in queue
                note('AFTER FIX: the slow check generated its named timeout wake; the subsequent check also completed.')
        results.append(dict(name=f'{backend}: reproduce silent timeout on base and named wake on target',result='pass',live=True,evidence='baseline-default-transcript.txt',reason=''))
    lab,e=labenv('default-thirty')
    slow=register(lab,e,'slow','printf "%s\\n" "$$" > "$FM_HOME/state/check-pid"\nexec sleep 60\n')
    assert 'FM_CHECK_TIMEOUT' not in e
    start=time.monotonic();p=run([ROOT/'bin/fm-watch.sh'],e,limit=45);elapsed=time.monotonic()-start
    assert p.returncode==0
    assert f'check: {slow}: timed out after 30s (FM_CHECK_TIMEOUT)' in p.stdout
    assert 29 <= elapsed < 40
    assert 'timed out after 30s (FM_CHECK_TIMEOUT)' in (lab/'state/.wake-queue').read_text()
    try:os.kill(int((lab/'state/check-pid').read_text()),0)
    except ProcessLookupError:pass
    else:raise AssertionError('default-timeout check survived')
    results.append(dict(name='An overlong check with FM_CHECK_TIMEOUT unset wakes at the default 30-second bound',result='pass',live=True,evidence='baseline-default-transcript.txt',reason=''))
    for backend in ('timeout','perl'):
        lab,e=labenv(f'stop-{backend}');e['FM_CHECK_TIMEOUT']='10'
        if backend=='perl':e['FM_CHECK_FORCE_FALLBACK']='1'
        register(lab,e,'slow','printf "%s\\n" "$$" > "$FM_HOME/state/check-pid"\nexec sleep 60\n')
        with (scratch/f'{backend}-out').open('w+') as out, (scratch/f'{backend}-err').open('w+') as err:
            p=subprocess.Popen([str(ROOT/'bin/fm-watch.sh')],env=e,stdout=out,stderr=err,text=True)
            try:
                deadline=time.monotonic()+5
                while not (lab/'state/check-pid').exists():
                    assert p.poll() is None and time.monotonic()<deadline
                    time.sleep(.02)
                p.terminate();rc=p.wait(timeout=5)
            finally:
                if p.poll() is None:p.kill();p.wait()
            out.seek(0);err.seek(0);stdout=out.read();stderr=err.read()
            note(f'External TERM during {backend} check: exit={rc}\n{stdout}{stderr}')
        assert rc != 0
        queue=lab/'state/.wake-queue'
        assert not queue.exists() or 'timed out' not in queue.read_text()
        assert not list((lab/'state').glob('.fm-check-output.*'))
        assert not list((lab/'state').glob('.fm-custom-check.*'))
        try:os.kill(int((lab/'state/check-pid').read_text()),0)
        except ProcessLookupError:pass
        else:raise AssertionError('stopped watcher left check running')
        results.append(dict(name=f'{backend}: stopping the watcher cancels its check without a false timeout wake or leftover files',result='pass',live=True,evidence='baseline-default-transcript.txt',reason=''))
    note('Baseline comparison, default-bound run and stop checks completed; disposable code copy and homes removed.')
finally:
    shutil.rmtree(scratch)
    (EV/'baseline-default-transcript.txt').write_text('\n'.join(log)+'\n')
    (EV/'baseline-default-results.json').write_text(json.dumps(results,indent=2)+'\n')
