import json, os, pathlib, shutil, subprocess, sys, tempfile, time
repo = pathlib.Path.cwd()
base = pathlib.Path(tempfile.mkdtemp(prefix='cli-', dir=repo/'.validation-tmp'))
home = base/'home'; home.mkdir()
env = {k: os.environ[k] for k in ('PATH','USER','LOGNAME') if k in os.environ}
env.update(HOME=str(home), TMPDIR=str(base))
helper = [sys.executable, str(repo/'bin/fm-codex-accounts.py')]
config = base/'codex-accounts'

def run(args, code=0):
    result = subprocess.run(helper+args, env=env, text=True, capture_output=True, timeout=50)
    print('$ fm-codex-accounts.py '+' '.join(args), flush=True)
    print('exit='+str(result.returncode), flush=True)
    if result.stdout: print(result.stdout.rstrip(), flush=True)
    if result.stderr: print(result.stderr.rstrip(), flush=True)
    assert result.returncode == code, result
    assert 'sk-fm-live-' not in result.stdout+result.stderr
    return result

def configured(command, *args, code=0):
    return run([command,'--config',str(config),*args], code)

try:
    shared=base/'shared'; (shared/'rules').mkdir(parents=True)
    (shared/'config.toml').write_text('cli_auth_credentials_store="file"\nmodel="gpt-6.1-sol"\n')
    (shared/'AGENTS.md').write_text('Disposable account validation.\n')
    (shared/'rules/default.rules').write_text('prefix_rule(pattern=["echo"],decision="allow")\n')
    roots=[base/'codex-alpha',base/'codex-beta']
    for i, root in enumerate(roots):
        root.mkdir()
        (root/'auth.json').write_text(json.dumps({'OPENAI_API_KEY':'sk-fm-live-synthetic-'+str(i)}))
        stamp=time.time()-i
        os.utime(root/'auth.json',(stamp,stamp))
        run(['prepare','--folder',str(root),'--shared',str(shared)])
        assert (root/'config.toml').is_symlink()
        assert not (root/'auth.json').is_symlink() and (root/'auth.json').stat().st_nlink==1
    print('Observed: configuration is shared; each synthetic auth file remains independent.',flush=True)
    config.write_text(''.join(str(r)+'\n' for r in roots))
    configured('prepare' if False else 'guard')
    selected=configured('select')
    assert selected.stdout.strip().split('\t') == [str(roots[0]),str(roots[0]),'gpt-6.1-sol']
    snapshot=configured('quota')
    data=json.loads(snapshot.stdout)
    assert len(data['providers'])==2
    assert len({r['accountKey'] for r in data['providers']})==2
    assert all(r['state']['status']=='unavailable' and r['signedIn'] for r in data['providers'])
    print('Observed: real quota-axi yields two unavailable folder rows; eligible unmeasured selection is lexical.',flush=True)
    state=base/'state';state.mkdir()
    configured('register','--state',str(state))
    checks=sorted(state.glob('*.check.sh'))
    assert len(checks)==len(list(state.glob('*.check-trust')))==2
    for path in checks:
        result=subprocess.run(['bash',str(path)],env=env,text=True,capture_output=True,timeout=30)
        print('$ bash '+str(path)+' => exit='+str(result.returncode)+' output='+repr(result.stdout+result.stderr),flush=True)
        assert result.returncode==0 and result.stdout==result.stderr==''
    stamp=time.time()-7*86400
    os.utime(roots[0]/'auth.json',(stamp,stamp))
    configured('check','--folder',str(roots[0]),code=1)
    os.utime(roots[0]/'auth.json',None)
    (roots[0]/'auth.json').unlink()
    configured('check','--folder',str(roots[0]),code=1)
    shutil.copy2(roots[1]/'auth.json',roots[0]/'auth.json')
    configured('guard',code=1)
    (roots[0]/'auth.json').unlink();(roots[0]/'auth.json').symlink_to(roots[1]/'auth.json')
    configured('guard',code=1)
    (roots[0]/'auth.json').unlink();os.link(roots[1]/'auth.json',roots[0]/'auth.json')
    configured('guard',code=1)
    (roots[0]/'auth.json').unlink()
    for body in ('',str(roots[0])+'\n'+str(roots[0]/'../codex-alpha')+'\n','relative\n',str(roots[0])+'\r\n'):
        config.write_text(body);configured('select',code=1)
    config.unlink();os.mkfifo(config);configured('select',code=1)
    print('Observed: copied metadata, credential links, empty/aliased/relative/control-character/FIFO lists all refuse.',flush=True)
finally:
    shutil.rmtree(base)
    print('Disposable CLI folders removed.',flush=True)
