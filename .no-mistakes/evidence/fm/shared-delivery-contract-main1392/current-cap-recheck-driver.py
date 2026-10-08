import json
import os
from pathlib import Path
import shutil
import subprocess
import time

root = Path.cwd()
lab = root / '.v'
evidence = Path('/home/tegris/.no-mistakes/evidence/01M4E7BAHBXQ3NWFFXVXNYRF29')
log = (evidence / 'current-cap-recheck-transcript.txt').open('w')
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key.startswith('TASKS_AXI_') or key in ('TMUX', 'TMUX_TMPDIR'):
        env.pop(key)
env.update(FM_HOME=str(lab), TMUX_TMPDIR=str(lab / 'tmux'),
           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           FM_CREW_STATE_NO_FORGE='1', FM_POLL='1', FM_SIGNAL_GRACE='1',
           FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999',
           FM_IDLE_LANE_CHECK_INTERVAL='0', FM_WATCH_HANDLING_SUCCESSOR='1')
results = []
active = None

def run(args, expected=0):
    proc = subprocess.run([str(a) for a in args], cwd=root, env=env, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    log.write('$ ' + ' '.join(str(a) for a in args) + '\n' + proc.stdout + proc.stderr + f'exit={proc.returncode}\n')
    log.flush()
    if expected is not None:
        assert proc.returncode == expected, (args, proc.returncode, proc.stdout, proc.stderr)
    return proc

def write(path, text):
    path.write_text(text)

def scenario(name, action):
    try:
        action()
        results.append(dict(name=name, result='pass', live=True))
        log.write('OBSERVED PASS: ' + name + '\n')
    except Exception as exc:
        results.append(dict(name=name, result='fail', live=True, error=str(exc)))
        log.write('OBSERVED FAILURE: ' + name + ': ' + str(exc) + '\n')
    log.flush()

def watch(expected=None, quiet=False):
    global active
    out_path, err_path = lab / 'watch.out', lab / 'watch.err'
    with out_path.open('w') as out, err_path.open('w') as err:
        active = subprocess.Popen([str(root / 'bin/fm-watch.sh')], cwd=root, env=env,
                                  stdout=out, stderr=err, start_new_session=True)
        if quiet:
            time.sleep(3)
            stayed = active.poll() is None
            active.terminate()
            active.wait(timeout=8)
        else:
            stayed = False
            try:
                active.wait(timeout=15)
            except subprocess.TimeoutExpired:
                active.terminate()
                active.wait(timeout=8)
                raise AssertionError('watcher did not produce expected wake: ' + str(expected))
        code = active.returncode
        active = None
    output, error = out_path.read_text(), err_path.read_text()
    log.write('$ FM_HOME=<disposable home> bin/fm-watch.sh\n' + output + error + f'exit={code}\n')
    queue = lab / 'state/.wake-queue'
    if queue.exists():
        log.write('Persisted wake queue:\n' + queue.read_text())
    log.flush()
    if quiet:
        assert stayed and not output, (stayed, output, error)
    else:
        assert code == 0 and expected in output, (code, expected, output, error)
    return output

try:
    assert not lab.exists(), 'refusing to adopt an existing lab'
    run(['bin/fm-lab-home.sh', 'create', lab])
    (lab / 'tmux').mkdir()
    write(lab / 'config/backend', 'tmux\n')
    run(['tmux', '-L', 'fm-lab', 'new-session', '-d', '-s', 'observer', '-x', '120', '-y', '40', '-c', root, 'bash'])
    socket = run(['tmux', '-L', 'fm-lab', 'display-message', '-p', '-t', 'observer', '#{socket_path}']).stdout.strip()
    env['TMUX'] = socket + ',0,0'
    write(lab / 'config/writing-lane-cap', '3\n')
    write(lab / 'config/release-capacity', '1\n')
    write(lab / 'data/backlog.md', '# Backlog\n\n## Queued\n- [ ] repair-one - Dispatchable repair (kind: ship)\n- [ ] independent-one - Independent admitted item (kind: ship)\n')
    run(['bin/fm-tasks-axi.sh', 'ready'])
    for i in range(3):
        write(lab / ('state/full' + str(i) + '.meta'), 'kind=ship\npr=https://github.com/example/repo/pull/7\n')
    scenario('A full writing-lane maximum emits no request for additional starts', lambda: watch(quiet=True))
finally:
    if active is not None and active.poll() is None:
        active.terminate()
        active.wait(timeout=8)
    if lab.exists():
        run(['tmux', '-L', 'fm-lab', 'kill-server'], expected=None)
        shutil.rmtree(lab)
        log.write('Disposable lab and private tmux socket removed.\n')
    (evidence / 'current-cap-recheck-results.json').write_text(json.dumps(results, indent=2) + '\n')
    log.close()
print(json.dumps(results, indent=2))
raise SystemExit(1 if any(r['result'] == 'fail' for r in results) else 0)
