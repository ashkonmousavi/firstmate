import json
import os
from pathlib import Path
import shutil
import subprocess
import time

root = Path.cwd()
lab = root / '.v'
evidence = Path('/home/tegris/.no-mistakes/evidence/01M4E7BAHBXQ3NWFFXVXNYRF29')
log = (evidence / 'current-live-local-transcript.txt').open('w')
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
    assert not lab.exists(), 'refusing to adopt existing lab'
    run(['bin/fm-lab-home.sh', 'create', lab])
    (lab / 'tmux').mkdir()
    write(lab / 'config/backend', 'tmux\n')
    run(['tmux', '-L', 'fm-lab', 'new-session', '-d', '-s', 'observer', '-x', '120', '-y', '40', '-c', root, 'bash'])
    socket = run(['tmux', '-L', 'fm-lab', 'display-message', '-p', '-t', 'observer', '#{socket_path}']).stdout.strip()
    pane = run(['tmux', '-L', 'fm-lab', 'display-message', '-p', '-t', 'observer', '#{pane_id}']).stdout.strip()
    env['TMUX'] = socket + ',0,0'
    write(lab / 'config/writing-lane-cap', '3\n')
    write(lab / 'config/release-capacity', '1\n')
    write(lab / 'data/backlog.md', '# Backlog\n\n## Queued\n- [ ] repair-one - Dispatchable repair (kind: ship)\n- [ ] independent-one - Independent admitted item (kind: ship)\n')
    run(['bin/fm-tasks-axi.sh', 'ready'])
    scenario('Ready work below the lane and release limits produces an idle-capacity wake',
             lambda: watch('idle writing lanes: 0/3 occupied, 0 working, 2 ready:'))
    scenario('An unchanged ready set does not repeat the capacity wake', lambda: watch(quiet=True))
    write(lab / 'state/one.meta', 'kind=ship\npr=https://github.com/example/repo/pull/7\n')
    scenario('A recorded PR saturates release capacity and the wake still names repair and independent work',
             lambda: watch('lane backpressure: 1/1 lanes awaiting validation or release'))
    (lab / 'state/one.meta').unlink()
    scenario('Retiring a published lane restores available capacity', lambda: watch('idle writing lanes: 0/3 occupied'))
    write(lab / 'state/one.meta', 'kind=ship\n')
    def unknown():
        run(['bin/fm-crew-state.sh', 'one'])
        watch(quiet=True)
        triage = (lab / 'state/.watch-triage.log').read_text()
        log.write('Watcher triage:\n' + triage)
        assert 'idle-lane release state unavailable: one' in triage
    scenario('An unreadable unpublished lane suppresses capacity advice and names the lane', unknown)
    (lab / 'state/one.meta').unlink()

    # The real watcher and crew resolver consume disposable persisted protocol
    # records. No harness executable is substituted and no LLM turn is claimed.
    project, wt = lab / 'projects/fixture', lab / 'worker'
    run(['git', 'init', '-q', project])
    run(['git', '-C', project, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
         'commit', '-q', '--allow-empty', '-m', 'Disposable data fixture'])
    run(['git', 'clone', '-q', project, wt])
    run(['git', '-C', wt, 'checkout', '-q', '--detach'])
    head = run(['git', '-C', wt, 'rev-parse', 'HEAD']).stdout.strip()
    write(lab / 'state/one.meta', f'kind=ship\nmode=local-only\nharness=claude\nbackend=tmux\nwindow={pane}\nworktree={wt}\nproject={project}\n')
    run(['bin/fm-busy-event.sh', 'arm', lab / 'state', 'one', '--state', 'idle', '--source', 'fm-recovery', '--event', 'fixture-input'])
    for label, url in [('documentation', 'https://docs.example.test/setup'), ('issue', 'https://github.com/example/repo/issues/7')]:
        write(lab / 'state/one.status', f'done: local branch ready: {head}; reference: {url}\n')
        (lab / 'state/.last-idle-lane-wake').unlink(missing_ok=True)
        def local_link():
            resolved = run(['bin/fm-crew-state.sh', 'one']).stdout
            assert 'state: done · source: status-log' in resolved, resolved
            output = watch('idle writing lanes: 1/3 occupied')
            assert 'lane backpressure' not in output
        scenario(f'A completed local-only lane with a {label} link preserves ordinary idle advice', local_link)
    write(lab / 'state/one.status', 'done: PR https://github.com/example/repo/pull/7 checks green\n')
    def pr_report():
        resolved = run(['bin/fm-crew-state.sh', 'one']).stdout
        assert 'state: done · source: status-log' in resolved, resolved
        watch('lane backpressure: 1/1 lanes awaiting validation or release')
    scenario('A real-format completed PR report consumes release capacity without pr metadata', pr_report)
    (lab / 'state/one.status').unlink()
    write(lab / 'config/release-capacity', 'zero\n')
    def invalid_capacity():
        watch(quiet=True)
        triage = (lab / 'state/.watch-triage.log').read_text()
        log.write('Watcher triage:\n' + triage)
        assert 'invalid config/release-capacity' in triage
    scenario('Invalid release capacity refuses to invent a capacity notice', invalid_capacity)

    rows = [
        ('no-mistakes +yolo landing=mergify', 'no-mistakes on', 'mergify', 0),
        ('direct-PR branch=q/', 'direct-PR off', 'direct', 0),
        ('local-only landing=mergify', 'local-only off', '', 3),
        ('no-mistakes landing=queue', 'no-mistakes off', '', 3),
        ('no-mistakes landing=', 'no-mistakes off', '', 3),
    ]
    def registry():
        for tokens, default, landing, code in rows:
            write(lab / 'data/projects.md', '- fp [' + tokens + '] - Disposable project\n')
            assert run(['bin/fm-project-mode.sh', 'fp']).stdout.strip() == default
            assert run(['bin/fm-project-mode.sh', '--landing', 'fp'], code).stdout.strip() == landing
            assert run(['bin/fm-project-mode.sh', '--forge', 'fp']).stdout.strip() == 'none'
        assert run(['bin/fm-project-mode.sh', '--landing', 'unregistered']).stdout.strip() == 'direct'
    scenario('Selecting queue landing preserves delivery posture and refuses invalid or local-only queue configuration', registry)
    def local_merge_guards():
        write(lab / 'state/guard.meta', f'kind=ship\nmode=no-mistakes\nproject={lab}/projects/fp\n')
        for tokens in ('no-mistakes landing=queue', 'local-only landing=mergify'):
            write(lab / 'data/projects.md', '- fp [' + tokens + '] - Disposable project\n')
            result = run(['bin/fm-pr-merge.sh', 'guard', 'https://github.com/example/repo/pull/7'], 2)
            assert 'invalid or unreadable; nothing was handed to the forge' in result.stderr
        write(lab / 'data/projects.md', '- fp [no-mistakes +yolo landing=mergify] - Disposable project\n')
        result = run(['bin/fm-pr-merge.sh', 'guard', 'https://github.com/example/repo/pull/7', '--allow-red', 'unit'], 2)
        assert 'waivers and extra merge arguments apply only to the attended repair path' in result.stderr
    scenario('The public merge command refuses invalid landing and routine queue waivers before contacting the forge', local_merge_guards)
    write(lab / 'config/release-capacity', '1\n')
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
        log.write('Disposable lab, private tmux socket, fixture repositories and state removed.\n')
    (evidence / 'current-live-local-results.json').write_text(json.dumps(results, indent=2) + '\n')
    log.close()

print(json.dumps(results, indent=2))
raise SystemExit(1 if any(r['result'] == 'fail' for r in results) else 0)
