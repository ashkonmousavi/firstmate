"""Live reply revival: real Firstmate executables and authenticated loopback SSH.

Run from the gate worktree with PYTHONPATH=$PWD/.test-revive/deps.
Only the SSH service is a fixture. It executes the unmodified remote entrypoint,
worker, and readers; injected service stalls never synthesize product responses.
Oracle: the supplied intent requires automatic runner revival. Reply bytes must
arrive exactly once after each failure; unknown probes must preserve the route.
"""
import asyncio
import base64
import ctypes
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import time

import asyncssh

ROOT = Path.cwd()
BASE = ROOT / '.test-revive/live'
EVIDENCE = Path('~/.no-mistakes/evidence/01M6AQWY3FWRRZZ20DDM574R12')
EVENTS = []
PROCS = []
MODE = 'normal'
SERVER = None
PORT = 0
LOOP = None


def record(event, **data):
    entry = dict(at=round(time.monotonic(), 3), event=event, **data)
    EVENTS.append(entry)
    print(json.dumps(entry), flush=True)


async def serve(process):
    args = shlex.split(process.command)
    assert args[0] == 'fm-remote-entrypoint.sh', args
    argv = base64.b64decode(args[-1]).decode().rstrip('\0').split('\0')
    record('ssh-exec', argv=argv, mode=MODE)
    if MODE == 'stalled' and argv[0] == 'fm-remote-secondmate-control.sh':
        # A real authenticated SSH connection which never finishes its command.
        try:
            await process.stdin.read()
            await process.channel.wait_closed()
        except (asyncssh.Error, asyncio.CancelledError):
            pass
        return
    remote_env = dict(os.environ, HOME=str(BASE / 'account'),
                      PATH=str(ROOT / 'bin') + ':/usr/bin:/bin',
                      TMPDIR=str(BASE / 'tmp'),
                      FM_REMOTE_JOB_STATE_ROOT=str(BASE / 'jobs'))
    for key in list(remote_env):
        if key.startswith('FM_') and key != 'FM_REMOTE_JOB_STATE_ROOT':
            remote_env.pop(key)
    child = await asyncio.create_subprocess_exec(
        str(ROOT / 'bin/fm-remote-entrypoint.sh'), *args[1:],
        env=remote_env, stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        start_new_session=True)
    try:
        data = await process.stdin.read()
        out, err = await child.communicate(data.encode())
        process.stdout.write(out.decode())
        process.stderr.write(err.decode())
        process.exit(child.returncode)
        if child.returncode:
            record('ssh-command-exit', argv=argv, code=child.returncode,
                   stderr=err.decode()[-1600:])
    except (asyncssh.Error, asyncio.CancelledError):
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        await child.wait()


async def server_start():
    global SERVER, PORT
    SERVER = await asyncssh.create_server(
        asyncssh.SSHServer, '127.0.0.1', PORT,
        server_host_keys=[str(BASE / 'host-key')],
        authorized_client_keys=str(BASE / 'client-key.pub'),
        process_factory=serve)
    PORT = SERVER.get_port()


async def server_stop():
    SERVER.close()
    await SERVER.wait_closed()


def run(args, timeout=100, env=None):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env or ENV,
                       text=True, capture_output=True, timeout=timeout)
    if p.returncode:
        raise AssertionError(f'{args}: exit={p.returncode}\n{p.stdout}\n{p.stderr}')
    return p.stdout


def wait_for(predicate, label, seconds=35):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.15)
    raise AssertionError('deadline: ' + label)


def claim():
    p = BASE / 'claims/remote-reply-ios.claim'
    try:
        return int(p.read_text().splitlines()[1])
    except (FileNotFoundError, IndexError, ValueError):
        return None


def alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        # Reap killed adopted children; zombies are never a live runner.
        while True:
            c, _ = os.waitpid(-1, os.WNOHANG)
            if not c:
                break
        return Path(f'/proc/{pid}').exists()
    except (ProcessLookupError, ChildProcessError):
        return Path(f'/proc/{pid}').exists()


def owner():
    listing = run([ROOT / 'bin/fm-procevent.sh', 'list'])
    lines = [s.split() for s in listing.splitlines() if s.startswith('remote-reply-ios ')]
    return lines[0][2] if lines else None


