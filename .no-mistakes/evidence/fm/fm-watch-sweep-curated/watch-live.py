import json, os, pathlib, shlex, shutil, signal, subprocess, tempfile, time

ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path(__file__).parent
results = []
transcript = []

def record(text):
    transcript.append(text)
    print(text, flush=True)

def scenario(name, checks, expected, *, fallback=False, quiet=False, watcher=None, old=False):
    lab = pathlib.Path(tempfile.mkdtemp(prefix='.watch-live-', dir=ROOT))
    env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI', 'HERDR_', 'TMUX', 'XDG_'))}
    env.update(HOME=str(lab), FM_HOME=str(lab), FM_POLL='1', FM_CHECK_INTERVAL='300',
               FM_CHECK_TIMEOUT='1', FM_HEARTBEAT='999999', TMPDIR=str(lab),
               TMUX=str(lab / 'private-tmux-socket') + ',0,0', TMUX_TMPDIR=str(lab),
               XDG_CONFIG_HOME=str(lab / 'config'), XDG_CACHE_HOME=str(lab / 'cache'))
    if fallback:
        env['FM_CHECK_FORCE_FALLBACK'] = '1'
    process = None
    try:
        subprocess.run(['bin/fm-lab-home.sh', 'create', str(lab)], env=env, check=True, capture_output=True, text=True)
        record('\nSCENARIO: ' + name)
        for check_id, body, register in checks:
            path = lab / 'state' / (check_id + '.check.sh')
            path.write_text('#!/usr/bin/env bash\n' + body + '\n')
            path.chmod(0o700)
            if register:
                reg = subprocess.run(['bin/fm-check-register.sh', check_id], env=env, capture_output=True, text=True)
                record('$ bin/fm-check-register.sh ' + check_id + '\n' + reg.stdout + reg.stderr)
                assert reg.returncode == 0
        started = time.monotonic()
        command = [str(watcher or ROOT / 'bin/fm-watch.sh')]
        record('$ FM_HOME=<disposable lab> FM_CHECK_TIMEOUT=1 FM_CHECK_INTERVAL=300 ' + command[0])
        process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        if quiet:
            deadline = started + 20
            while not (lab / 'state/.last-check').exists():
                assert process.poll() is None, 'quiet watcher exited before completing sweep'
                assert time.monotonic() < deadline, 'quiet sweep never completed'
                time.sleep(.1)
            time.sleep(2.3)
            assert process.poll() is None, 'quiet check unexpectedly woke watcher'
            process.terminate()
        out, err = process.communicate(timeout=30)
        elapsed = time.monotonic() - started
        record('exit=' + str(process.returncode) + ' elapsed=' + format(elapsed, '.2f') + 's\nstdout:\n' + out + 'stderr:\n' + err)
        trace_path = lab / 'trace'
        trace = trace_path.read_text().splitlines() if trace_path.exists() else []
        queue_path = lab / 'state/.wake-queue'
        queue = queue_path.read_text() if queue_path.exists() else ''
        record('check execution trace: ' + json.dumps(trace))
        record('durable wake queue:\n' + queue)
        if old:
            assert trace == ['early'], 'base did not reproduce expected starvation'
            assert 'disk-full' not in queue
            record('BASELINE REPRODUCED: early check exits the sweep; quiet and later printing checks never run.')
        else:
            assert trace == expected, (trace, expected)
            assert (lab / 'state/.last-check').exists()
            if quiet:
                assert out == '' and queue == ''
                assert process.returncode == -signal.SIGTERM
            else:
                assert process.returncode == 0
                assert len(out.splitlines()) == 1, 'expected exactly one wake headline'
                rows = [row.split('\t') for row in queue.splitlines()]
                assert len(rows) == 2, rows
                assert all(row[2] == 'check' for row in rows)
                if 'rejected' in name:
                    assert 'unauthenticated-state-checks' in queue
                    assert 'disk-full' in queue
                    assert not (lab / 'unauthorized-ran').exists()
                else:
                    assert 'memory-low' in queue and 'disk-full' in queue
                if 'timeout' in name:
                    assert elapsed < 10, 'per-check deadline did not bound the sweep'
                    assert not (lab / 'escaped-timeout').exists()
                    pid = int((lab / 'slow.pid').read_text())
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        pass
                    else:
                        raise AssertionError('timed-out check remains alive: ' + str(pid))
                drain = subprocess.run(['bin/fm-wake-drain.sh'], env=env, capture_output=True, text=True, timeout=20)
                record('$ bin/fm-wake-drain.sh\nexit=' + str(drain.returncode) + '\n' + drain.stdout + drain.stderr)
                assert drain.returncode == 0
                assert 'disk-full' in drain.stdout
                if 'rejected' not in name:
                    assert 'memory-low' in drain.stdout
            record('PASS: ' + name)
        results.append(dict(name=name, result='pass', baseline=old, elapsed=round(elapsed, 2)))
    except Exception as exc:
        record('FAIL: ' + repr(exc))
        results.append(dict(name=name, result='fail', error=repr(exc)))
        raise
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
        shutil.rmtree(lab)
        (EVIDENCE / 'watch-live.log').write_text('\n'.join(transcript) + '\n')
        (EVIDENCE / 'watch-live-results.json').write_text(json.dumps(results, indent=2) + '\n')

early = 'printf "early\\n" >> "$FM_HOME/trace"\nprintf "memory-low\\n"'
quiet_check = 'printf "quiet\\n" >> "$FM_HOME/trace"\n[ ! -e "$FM_HOME/state/.last-check" ] || exit 55'
late = 'printf "late\\n" >> "$FM_HOME/trace"\nprintf "disk-full\\n"'
checks = [('a-news', early, True), ('b-quiet', quiet_check, True), ('c-news', late, True)]

try:
    scenario('printing checks both queue before one wake, including intervening quiet check', checks, ['early', 'quiet', 'late'])
    slow = 'printf "slow\\n" >> "$FM_HOME/trace"\nprintf "%s\\n" "$$" > "$FM_HOME/slow.pid"\nsleep 12\ntouch "$FM_HOME/escaped-timeout"'
    for fallback in (False, True):
        scenario('per-check timeout preserves later results (' + ('Perl fallback' if fallback else 'native timeout') + ')',
                 [('a-news', early, True), ('b-slow', slow, True), ('c-news', late, True)],
                 ['early', 'slow', 'late'], fallback=fallback)
    scenario('rejected unsigned check cannot execute or prevent later valid check',
             [('a-unsigned', 'touch "$FM_HOME/unauthorized-ran"', False), ('c-news', late, True)], ['late'])
    scenario('all-quiet sweep updates cadence, stays silent, and does not rerun early',
             [('b-quiet', quiet_check, True)], ['quiet'], quiet=True)
    base = ROOT / 'bin/.fm-watch-before-live.sh'
    try:
        base.write_bytes(subprocess.run(['git', 'show', 'afeb0d3b58c5d5f892949edd6e3d0b3f98129407:bin/fm-watch.sh'], check=True, capture_output=True).stdout)
        base.chmod(0o700)
        scenario('pre-fix watcher reproduces starvation with identical checks', checks, ['early'], watcher=base, old=True)
    finally:
        base.unlink(missing_ok=True)
finally:
    record('\nAll disposable homes and watcher children cleaned up.')
    (EVIDENCE / 'watch-live.log').write_text('\n'.join(transcript) + '\n')
