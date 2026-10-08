import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

ROOT = Path.cwd()
EVIDENCE = Path('/home/tegris/.no-mistakes/evidence/01M4C578R6BY8Y88P3P9QJDFDG')
LAB = ROOT / '.checkpoint-live-lab'
SOCKETS = ROOT / '.t'
env = dict(os.environ)
for key in ('NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_TEST_SEAM', 'CODEX_SESSION_ID', 'CODEX_THREAD_ID', 'FM_TASK_ID'):
    env.pop(key, None)
env.update(TMUX_TMPDIR=str(SOCKETS), TMPDIR=str(LAB), FM_POLL='1', FM_CHECK_TIMEOUT='1', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999')
records = []
server = None

def command(args, extra=None, timeout=25):
    return subprocess.run(args, cwd=ROOT, env=env | (extra or {}), text=True, capture_output=True, timeout=timeout)

def tmux(*args):
    r = command(['tmux', '-L', 'fm-lab', *args])
    if r.returncode:
        raise RuntimeError(r.stderr)
    return r.stdout.strip()

def home(name):
    p = LAB / name
    r = command(['bash', 'bin/fm-lab-home.sh', 'create', str(p)])
    assert r.returncode == 0, r.stderr
    for f in ('.last-check', '.last-heartbeat', 'home-summary.json'):
        (p / 'state' / f).touch()
    return p

def checkpoint(p, label, seconds=3, prefix=None):
    args = (prefix or []) + ['bash', 'bin/fm-watch-checkpoint.sh', '--seconds', str(seconds)]
    start = time.monotonic()
    process = subprocess.Popen(args, cwd=ROOT, env=env | {'FM_HOME': str(p)}, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    observed = set()
    while process.poll() is None:
        children = [process.pid]
        while children:
            pid = children.pop()
            try:
                children.extend(int(n) for n in Path(f'/proc/{pid}/task/{pid}/children').read_text().split())
                argv = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
                if argv and argv[0].split(b'/')[-1] == b'tmux':
                    observed.add(' '.join(a.decode(errors='replace') for a in argv if a))
            except (FileNotFoundError, ProcessLookupError):
                pass
        if time.monotonic() - start > seconds + 18:
            process.kill()
            raise TimeoutError(label)
        time.sleep(0.05)
    stdout, stderr = process.communicate()
    r = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    rec = dict(label=label, command=args, seconds=seconds, elapsed=round(time.monotonic()-start, 3), rc=r.returncode, stdout=r.stdout, stderr=r.stderr,
               cursor=(p/'state/.watch-window-cursor').read_text() if (p/'state/.watch-window-cursor').exists() else '',
               queue=(p/'state/.wake-queue').read_text() if (p/'state/.wake-queue').exists() else '', observed_backend_commands=sorted(observed))
    records.append(rec)
    print(json.dumps(rec), flush=True)
    return r

def quiet(r):
    assert r.returncode == 124 and 'checkpoint: no actionable wake within' in r.stdout, (r.returncode, r.stdout, r.stderr)

def ack(p, label):
    r = command(['bash', 'bin/fm-wake-drain.sh'], {'FM_HOME': str(p)})
    assert r.returncode == 0, r.stderr
    records.append(dict(label=label, stdout=r.stdout, stderr=r.stderr))
    print(json.dumps(records[-1]), flush=True)
    m = re.search(r'--ack-through (\d+) --recovery-generation (\S+)', r.stderr)
    assert m, r.stderr
    a = command(['bash', 'bin/fm-wake-drain.sh', '--ack-through', m[1], '--recovery-generation', m[2]], {'FM_HOME': str(p)})
    assert a.returncode == 0, a.stderr
    return r.stdout

def meta(p, name, target):
    (p/'state'/f'{name}.meta').write_text(f'kind=ship\nbackend=tmux\nharness=codex\nwindow={target}\n')

try:
    assert not LAB.exists() and not SOCKETS.exists()
    LAB.mkdir(mode=0o700)
    SOCKETS.mkdir(mode=0o700)
    tmux('new-session', '-d', '-s', 'primary', '-x', '120', '-y', '40', '-c', str(ROOT), 'sleep 600')
    server = int(tmux('display-message', '-p', '#{pid}'))
    env['TMUX'] = tmux('display-message', '-p', '#{socket_path},#{pid},0')
    records.append(dict(label='private real tmux', server_pid=server, socket=env['TMUX'], grid=tmux('display-message', '-p', '#{window_width}x#{window_height}')))
    p = home('native-empty')
    quiet(checkpoint(p, 'native Codex quiet', prefix=['codex', 'sandbox', '-c', 'sandbox_mode="workspace-write"']))
    p = home('short')
    meta(p, 'one', 'primary:0')
    quiet(checkpoint(p, 'one real pane quiet control'))
    for i in range(1, 31):
        tmux('new-window', '-d', '-t', 'primary', '-n', f'lane{i:03}', '-c', str(ROOT), 'sleep 600')
    p = home('long')
    for i in range(1, 181):
        meta(p, f'lane{i:03}', f'primary:lane{(i-1)%30+1:03}')
    quiet(checkpoint(p, '180 records / 30 real panes quiet'))
    for i in range(1, 9):
        cursor = (p/'state/.watch-window-cursor').read_text()
        if 'panes=' in cursor:
            break
        quiet(checkpoint(p, f'long inventory continuation {i}'))
    cursor = (p/'state/.watch-window-cursor').read_text()
    assert 'panes=' in cursor, 'long control never reached pane observations'
    p = home('fair')
    for i in range(1, 19):
        meta(p, f'lane{i:03}', f'primary:lane{(i-1)%30+1:03}')
    meta(p, 'zz-later', 'primary:0')
    inbox = p/'state/zz-later.inbox/001.msg'
    inbox.parent.mkdir()
    inbox.write_text('retain pending instruction\n')
    (p/'state/zz-later.prompt-waiting').write_text(f'{int(time.time())} {os.getpid()}\n')
    custody = (p/'state/zz-later.meta').read_bytes() + inbox.read_bytes()
    first = checkpoint(p, 'later-lane first budget')
    quiet(first)
    for i in range(1, 13):
        r = checkpoint(p, f'later-lane resumed cycle {i}')
        if r.returncode == 0 and 'a permission or question prompt is waiting' in r.stdout:
            break
        quiet(r)
    else:
        raise AssertionError('later-lane prompt not delivered after twelve cycles')
    assert custody == (p/'state/zz-later.meta').read_bytes() + inbox.read_bytes()
    drained = ack(p, 'later-lane durable drain')
    assert drained.count('\tstale\tprimary:0\t') == 1, drained
    r = checkpoint(p, 'after later-lane generation acknowledgement')
    assert r.returncode in (0, 124), r.stderr
    assert 'stale: primary:0 ' not in r.stdout, 'acknowledged witness repeated'
    q = command(['bash', 'bin/fm-wake-drain.sh'], {'FM_HOME': str(p)})
    assert '\tstale\tprimary:0\t' not in q.stdout
    records.append(dict(label='later-lane custody unchanged and no replay', custody_sha256=hashlib.sha256(custody).hexdigest(), pending_inbox=inbox.read_text(), post_ack_drain=q.stdout))
    p = home('stopped-backend')
    meta(p, 'one', 'primary:0')
    os.kill(server, signal.SIGSTOP)
    try:
        r = checkpoint(p, 'real tmux server stopped: bounded observation', seconds=6)
        records[-1]['expected_rc'] = 124
        records[-1]['scenario_result'] = 'pass' if r.returncode == 124 else 'fail'
        assert any('capture-pane' in a for a in records[-1]['observed_backend_commands']), 'stopped server did not exercise the real capture'
        assert not (p/'state/.wake-queue').exists() or not (p/'state/.wake-queue').read_text()
    finally:
        os.kill(server, signal.SIGCONT)
    quiet(checkpoint(p, 'real tmux server restored control'))
    p = home('recovery-handoff')
    child = p/'child'
    assert command(['bash', 'bin/fm-lab-home.sh', 'create', str(child)]).returncode == 0
    (child/'.fm-secondmate-home').write_text('mate\n')
    record = p/'state/mate.meta'
    record.write_text(f'kind=secondmate\nbackend=tmux\nharness=codex\nwindow=primary:absent-mate\nhome={child}\n')
    before = record.read_bytes()
    for n in (1, 2):
        r = checkpoint(p, f'bounded missing-mate recovery handoff {n}', seconds=6)
        assert r.returncode == 0 and 'recovery cycle required for relaunch mate' in r.stdout
        assert not (p/'state/.secondmate-relaunch-mate').exists(), 'bounded handoff consumed a recovery attempt'
        assert before == record.read_bytes()
    rows = (p/'state/.wake-queue').read_text()
    assert rows.count('\tcheckpoint-recovery-relaunch-mate\t') == 1
    records.append(dict(label='owed recovery durable once before mutation', queue=rows, unchanged_custody=before.decode()))
    p = home('signal')
    (p/'state/demo.status').write_text('done: live signal witness\n')
    r = checkpoint(p, 'real status signal publication')
    assert r.returncode == 0 and 'signal:' in r.stdout
    drained = ack(p, 'status generation acknowledgement')
    assert drained.count('\tsignal\tdemo.status\t') == 1
    quiet(checkpoint(p, 'acknowledged status does not repeat'))
    print('LIVE CHECKPOINT SCENARIOS FINISHED; see per-scenario results', flush=True)
finally:
    if server:
        try:
            os.kill(server, signal.SIGCONT)
        except ProcessLookupError:
            pass
        r = command(['tmux', '-L', 'fm-lab', 'kill-server'])
        records.append(dict(label='private tmux teardown', rc=r.returncode, stderr=r.stderr))
    shutil.rmtree(LAB, ignore_errors=True)
    shutil.rmtree(SOCKETS, ignore_errors=True)
    (EVIDENCE/'live-checkpoints.json').write_text(json.dumps(records, indent=2)+'\n')