def stop_runner(sig):
    pid = claim()
    assert pid and alive(pid), ('no live claim', pid)
    os.killpg(pid, sig)
    wait_for(lambda: not alive(pid), 'runner stopped')
    record('runner-stopped', pid=pid, signal=sig,
           retained_claim=(BASE / 'claims/remote-reply-ios.claim').exists())
    return pid


def watcher(label):
    log = (EVIDENCE / ('watcher-' + label + '.log')).open('w')
    p = subprocess.Popen([str(ROOT / 'bin/fm-watch.sh')], env=ENV,
                         stdout=log, stderr=log, start_new_session=True)
    PROCS.append((p, log))
    return p


def stop_watch(p):
    if p.poll() is None:
        p.terminate()
    code = p.wait(timeout=15)
    record('watcher-exit', pid=p.pid, code=code)
    assert code in (0, -signal.SIGTERM, 128 + signal.SIGTERM), code


def append_and_verify(label):
    line = f'working [at={int(time.time())}]: live-revival-{label}\n'
    with (REMOTE / 'state/parent-replies.status').open('a') as f:
        f.write(line)
    target = HOME / 'state/ios.status'
    wait_for(lambda: target.exists() and line in target.read_text(),
             'remote reply mirrored: ' + label)
    assert target.read_text().count(line) == 1
    record('reply-mirrored-exactly-once', label=label, line=line.strip(),
           owner=owner(), cursor=(HOME / 'state/remote-replies/ios.cursor').read_text())


def check_backstop():
    # Disable external sends. The actual backstop still performs real list and
    # remote reader calls, but any incident remains held inside this lab.
    return run([ROOT / 'bin/fm-main-backstop.py', '--home', HOME,
                '--code-root', ROOT, '--mate', 'ios', '--send-enabled-file',
                HOME / 'config/main-backstop-send-enabled'])


