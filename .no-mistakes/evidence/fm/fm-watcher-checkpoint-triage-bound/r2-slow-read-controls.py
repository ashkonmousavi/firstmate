import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

root = Path.cwd()
evidence = Path('/home/tegris/.no-mistakes/evidence/01M4C578R6BY8Y88P3P9QJDFDG')
lab = root/'.checkpoint-causal-lab'
socketdir = root/'.t2'
env = dict(os.environ)
for k in ('NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_TEST_SEAM', 'CODEX_SESSION_ID', 'CODEX_THREAD_ID', 'FM_TASK_ID'):
    env.pop(k, None)
env.update(TMUX_TMPDIR=str(socketdir), TMPDIR=str(lab), FM_POLL='1', FM_SIGNAL_GRACE='0', FM_CHECK_TIMEOUT='1', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999')
records = []
pid = None
trace = None

def run(args):
    if env.get('BASH_ENV'):
        process = subprocess.Popen(args, cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(trace.fileno(),))
        known = set()
        previous = {}
        snapshots = []
        trees = []
        marks = [1.8, 3.5, 5.0, 12.0]
        started = time.monotonic()
        while process.poll() is None:
            children = [process.pid]
            tree = []
            while children:
                child = children.pop()
                try:
                    children.extend(int(n) for n in Path(f'/proc/{child}/task/{child}/children').read_text().split())
                    cmd = Path(f'/proc/{child}/cmdline').read_bytes().split(b'\0')
                    fields = Path(f'/proc/{child}/stat').read_text().rsplit(')', 1)[1].split()
                    tree.append(dict(pid=child,ppid=int(fields[1]),pgid=int(fields[2]),exe=cmd[0].decode(errors='replace') if cmd else '',args=[a.decode(errors='replace')[:120] for a in cmd[1:5]]))
                    if cmd and cmd[0].split(b'/')[-1] == b'tmux':
                        known.add(child)
                except (FileNotFoundError, ProcessLookupError):
                    pass
            for child in known:
                try:
                    fields = Path(f'/proc/{child}/stat').read_text().rsplit(')', 1)[1].split()
                    info = dict(pid=child, ppid=int(fields[1]), pgid=int(fields[2]), session=int(fields[3]))
                except FileNotFoundError:
                    info = dict(pid=child, gone=True)
                if previous.get(child) != info:
                    previous[child] = info
                    snapshots.append(dict(elapsed=round(time.monotonic()-started, 3), **info))
            time.sleep(0.05)
            if marks and time.monotonic()-started >= marks[0]:
                trees.append(dict(elapsed=round(time.monotonic()-started,3),tree=tree))
                marks.pop(0)
        out, err = process.communicate(timeout=3)
        (evidence/'r2-stalled-client-lifetime.json').write_text(json.dumps(snapshots, indent=2)+'\n')
        (evidence/'r2-stalled-reader-process-trees.json').write_text(json.dumps(trees, indent=2)+'\n')
        return subprocess.CompletedProcess(args, process.returncode, out, err)
    return subprocess.run(args, cwd=root, env=env, text=True, capture_output=True, timeout=23, pass_fds=(trace.fileno(),) if trace else ())

def checkpoint(name, executable, stopped):
    p = lab/name
    assert run(['bash', 'bin/fm-lab-home.sh', 'create', str(p)]).returncode == 0
    env['FM_HOME'] = str(p)
    (p/'state/one.meta').write_text('kind=ship\nbackend=tmux\nharness=codex\nwindow=primary:0\n')
    for f in ('.last-check', '.last-heartbeat', 'home-summary.json'):
        (p/'state'/f).touch()
    if stopped:
        os.kill(pid, signal.SIGSTOP)
    try:
        start = time.monotonic()
        if name == 'target-real-stalled-read-GREEN':
            env['BASH_ENV'] = str(evidence/'traced-shell.sh')
            env['BASH_XTRACEFD'] = str(trace.fileno())
        r = run(['bash', str(executable), '--seconds', '3'])
        env.pop('BASH_ENV', None)
        env.pop('BASH_XTRACEFD', None)
        record = dict(label=name, stopped_real_tmux=stopped, elapsed=round(time.monotonic()-start, 3), rc=r.returncode, stdout=r.stdout, stderr=r.stderr)
        records.append(record)
        print(json.dumps(record), flush=True)
        return r
    finally:
        if stopped:
            os.kill(pid, signal.SIGCONT)

try:
    assert not lab.exists() and not socketdir.exists()
    lab.mkdir(mode=0o700)
    socketdir.mkdir(mode=0o700)
    trace = (evidence/'r2-stalled-tmux-trace.log').open('w')
    baseline = lab/'baseline'
    shutil.copytree(root/'bin', baseline/'bin')
    paths = run(['git', 'diff', '--name-only', '0e43755177cde2a05b2fb68c0eec9c5d5a76da84', '8d876d3ea7fa406a00b9f793cfd794c48bdfe26a', '--', 'bin']).stdout.splitlines()
    for path in paths:
        r = run(['git', 'show', f'0e43755177cde2a05b2fb68c0eec9c5d5a76da84:{path}'])
        assert r.returncode == 0, r.stderr
        (baseline/path).write_text(r.stdout)
    r = run(['tmux', '-L', 'fm-lab', 'new-session', '-d', '-s', 'primary', '-x', '120', '-y', '40', '-c', str(root), 'sleep 600'])
    assert r.returncode == 0, r.stderr
    pid = int(run(['tmux', '-L', 'fm-lab', 'display-message', '-p', '#{pid}']).stdout)
    env['TMUX'] = run(['tmux', '-L', 'fm-lab', 'display-message', '-p', '#{socket_path},#{pid},0']).stdout.strip()
    control = checkpoint('base-short-control', baseline/'bin/fm-watch-checkpoint.sh', False)
    assert control.returncode == 124
    red = checkpoint('base-real-stalled-read-RED', baseline/'bin/fm-watch-checkpoint.sh', True)
    assert red.returncode == 1 and 'exceeded the quiet bound' in red.stderr
    green = checkpoint('target-real-stalled-read-GREEN', root/'bin/fm-watch-checkpoint.sh', True)
    # A disposable target copy with only the old watcher reinstated is the
    # independent fault: shared libraries retain the target implementation.
    fault = lab/'fault'
    shutil.copytree(root/'bin', fault/'bin')
    shutil.copy2(baseline/'bin/fm-timeout-lib.sh', fault/'bin/fm-timeout-lib.sh')
    broken = checkpoint('target-old-output-owner-FAULT', fault/'bin/fm-watch-checkpoint.sh', True)
    assert broken.returncode == 1 and 'exceeded the quiet bound' in broken.stderr
    assert green.returncode == 124 and records[-2]['elapsed'] < 6, 'target did not bound the real stopped tmux output'
    restored = checkpoint('target-restored-control', root/'bin/fm-watch-checkpoint.sh', False)
    assert restored.returncode == 124
    print('REAL STALLED READ CONTROLS FINISHED; target GREEN and old-output-owner FAULT retained', flush=True)
finally:
    if pid:
        try:
            os.kill(pid, signal.SIGCONT)
        except ProcessLookupError:
            pass
        r = run(['tmux', '-L', 'fm-lab', 'kill-server'])
        records.append(dict(label='private causal lab teardown', rc=r.returncode, stderr=r.stderr))
    shutil.rmtree(lab, ignore_errors=True)
    shutil.rmtree(socketdir, ignore_errors=True)
    (evidence/'r2-slow-read-controls.json').write_text(json.dumps(records, indent=2)+'\n')
    if trace:
        trace.close()
