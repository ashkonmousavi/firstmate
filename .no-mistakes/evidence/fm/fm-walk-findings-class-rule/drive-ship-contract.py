import json, os, pathlib, re, shutil, subprocess, tempfile
root = pathlib.Path.cwd()
evidence = pathlib.Path('/home/tegris/.no-mistakes/evidence/01M4A1DG2FKS344GNXF5BG88DG')
scratch = pathlib.Path(tempfile.mkdtemp(prefix='.fm-contract-test-', dir=root))
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key.startswith('TASKS_AXI_'):
        env.pop(key)
env['TMPDIR'] = str(scratch)
records = []
line = 'class fix: test fails without the fix; symptom seen twice.'
def run(args, **kwargs):
    return subprocess.run(args, cwd=root, env=env, text=True, capture_output=True, **kwargs)
try:
    home = scratch / "home with spaces and quote's"
    env['FM_HOME'] = str(home)
    for mode, forge in [('no-mistakes','none'),('no-mistakes','gerrit'),('direct-PR','none'),('direct-PR','gerrit'),('local-only','none')]:
        task = 'contract-' + mode.lower() + '-' + forge
        args = ['bash', 'bin/fm-brief.sh', task, 'firstmate', '--mode', mode, '--forge', forge]
        scaffold = run(args)
        assert scaffold.returncode == 0, scaffold.stderr
        brief_path = home / 'data' / task / 'brief.md'
        brief = brief_path.read_text()
        command = re.search(r'^```bash\n(.*?)\n```$', brief, re.M | re.S).group(1)
        emitted = run(['bash', '-c', command])
        assert emitted.returncode == 0, emitted.stderr
        assert emitted.stdout.splitlines().count(line) == 1, (mode, forge, emitted.stdout)
        assert 'Delivery contract: mode=' + mode in emitted.stdout
        assert 'Ship branch: fm/' + task in emitted.stdout
        assert (('forge=gerrit' in emitted.stdout) == (forge == 'gerrit'))
        name = task + '-emitted.md'
        (evidence / name).write_text(emitted.stdout)
        (evidence / (task + '-brief.md')).write_text(brief)
        records.append({'scenario':mode+'/'+forge,'command':args,'scaffold_output':scaffold.stdout.strip(),'pointer':command,'result':'pass','emitted_contract':name})
    for task, args in [('bad-forge-mode',['--mode','local-only','--forge','gerrit']),('bad-mode',['--mode','invalid']),('bad-forge',['--mode','no-mistakes','--forge','unknown'])]:
        command = ['bash','bin/fm-brief.sh',task,'firstmate'] + args
        refused = run(command)
        assert refused.returncode != 0, task
        assert not (home/'data'/task/'brief.md').exists(), task
        records.append({'scenario':task,'command':command,'exit':refused.returncode,'diagnostic':refused.stderr.strip(),'result':'pass: refused without writing brief'})
    # Execute the real baseline renderer to establish that the emitted-interface
    # regression rejects the old output, without editing candidate source.
    base = scratch/'baseline'
    base.mkdir()
    archive = subprocess.Popen(['git','archive','4f0120b3777c3ebd2a685cd1155da2e1e33c49b3','bin'], cwd=root, stdout=subprocess.PIPE)
    unpack = subprocess.run(['tar','-x','-C',str(base)],stdin=archive.stdout,capture_output=True)
    archive.stdout.close()
    assert archive.wait() == 0 and unpack.returncode == 0
    baseline = run(['bash','-c','. "$1"; fm_dod_block no-mistakes baseline fm/baseline none','_',str(base/'bin/fm-dod-lib.sh')])
    assert baseline.returncode == 0, baseline.stderr
    assert baseline.stdout.splitlines().count(line) == 0
    (evidence/'baseline-emitted-dod.md').write_text(baseline.stdout)
    records.append({'scenario':'baseline emitted contract','result':'RED: old renderer lacks the required class-fix line; candidate emits it once','baseline_exit':baseline.returncode})
finally:
    shutil.rmtree(scratch)
    records.append({'cleanup':str(scratch),'exists':scratch.exists()})
    (evidence/'ship-contract-transcript.json').write_text(json.dumps(records,indent=2)+'\n')
print(json.dumps(records,indent=2))