def scenarios():
    global MODE
    # Begin with a genuinely unavailable listener, then restore SSH and let the
    # ordinary watcher (not a hand reconcile) recover it.
    asyncio.run_coroutine_threadsafe(server_stop(), LOOP).result()
    record('ssh-listener-stopped')
    run([ROOT / 'bin/fm-procevent-remote-reply.sh', 'arm', 'ios'])
    p = subprocess.Popen([str(ROOT / 'bin/fm-procevent.sh'), 'start', 'remote-reply-ios'],
                         env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = p.communicate(timeout=30)
    record('unavailable-transport-result', code=p.returncode, stdout=out.strip(), stderr=err.strip())
    assert 'no-result:' in out and '255' in out
    assert (HOME / 'state/procevent/remote-reply-ios.source').exists()
    assert not (HOME / 'state/remote-replies/ios.caught-up').exists()
    asyncio.run_coroutine_threadsafe(server_start(), LOOP).result()
    w = watcher('transport')
    wait_for(lambda: owner() == 'live', 'watcher automatically restarts transport failure')
    append_and_verify('transport-recovery')
    stop_watch(w)

    for label, sig in [('clean-stop', signal.SIGTERM), ('stale-claim', signal.SIGKILL)]:
        old = stop_runner(sig)
        if sig == signal.SIGKILL:
            assert (BASE / 'claims/remote-reply-ios.claim').exists()
        w = watcher(label)
        wait_for(lambda: claim() != old and owner() == 'live', label + ' restarted')
        record('automatic-replacement', label=label, old=old, new=claim())
        append_and_verify(label)
        stop_watch(w)

    # Lost pid hint must not create a dead-owner incident or extend the home
    # owner lease. The claim owner really is the listener started above.
    wait_for(lambda: owner() == 'live', 'live owner before absent-pid check')
    runner = HOME / 'state/procevent/remote-reply-ios.runner'
    runner.unlink(missing_ok=True)
    lease = HOME / 'state/procevent/.owner-lease'
    lease_before = (lease.read_bytes(), lease.stat().st_mtime_ns)
    first = check_backstop()
    second = check_backstop()
    memory = json.loads((HOME / 'state/.main-backstop.json').read_text())
    assert (lease.read_bytes(), lease.stat().st_mtime_ns) == lease_before
    assert 'ios' not in memory.get('runner_fails', {})
    assert 'runner-ios' not in memory.get('episodes', {})
    record('live-claim-without-pid-hint', first=first.strip(), second=second.strip(),
           runner_fails=memory.get('runner_fails', {}), episodes=memory.get('episodes', {}),
           owner_lease_unchanged=True)

    # Actual death must be detected, deduplicated, and cleared after recovery.
    old = stop_runner(signal.SIGTERM)
    check_backstop()
    memory = json.loads((HOME / 'state/.main-backstop.json').read_text())
    assert 'ios' in memory['runner_fails'] and 'runner-ios' not in memory['episodes']
    second = check_backstop()
    memory = json.loads((HOME / 'state/.main-backstop.json').read_text())
    assert 'runner-ios' in memory['episodes']
    episode = memory['episodes']['runner-ios']
    third = check_backstop()
    assert json.loads((HOME / 'state/.main-backstop.json').read_text())['episodes']['runner-ios'] == episode
    record('dead-owner-two-pass-alarm', second=second.strip(), third=third.strip(), episode=episode)

    # Force a real remote state and observe connection to stall. Recovery must
    # precede the hop; deadlines must preserve metadata and pending expectation.
    meta = HOME / 'state/ios.meta'
    meta.write_text('kind=secondmate\nwindow=fm-lab-revive:p1\nbackend=herdr\nharness=claude\nremote_host=revive-lab\nhome=' + str(REMOTE) + '\n')
    saved_meta = meta.read_bytes()
    script = '''. "$1/bin/fm-pending-reply-lib.sh"
c=$(fm_pending_reply_create "$FM_HOME" "$FM_HOME/state" ios "Please report the recovery result")
fm_pending_reply_mark_delivered "$FM_HOME/state" "$c"
printf '%s' "$c"
'''
    corr = run(['bash', '-c', script, 'create', ROOT]).strip()
    pending = HOME / 'state/pending-replies' / corr
    assert pending.exists(), (corr, list(pending.parent.glob('*')))
    # Prior watcher scenarios have stamped the normal 60-second liveness
    # cadence. Make the adversarial probe due on this scenario's first cycle.
    (HOME / 'state/.secondmate-liveness-tick').unlink(missing_ok=True)
    MODE = 'stalled'
    started = time.monotonic()
    w = watcher('stalled-probes')
    wait_for(lambda: claim() != old and owner() == 'live', 'recovery before stalled probes', 15)
    restart_time = time.monotonic() - started
    append_and_verify('stalled-probes')
    wait_for(lambda: any(e['event'] == 'ssh-exec' and e.get('mode') == 'stalled' and e.get('argv', [])[:2] == ['fm-remote-secondmate-control.sh', 'state'] for e in EVENTS),
             'observe bound completed; state probe started', 35)
    wait_for(lambda: (HOME / 'state/.watch-triage.log').exists() and
             'route preserved' in (HOME / 'state/.watch-triage.log').read_text(),
             'state bound preserves route', 40)
    text = pending.read_text()
    assert 'phase=awaiting_report' in text and 'turn_seen_busy=0' in text
    assert 'request_turn_completed_epoch=\n' in text
    assert meta.read_bytes() == saved_meta
    record('stalled-probes-preserve-state', revival_seconds=round(restart_time, 2),
           elapsed=round(time.monotonic() - started, 2), pending=text,
           triage=(HOME / 'state/.watch-triage.log').read_text())
    MODE = 'normal'
    stop_watch(w)
    check_backstop()
    memory = json.loads((HOME / 'state/.main-backstop.json').read_text())
    assert 'ios' not in memory.get('runner_fails', {})
    assert 'runner-ios' not in memory.get('episodes', {})
    record('recovery-clears-backstop-incident')


async def main():
    global HOME, REMOTE, ENV, LOOP
    ctypes.CDLL(None).prctl(36, 1, 0, 0, 0)  # subreap disposable descendants
    os.umask(0o022)
    BASE.mkdir(parents=True)
    for name in ['tmp', 'account', 'claims']:
        (BASE / name).mkdir(mode=0o700)
    HOME = BASE / 'parent'
    REMOTE = BASE / 'remote'
    for home in [HOME, REMOTE]:
        subprocess.run([str(ROOT / 'bin/fm-lab-home.sh'), 'create', str(home)], check=True)
        (home / 'state').chmod(0o700)
    # The remote protocol requires nonoverlapping root/home. Materialize the
    # exact tracked product under a sibling disposable root; no source edits.
    code = BASE / 'remote-code'
    code.mkdir()
    shutil.copytree(ROOT / 'bin', code / 'bin')
    shutil.copy2(ROOT / 'AGENTS.md', code / 'AGENTS.md')
    subprocess.run(['git', 'init', '-q', str(code)], check=True)
    subprocess.run(['git', '-C', str(code), 'add', 'bin', 'AGENTS.md'], check=True)
    (HOME / 'data/secondmates.md').write_text(f'- ios - lab recovery (host: revive-lab; root: {code}; home: {REMOTE}; scope: lab; projects: alpha; added 2026-10-31)\n')
    (REMOTE / 'state/parent-replies.status').touch()
    for name in ['host-key', 'client-key']:
        key = asyncssh.generate_private_key('ssh-ed25519')
        key.write_private_key(str(BASE / name))
        (BASE / name).chmod(0o600)
        key.write_public_key(str(BASE / (name + '.pub')))
    LOOP = asyncio.get_running_loop()
    await server_start()
    config = BASE / 'ssh-config'
    config.write_text(f'Host revive-lab\n HostName 127.0.0.1\n Port {PORT}\n User lab\n IdentityFile {BASE}/client-key\n IdentitiesOnly yes\n UserKnownHostsFile {BASE}/known-hosts\n StrictHostKeyChecking yes\n BatchMode yes\n ConnectTimeout 3\n')
    (BASE / 'known-hosts').write_text(f'[127.0.0.1]:{PORT} ' + (BASE / 'host-key.pub').read_text())
    ssh = BASE / 'ssh'
    ssh.write_text('#!/bin/bash\nexec /usr/bin/ssh -F ' + shlex.quote(str(config)) + ' "$@"\n')
    ssh.chmod(0o700)
    ENV = dict(os.environ, FM_HOME=str(HOME), FM_SSH_BIN=str(ssh),
               FM_PROCEVENT_CLAIM_ROOT=str(BASE / 'claims'),
               TMPDIR=str(BASE / 'tmp'), FM_REMOTE_REPLY_WAIT_SECONDS='3',
               FM_PROCEVENT_LAUNCH_FLOOR_SECONDS='1', FM_POLL='1',
               FM_BACKEND='tmux', FM_HOME_SUMMARY_INTERVAL='86400')
    for key in ['FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE',
                'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_GATE_REFUSE_BYPASS']:
        ENV.pop(key, None)
    record('lab-started', port=PORT, home=str(HOME), remote_root=str(code))
    try:
        await asyncio.to_thread(scenarios)
        record('all-live-scenarios-passed')
    finally:
        for p, log in PROCS:
            if p.poll() is None:
                p.terminate()
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
            log.close()
        subprocess.run([str(ROOT / 'bin/fm-procevent.sh'), 'sweep-home'], env=ENV,
                       capture_output=True, timeout=30)
        worker = BASE / 'jobs/worker.pid'
        if worker.exists():
            subprocess.run(['bash', '-c', '. "$1/bin/fm-remote-job-lib.sh"; fm_remote_job_stop_worker_tree "$2"',
                            'stop', str(ROOT), worker.read_text().strip()], env=ENV,
                           capture_output=True, timeout=30)
        await server_stop()
        # Subreaping contains helpers detached by the real product. Reap only
        # this test driver's own descendant tree, never a host-wide pid match.
        for attempt in range(40):
            children = set()
            for task in Path('/proc/self/task').iterdir():
                children.update(int(p) for p in (task / 'children').read_text().split())
            if not children:
                break
            for pid in children:
                try:
                    os.kill(pid, signal.SIGTERM if attempt < 20 else signal.SIGKILL)
                except ProcessLookupError:
                    pass
            while True:
                try:
                    pid, _ = os.waitpid(-1, os.WNOHANG)
                    if not pid:
                        break
                except ChildProcessError:
                    break
            await asyncio.sleep(.1)
        remaining = set()
        for task in Path('/proc/self/task').iterdir():
            remaining.update((task / 'children').read_text().split())
        assert not remaining, ('unreaped test children', remaining)
        record('all-disposable-children-reaped')
        (EVIDENCE / 'live-events.json').write_text(json.dumps(EVENTS, indent=2) + '\n')
        for path in ['state/ios.status', 'state/remote-replies/ios.cursor', 'state/.main-backstop.json', 'state/.main-backstop.log', 'state/.watch-triage.log']:
            p = HOME / path
            if p.exists():
                shutil.copy2(p, EVIDENCE / ('live-' + p.name.lstrip('.')))
        # Retain only evidence, never the lab keys, local dependency binaries,
        # temporary fixture homes, or nested git index.
        shutil.rmtree(BASE)
        record('lab-removed')


if __name__ == '__main__':
    asyncio.run(main())
