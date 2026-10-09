from pathlib import Path
import subprocess, os, time, shutil
root=Path.cwd(); work=root/'.gate-test-tmp'; evidence=Path('/home/tegris/.no-mistakes/evidence/01M4F6V4RF8ZZE0Z7MGK9HV9XP')
def state(pid):
    q=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
    return q.stdout.strip()
def live(pid):
    s=state(pid)
    return bool(s) and 'Z' not in s
mode=os.environ['GATE_EXERCISE']
if mode=='baseline':
    temp=work/'baseline-runtime'; temp.mkdir(exist_ok=True)
    with (evidence/'base-red.log').open('w') as log:
        for outcome in ['success','failure']:
            receipt=work/('base-'+outcome+'.receipt')
            env=os.environ.copy(); env.update(TMPDIR=str(temp),CHILD_LIB=str(work/'base/tests/lib.sh'),CHILD_RECEIPT=str(receipt),CHILD_OUTCOME=outcome,CHILD_CLEANUP='production',CHILD_HOLDER=str(work/'baseline-holder.sh'))
            q=subprocess.run(['bash','bin/fm-test-run.sh','--jobs','1','.gate-test-tmp/baseline-producer.test.sh'],env=env,capture_output=True,text=True)
            log.write(q.stdout+q.stderr)
            pid,fixture=receipt.read_text().splitlines()[:2]; pid=int(pid)
            try:
                childstate=state(pid)
                birth=Path('/proc')/str(pid)/'stat'
                birth=birth.read_text().rsplit(')',1)[1].split()[19]
                cwd=os.readlink('/proc/'+str(pid)+'/cwd')
                print(f'BASE_RED outcome={outcome} runner_exit={q.returncode} child_pid={pid} child_state={childstate} birth=proc:{birth} cwd={cwd} root_removed={not Path(fixture).exists()} released_at_observation={Path(str(receipt)+".release").exists()} expired={Path(str(receipt)+".release.expired").exists()}',file=log,flush=True)
                assert q.returncode==(0 if outcome=='success' else 1)
                assert live(pid) and not Path(fixture).exists()
                assert not Path(str(receipt)+'.release').exists()
                assert not Path(str(receipt)+'.release.expired').exists()
            finally:
                Path(str(receipt)+'.release').touch()
                for _ in range(600):
                    if not live(pid): break
                    time.sleep(.1)
                assert not live(pid), 'baseline holder failed cooperative release'
            print(f'BASE_RELEASE outcome={outcome} child_terminal=true',file=log,flush=True)
    print('Baseline public success/failure reproduced the live child after fixture removal.')
elif mode=='callers':
    names=(evidence/'caller-selectors.txt').read_text().splitlines()
    temp=work/'callers-runtime'; temp.mkdir(exist_ok=True)
    with (evidence/'callers-early-failure.log').open('w') as log:
        for name in names:
            other=subprocess.Popen(['sleep','300'],cwd=temp)
            try:
                env=os.environ.copy(); env.update(TMPDIR=str(temp),FM_HOME=str(work/'neutral-home'),GATE_CALLER=name,GATE_OTHER_PID=str(other.pid))
                q=subprocess.run(['bash','bin/fm-test-run.sh','--jobs','1','.gate-test-tmp/callers.test.sh'],env=env,capture_output=True,text=True)
                log.write(q.stdout+q.stderr); log.flush()
                assert q.returncode==1, (name,q.stdout,q.stderr)
                assert 'injected early assertion after child registration' in q.stdout+q.stderr
                assert 'before_removal caller='+name+' child_terminal=true unrelated_alive=true' in q.stdout
                assert 'FAIL:' not in q.stdout+q.stderr
                assert other.poll() is None
                print(f'CALLER_EXIT caller={name} public_runner_exit=1 unrelated_pid={other.pid} unrelated_state={state(other.pid)}',file=log,flush=True)
            finally:
                if other.poll() is None: other.terminate()
                other.wait(timeout=10)
    print('All ten actual caller setups cleaned their registered child before root removal after an injected early assertion; unrelated children survived.')

elif mode=='drift':
    temp=work/'drift-runtime'; temp.mkdir(exist_ok=True)
    receipt=work/'drift.receipt'
    env=os.environ.copy(); env.update(TMPDIR=str(temp),GATE_LIB=str(root/'tests/lib.sh'),GATE_RECEIPT=str(receipt),GATE_EXTERNAL=str(temp))
    with (evidence/'live-cwd-drift.log').open('w') as log:
        q=subprocess.run(['bash','bin/fm-test-run.sh','--jobs','1','.gate-test-tmp/drift.test.sh'],env=env,capture_output=True,text=True)
        log.write(q.stdout+q.stderr)
        pid=int(Path(str(receipt)+'.pid').read_text()); fixture=Path(Path(str(receipt)+'.root').read_text().strip())
        try:
            cwd=os.readlink('/proc/'+str(pid)+'/cwd')
            print('original_provenance='+Path(str(receipt)+'.provenance').read_text().strip(),file=log)
            print(f'CWD_DRIFT runner_exit={q.returncode} child_pid={pid} child_state={state(pid)} current_cwd={cwd} root_preserved={fixture.exists()} expired={Path(str(receipt)+".expired").exists()}',file=log,flush=True)
            assert q.returncode==1 and 'REFUSED' in q.stdout+q.stderr
            assert live(pid) and fixture.is_dir() and cwd==str(temp)
            assert not Path(str(receipt)+'.expired').exists()
        finally:
            Path(str(receipt)+'.release').touch()
            for _ in range(600):
                if not live(pid): break
                time.sleep(.1)
            assert not live(pid), 'drift holder failed cooperative release'
            print('CWD_DRIFT_RELEASE child_terminal=true',file=log,flush=True)
    print('Actual cwd drift refused cleanup, preserved root, and left the live child untouched until outer release.')
