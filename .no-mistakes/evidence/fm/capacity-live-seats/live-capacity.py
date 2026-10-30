"""Run from the gate worktree. Real Firstmate, tmux, lsof, ps and OS processes.
Oracle: owner's seat rule; no product implementations or liveness probes mocked.
Fixtures and private socket stay inside the worktree and are removed on exit.
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
LAB = ROOT / '.test-capacity-tmp' / 'live-lab'
SOCKET = '.test-capacity-tmp/live.sock'
SESSION = 'fm-lab-capacity'
env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_') or key in ('TMUX', 'TMUX_PANE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
        env.pop(key)
env.update(FM_HOME=str(LAB), TMPDIR=str(ROOT / '.test-capacity-tmp'),
           TREEHOUSE_ROOT=str(LAB / 'pool'), SHELL='/bin/bash',
           DISABLE_AUTOUPDATER='1', LC_ALL='C', BASH_ENV='/dev/null')
children = []
transcript = []
results = []

def log(s):
    print(s, flush=True)
    transcript.append(s)

def run(args, *, check=True, custom_env=None, timeout=90):
    p = subprocess.run(args, cwd=ROOT, env=custom_env or env,
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=timeout)
    if check and p.returncode:
        raise RuntimeError(f'{shlex.join(args)} => {p.returncode}\n{p.stdout}')
    return p

def tmux(*args, check=True):
    return run(['tmux', '-S', SOCKET, *args], check=check)

def record(name, wt, target=None, extra='', home=LAB, project=None):
    (home / 'state' / f'{name}.meta').write_text(
        f'kind=ship\nbackend=tmux\nharness=codex\nproject={project or LAB / "project"}\n'
        f'window={target or SESSION + ":missing-" + name}\nworktree={wt}\n{extra}')

def clear_records():
    for home in (LAB, LAB / 'mate'):
        if (home / 'state').exists():
            for path in (home / 'state').glob('*.meta'):
                path.unlink()

def counts(label, project_expected, lanes_expected=None, *, base=False, custom_env=None):
    shell = '''set -eu
FM_ROOT=$PWD; STATE=$FM_HOME/state; CONFIG=$FM_HOME/config
. bin/fm-wake-lib.sh
. bin/fm-backend.sh
. bin/fm-secondmate-registry-lib.sh
. bin/fm-capacity-lib.sh
. "$1"
lock=$(fm_treehouse_project_lock_path "$FM_HOME/project")
fm_project_capacity_occupants "$lock" "$FM_HOME/project" "$STATE" candidate
printf 'project_occupants=%s ids=[%s]\\n' "$FM_PROJECT_CAPACITY_OCCUPANTS" "$FM_PROJECT_CAPACITY_OCCUPANT_IDS"
'''
    lib = str(LAB / 'base-project-lib.sh') if base else 'bin/fm-project-capacity-lib.sh'
    p = run(['bash', '-c', shell, '_', lib], custom_env=custom_env)
    log(f'{label}: {p.stdout.strip()}')
    actual = int(p.stdout.split('project_occupants=')[1].split()[0])
    assert actual == project_expected, (label, actual, project_expected)
    if lanes_expected is not None:
        p = run(['bin/fm-capacity.sh', '--json'], custom_env=custom_env)
        facts = json.loads(p.stdout)
        log('fm-capacity.sh --json: ' + json.dumps({k: facts[k] for k in
            ('readable', 'reason', 'lanes', 'target', 'free_lanes')}))
        assert facts['readable'] and facts['lanes'] == lanes_expected, facts

def proof(name):
    results.append({'name': name, 'result': 'pass', 'live': True})
    log('PROVED: ' + name)

def worker(cwd):
    p = subprocess.Popen(['/usr/bin/sleep', '300'], cwd=cwd, env=env)
    children.append(p)
    time.sleep(.1)
    log(f'Live workload pid={p.pid}, cwd={os.readlink(f"/proc/{p.pid}/cwd")}')
    return p

def stop(p):
    p.terminate()
    p.wait(timeout=5)

try:
    assert not LAB.exists()
    run(['bin/fm-lab-home.sh', 'create', str(LAB)])
    (LAB / 'config/lane-capacity').write_text('30 0\n')
    (LAB / 'config/project-capacity').write_text('project 1\n')
    (LAB / 'config/crew-harness').write_text('codex\n')
    (LAB / 'config/machine-admission.json').write_text(json.dumps({
        'schema':'fm-machine-admission.v1', 'memory_floor_gib':0,
        'memory_full_avg60_max':100, 'disk_floor_gib':0, 'disk_paths':[str(LAB)]}))
    (LAB / 'state/.last-watcher-beat').touch()
    project = LAB / 'project'
    run(['git', 'init', '-q', str(project)])
    run(['git', '-C', str(project), '-c', 'user.name=Capacity Lab', '-c',
         'user.email=capacity@example.invalid', '-c', 'core.hooksPath=/dev/null',
         '-c', 'commit.gpgsign=false', 'commit', '--quiet', '--allow-empty', '-m', 'fixture'])
    run(['git', 'init', '--bare', '-q', str(LAB / 'origin.git')])
    run(['git', '-C', str(project), 'remote', 'add', 'origin', str(LAB / 'origin.git')])
    run(['git', '-C', str(project), 'push', '-q', 'origin', 'HEAD'])
    base = run(['git', 'show', '2bafe15f26658147adf097c4f0dbef263761c814:bin/fm-project-capacity-lib.sh'])
    (LAB / 'base-project-lib.sh').write_text(base.stdout)
    idle = LAB / 'idle'
    idle.mkdir()
    (idle / 'nested').mkdir()
    sibling = LAB / 'idle-other'
    sibling.mkdir()
    # No user tmux config/plugins. Nonzero PTY dimensions are set before shells start.
    tmux('-f', '/dev/null', 'new-session', '-d', '-x', '100', '-y', '30',
         '-s', SESSION, '-n', 'parked', '-c', str(idle), '/bin/bash --noprofile --norc')
    tmux('set-option', '-g', 'default-command', '/bin/bash --noprofile --norc')
    tmux('set-option', '-g', 'default-shell', '/bin/bash')
    tmux('set-window-option', '-g', 'automatic-rename', 'off')
    # Firstmate's unmodified tmux client calls inherit precisely this socket.
    env['TMUX'] = tmux('display-message', '-p', '-t', SESSION, '#{socket_path},#{pid},0').stdout.strip()
    log('Private session dimensions: ' + tmux('display-message', '-p', '-t', SESSION,
        '#{session_name} #{pane_width}x#{pane_height}').stdout.strip())
    record('exited', idle)
    counts('BASE: exited retained record (regression reproduced)', 1, base=True)
    counts('TARGET: missing endpoint with empty worktree', 0, 0)
    record('exited', idle, SESSION + ':parked')
    counts('TARGET: parked shell holds no seat', 0, 0)
    # A same-prefix sibling must not be mistaken for a descendant.
    p = worker(sibling)
    counts('TARGET: same-prefix sibling workload does not consume this seat', 0, 0)
    stop(p)
    proof('Exited or parked records free their project and machine seats; the base retained them')

    p = worker(idle / 'nested')
    counts('TARGET: surviving non-shell descendant retains seat', 1, 1)
    stop(p)
    counts('TARGET: terminating descendant immediately frees seat', 0, 0)
    alias = LAB / 'idle-alias'
    alias.symlink_to(idle, target_is_directory=True)
    record('exited', alias)
    p = worker(idle / 'nested')
    counts('TARGET: canonicalized symlink worktree retains surviving process', 1, 1)
    stop(p)
    proof('A surviving process in a nested or symlinked worktree holds a seat until it exits')

    clear_records()
    record('unknown-worktree', LAB / 'not-created')
    counts('TARGET: missing worktree is uncertain evidence', 1, 1)
    clear_records()
    record('unreadable-worktree', idle)
    idle.chmod(0)
    counts('TARGET: unreadable worktree keeps its seat', 1, 1)
    idle.chmod(0o755)
    counts('TARGET: restored readability frees idle record', 0, 0)
    clear_records()
    # A real non-agent foreground process supplies ambiguous endpoint evidence.
    tmux('new-window', '-d', '-t', SESSION, '-n', 'ambiguous', '-c', str(sibling), 'sleep 300')
    record('ambiguous', idle, SESSION + ':ambiguous')
    counts('TARGET: ambiguous endpoint retains an otherwise idle worktree', 1, 1)
    tmux('kill-window', '-t', SESSION + ':ambiguous')
    counts('TARGET: proven missing endpoint permits release', 0, 0)
    proof('Missing or unreadable worktrees and uncertain endpoint liveness retain seats')

    # Actual lsof unavailability, without a fake process inventory or probe.
    clear_records()
    record('no-scan', idle)
    toolsdir = LAB / 'tools-without-lsof'
    toolsdir.mkdir()
    for name in ('bash','dirname','cat','sed','tail','head','basename','git','ps','stat',
                 'uname','jq','python3','awk','getconf','df','tr','hostname','readlink','id',
                 'mkdir','tmux','grep','cut','od','sort','realpath','date','shasum',
                 'sha256sum','wc','sleep','perl','find','tty','rmdir','rm'):
        path = shutil.which(name)
        if path:
            (toolsdir / name).symlink_to(path)
    no_scan_env = dict(env, PATH=str(toolsdir))
    state = run(['bash', '-c', '. bin/fm-backend.sh; fm_backend_agent_state tmux "$1"',
                 '_', SESSION + ':parked'], custom_env=no_scan_env).stdout
    assert state == 'dead', state
    assert run(['bash', '-c', 'command -v lsof'], check=False,
               custom_env=no_scan_env).returncode != 0
    log('FAULT SETUP: endpoint remains proven dead; lsof alone is unavailable')
    counts('TARGET: absent lsof retains project seat', 1, custom_env=no_scan_env)
    counts('TARGET: normal process evidence restores release', 0, 0)
    proof('Unavailable process scanning fails closed and restored scanning frees the seat')

    clear_records()
    record('released', LAB / 'state/released.released-copy')
    counts('TARGET: completed-release sentinel with missing endpoint', 0, 0)
    record('released', LAB / 'state/released.released-copy', SESSION + ':parked')
    counts('TARGET: completed-release sentinel with dead shell endpoint', 0, 0)
    proof('Completed-release sentinel records still hold no seat when agents are gone')

    clear_records()
    mate = LAB / 'mate'
    run(['bin/fm-lab-home.sh', 'create', str(mate)])
    (mate / '.fm-secondmate-parent').write_text(
        f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={LAB}\n')
    (LAB / 'data/secondmates.md').write_text(
        f'- mate - local (home: {mate}; scope: tests; projects: project; added 2026-10-30)\n')
    clone = mate / 'clone'
    run(['git', 'clone', '-q', str(LAB / 'origin.git'), str(clone)])
    record('root-exited', idle)
    record('mate-exited', idle, home=mate, project=clone)
    counts('TARGET: exited records across registered homes share no seats', 0, 0)
    p = worker(idle / 'nested')
    counts('TARGET: both homes observe the surviving workload', 2, 2)
    stop(p)
    counts('TARGET: both homes release after workload exit', 0, 0)
    proof('Registered local homes and same-origin clones share the live seat rule')

    clear_records()
    # An authentic, idle installed harness, with no model request or credentials changed.
    command = ['codex', '--no-daemon', '--disable', 'hooks', '-c',
               f'projects."{ROOT}".trust_level="trusted"']
    tmux('new-window', '-d', '-t', SESSION, '-n', 'agent', '-c', str(ROOT), shlex.join(command))
    deadline = time.monotonic() + 25
    pane = ''
    while time.monotonic() < deadline:
        pane = tmux('capture-pane', '-p', '-t', SESSION + ':agent', check=False).stdout
        if 'Update now' in pane and 'esc skip' in pane:
            # Skip this invocation's updater without changing installed tools/config.
            tmux('send-keys', '-t', SESSION + ':agent', 'Escape')
        if 'Codex' in pane and ('context left' in pane or 'Send a message' in pane or 'gpt-' in pane):
            break
        time.sleep(.5)
    log('AUTHENTIC HARNESS PANE:\n' + pane)
    (EVIDENCE / 'codex-pane.txt').write_text(pane)
    assert 'Codex' in pane and not ('Sign in' in pane or 'sign in' in pane), pane
    state = run(['bash', '-c', '. bin/fm-backend.sh; fm_backend_agent_state tmux "$1"',
                 '_', SESSION + ':agent']).stdout
    assert state == 'alive', state
    record('live-agent', idle, SESSION + ':agent')
    counts('TARGET: live harness holds seat even outside its empty recorded worktree', 1, 1)
    record('live-agent', LAB / 'state/live-agent.released-copy', SESSION + ':agent')
    counts('TARGET: live harness cannot be hidden by a released-copy sentinel', 1, 1)
    tmux('kill-window', '-t', SESSION + ':agent')
    counts('TARGET: terminated harness releases its sentinel seat', 0, 0)
    proof('A real live Codex agent retains its seat even with an idle worktree or released-copy sentinel')

    clear_records()
    # End-to-end public spawn admission, using its supported raw command input.
    # The worker is an actual Python workload, not a substitute CLI or liveness probe.
    workload = LAB / 'workload.py'
    workload.write_text('import os,time\nfrom pathlib import Path\n'
                        f'Path({str(LAB / "worker-started.json")!r}).write_text('
                        'str(os.getpid())+"\\n"+os.getcwd())\ntime.sleep(300)\n')
    for task in ('candidate', 'blocked'):
        (LAB / 'data' / task).mkdir()
        (LAB / 'data' / task / 'brief.md').write_text(
            '# Task\n## Captain\'s intent\nRun the disposable capacity workload.\n'
            '## Firstmate spec\nRun only the supplied disposable workload.\n'
            '# Definition of done\nDelivery contract: mode=local-only\n')
    record('retained-exited', idle)
    raw = f'{sys.executable} {shlex.quote(str(workload))}'
    p = run(['bin/fm-spawn.sh', 'candidate', str(project), '--mode', 'local-only',
             '--yolo', 'off', raw], check=False, timeout=90)
    log(f'PUBLIC SPAWN candidate exit={p.returncode}\n{p.stdout}')
    assert p.returncode == 0, p.stdout
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline and not (LAB / 'worker-started.json').exists():
        time.sleep(.2)
    assert (LAB / 'worker-started.json').exists(), tmux('capture-pane', '-p', '-t', SESSION + ':fm-candidate').stdout
    log('WORKLOAD STARTED: ' + (LAB / 'worker-started.json').read_text())
    counts('TARGET: only launched workload occupies project', 1, 1)
    p = run(['bin/fm-spawn.sh', 'blocked', str(project), '--mode', 'local-only',
             '--yolo', 'off', raw], check=False)
    log(f'PUBLIC SPAWN blocked exit={p.returncode}\n{p.stdout}')
    assert p.returncode == 75 and '1 already hold a place (candidate)' in p.stdout
    assert not (LAB / 'state/blocked.meta').exists()
    proof('A retained exited record permits a real worker launch; the live worker blocks the next launch at the project cap')
finally:
    for p in children:
        if p.poll() is None:
            p.terminate()
            p.wait(timeout=5)
    # Private tmux owns all worker descendants, including Treehouse shells.
    tmux('kill-server', check=False)
    time.sleep(.3)
    if LAB.exists():
        if (LAB / 'idle').exists():
            (LAB / 'idle').chmod(0o755)
        # The pool hardens its own copied Git hooks directory against writes.
        # Restore only our disposable tree's owner write permission for removal.
        for directory, subdirs, files in os.walk(LAB, followlinks=False):
            os.chmod(directory, os.stat(directory).st_mode | 0o700)
        shutil.rmtree(LAB)
    log('CLEANUP: private tmux server stopped; disposable lab removed')
    (EVIDENCE / 'live-capacity.log').write_text('\n'.join(transcript) + '\n')
    (EVIDENCE / 'live-capacity-results.json').write_text(json.dumps(results, indent=2) + '\n')
