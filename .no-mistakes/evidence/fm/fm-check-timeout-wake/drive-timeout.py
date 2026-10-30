import os, pathlib, subprocess, tempfile, shutil, time, json, re, signal
ROOT=pathlib.Path.cwd()
EVIDENCE=pathlib.Path('~/.no-mistakes/evidence/01M669NM1EEECFNSSZGN7B030E')
log=[]
results=[]
scratch=pathlib.Path(tempfile.mkdtemp(prefix='.fm-timeout-live-',dir=ROOT))
def note(s):
    print(s,flush=True);log.append(s)
def run(args,env,limit=15):
    t=time.monotonic()
    p=subprocess.run([str(a) for a in args],env=env,text=True,capture_output=True,timeout=limit)
    note(f'$ {" ".join(str(a) for a in args)}\nexit={p.returncode}, elapsed={time.monotonic()-t:.2f}s\n{p.stdout}{p.stderr}')
    return p
try:
    env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE')}
    env.update(PATH='/usr/bin:/bin',TMPDIR=str(scratch))
    note('Oracle: owner intent and accepted R1 decision require each timed-out custom run to wake with its original path and configured bound. Normal checks retain their output. Real bin/fm-watch.sh and registration/drain entrypoints are executed, with no harness or backend mocks.')
    for backend in ['timeout','perl','gtimeout']:
        lab=scratch/backend
        assert run([ROOT/'bin/fm-lab-home.sh','create',lab],env).returncode==0
        caseenv=env.copy()
        (lab/'user').mkdir();(lab/'tmux').mkdir()
        caseenv.update(FM_HOME=str(lab),HOME=str(lab/'user'),XDG_CONFIG_HOME=str(lab/'user/config'),TMUX=f'{lab}/tmux/private,1,0',TMUX_TMPDIR=str(lab/'tmux'),FM_POLL='0.05',FM_CHECK_INTERVAL='0',FM_HEARTBEAT='9999999999',FM_SIGNAL_GRACE='0',FM_CHECK_TIMEOUT='1')
        if backend=='perl':caseenv['FM_CHECK_FORCE_FALLBACK']='1'
        if backend=='gtimeout':
            toolbin=lab/'tools';toolbin.mkdir()
            for cmd in 'awk bash basename cat chmod cmp cp cut date dirname env expr flock getconf grep head hostname id kill ln ls mkdir mktemp mv od perl ps pwd readlink realpath rm rmdir sed sha256sum shasum sleep sort stat tail touch tr uname wc python3 git jq tee xargs true false'.split():
                target=shutil.which(cmd,path='/usr/bin:/bin')
                if target:(toolbin/cmd).symlink_to(target)
            (toolbin/'gtimeout').symlink_to(shutil.which('timeout',path='/usr/bin:/bin'))
            caseenv['PATH']=str(toolbin)
            note('gtimeout route uses the real GNU coreutils timeout binary under its alternate executable name; PATH contains no timeout executable.')
        state=lab/'state'
        slow=state/'slow.check.sh'
        slow.write_text('#!/usr/bin/env bash\nprintf "partial result before timeout\\n"\nprintf "%s\\n" "$$" >> "$FM_HOME/state/check-pids"\nexec sleep 60\n')
        slow.chmod(0o700)
        assert run([ROOT/'bin/fm-check-register.sh','slow'],caseenv).returncode==0
        expected=f'check: {slow}: timed out after 1s (FM_CHECK_TIMEOUT)'
        for cycle in (1,2):
            p=run([ROOT/'bin/fm-watch.sh'],caseenv)
            assert p.returncode==0,(backend,cycle,p.stderr)
            assert expected in p.stdout.splitlines(),(backend,cycle,p.stdout)
            assert 'partial result' not in p.stdout
            queue=(state/'.wake-queue').read_text()
            note(f'Persisted wake queue ({backend} cycle {cycle}):\n{queue}')
            assert expected in queue
            for pid in (state/'check-pids').read_text().splitlines():
                try:os.kill(int(pid),0)
                except ProcessLookupError:pass
                else:raise AssertionError(f'custom check still exists: {pid}')
            assert not list(state.glob('.fm-check-output.*'))
            assert not list(state.glob('.fm-custom-check.*'))
            d=run([ROOT/'bin/fm-wake-drain.sh'],caseenv)
            assert d.returncode==0
            assert expected in d.stdout
            ack=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',d.stderr)
            assert ack,(d.stdout,d.stderr)
            assert run([ROOT/'bin/fm-wake-drain.sh','--ack-through',ack[1],'--recovery-generation',ack[2]],caseenv).returncode==0
        results.append(dict(name=f'{backend}: consecutive timeouts wake with check path and bound, persist for supervisor drain, and clean child processes',result='pass',live=True,evidence='live-timeout-transcript.txt',reason=''))
        # Re-register a same-ID replacement and add normal checks. Each result
        # must be delivered according to behavior, independent of old identity.
        slow.write_text('#!/usr/bin/env bash\nexec sleep 60\n');slow.chmod(0o700)
        for ident,body in [('quiet','exit 0\n'),('report','printf "normal report\\n"\nexit 7\n')]:
            check=state/f'{ident}.check.sh';check.write_text('#!/usr/bin/env bash\n'+body);check.chmod(0o700)
            assert run([ROOT/'bin/fm-check-register.sh',ident],caseenv).returncode==0
        assert run([ROOT/'bin/fm-check-register.sh','slow'],caseenv).returncode==0
        p=run([ROOT/'bin/fm-watch.sh'],caseenv)
        assert p.returncode==0
        queue=(state/'.wake-queue').read_text()
        note(f'Persisted mixed-check wake queue ({backend}):\n{queue}')
        assert expected in queue
        assert f'check: {state}/report.check.sh: normal report' in queue
        assert 'quiet.check.sh' not in queue
        results.append(dict(name=f'{backend}: same-ID replacement still times out visibly while silent and reporting checks retain normal behavior',result='pass',live=True,evidence='live-timeout-transcript.txt',reason=''))
    note('All live scenarios completed; all disposable homes removed by final cleanup.')
except Exception as e:
    note(f'FAILED: {type(e).__name__}: {e}')
    raise
finally:
    shutil.rmtree(scratch)
    (EVIDENCE/'live-timeout-transcript.txt').write_text('\n'.join(log)+'\n')
    (EVIDENCE/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
