"""Run the real backstop CLI/readers/inbox with disposable files and processes.
The fm-on adapter replaces SSH with local execution of genuine remote readers.
Herdr is explicitly unavailable: this driver never claims real nudge proof.
"""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time

ROOT = Path.cwd()
spec = importlib.util.spec_from_file_location('backstop', ROOT / 'bin/fm-main-backstop.py')
backstop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backstop)

def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)

with tempfile.TemporaryDirectory(dir=ROOT / '.test-backstop-tmp', prefix='manual-') as tmp:
    base = Path(tmp)
    home, remote, code, tools = [base / x for x in ('home', 'remote', 'code', 'tools')]
    subprocess.run([str(ROOT / 'bin/fm-lab-home.sh'), 'create', str(home)], check=True)
    for path in (remote / 'state', code / 'bin', tools):
        path.mkdir(parents=True)
    executable(code / 'bin/fm-inbox.sh', '#!/bin/sh\nexec ' + shlex.quote(str(ROOT / 'bin/fm-inbox.sh')) + ' "$@"\n')
    executable(code / 'bin/fm-on.sh', '#!/bin/sh\nshift\ncommand=$1\nshift\ncase "$command" in fm-remote-file.sh|fm-remote-delta-read.sh) ;; *) exit 64;; esac\nexec env FM_HOME=' + shlex.quote(str(remote)) + ' ' + shlex.quote(str(ROOT / 'bin')) + '/"$command" "$@"\n')
    executable(tools / 'herdr', '#!/bin/sh\necho "Herdr lab unavailable: prepare tripwire refused; no default session" >&2\nexit 1\n')
    env = dict(os.environ, FM_HOME=str(home), PATH=str(tools) + ':' + os.environ['PATH'])
    for key in list(env):
        if key.startswith('FM_') and key.endswith('_OVERRIDE'):
            env.pop(key)
    state = home / 'state'
    source = remote / 'state/parent-replies.status'
    mirrored = state / '.remote-reply-mirrored-lab'
    source.write_bytes(b'working [at=1000]: baseline\n')
    mirrored.write_text('working [at=1000]: baseline\n')
    (state / '.last-watcher-beat').touch()

    def drive(label, mate=True):
        args = ['python3', str(ROOT / 'bin/fm-main-backstop.py'), '--home', str(home), '--code-root', str(code)]
        if mate:
            args += ['--mate', 'lab']
        out = subprocess.run(args, env=env, capture_output=True, text=True, timeout=30)
        print('\n### ' + label + '\n' + out.stdout, flush=True)
        assert out.returncode == 0, out.stderr
        return json.loads((state / '.main-backstop.json').read_text())

    def notes():
        return '\n'.join(p.read_text() for p in (state / 'inbox').glob('*.note'))

    def count():
        return len(list((state / 'inbox').glob('*.note')))

    def caught_up():
        mirrored.write_bytes(source.read_bytes())
        drive('healthy observation clears incidents')

    memory = drive('healthy watcher and caught-up replies')
    assert count() == 0
    if os.environ.get('BACKSTOP_BOUNDARY_ONLY') == '1':
        source.write_text('done [at=1900]: exact boundary\n')
        drive('exact fifteen-minute delivery lag stays quiet')
        assert count() == 0
        (state / 'work.meta').touch()
        os.utime(state / '.last-watcher-beat', (time.time() - 299,) * 2)
        drive('watcher silence below five-minute threshold stays quiet', mate=False)
        assert count() == 0
        os.utime(state / '.last-watcher-beat', (time.time() - 600,) * 2)
        (state / '.afk').touch()
        drive('away marker suppresses silent-watcher recovery', mate=False)
        assert count() == 0
        print('PASS: exact delivery-lag threshold, watcher silence threshold, and away suppression.', flush=True)
        raise SystemExit(0)
    with source.open('ab') as out:
        out.write('done [at=1901]: café\r\n'.encode())
    memory = drive('UTF-8 CRLF delta produces exact 901-second lag')
    assert 'REPLY DELIVERY LAG lab: 901s' in notes()
    assert memory['readers']['lab']['offset'] == source.stat().st_size
    incident = memory['episodes']['lag-lab']
    before = count()
    source.rename(source.with_suffix('.missing'))
    drive('first actual missing-file read is tolerated')
    memory = drive('second missing-file read alarms durably')
    assert 'REPLY DELIVERY UNVERIFIED lab' in notes()
    assert memory['episodes']['lag-lab'] == incident
    source.with_suffix('.missing').rename(source)
    memory = drive('read recovery preserves unresolved lag incident')
    assert memory['episodes']['lag-lab'] == incident
    assert count() == before + 1
    caught_up()

    source.write_bytes(b'working [at=1000]: old\n' * 60000 + 'done [at=3000]: café\n'.encode())
    memory = drive('replaced oversized log bootstraps its actual UTF-8 tail')
    assert memory['readers']['lab']['offset'] == source.stat().st_size
    assert memory['readers']['lab']['stamp'] == 3000
    assert 'REPLY DELIVERY LAG lab: 1099s' in notes()
    caught_up()
    with source.open('ab') as out:
        out.write(b'working [at=3200]: backlog\n' * 22000 + b'done [at=5000]: latest\n')
    memory = drive('over-budget backlog retains progress without claiming tail')
    assert 'lab' in memory['read_fails']
    memory = drive('second incomplete scan becomes unverified')
    assert 'read-lab' in memory['episodes']
    memory = drive('bounded subsequent scan reaches tail and reports exact lag')
    assert memory['readers']['lab']['stamp'] == 5000
    assert 'lab' not in memory['read_fails']
    assert 'REPLY DELIVERY LAG lab: 2000s' in notes()
    caught_up()

    pe = state / 'procevent'
    pe.mkdir()
    (pe / 'remote-reply-lab.source').touch()
    record = pe / 'remote-reply-lab.runner'
    record.write_text('999999999\n')
    before = count()
    drive('first dead-runner pass tolerated')
    assert count() == before
    memory = drive('second dead-runner pass alarms')
    assert 'runner-lab' in memory['episodes']
    runner = subprocess.Popen(['python3', '-c', 'import time; time.sleep(60)', '_start', 'remote-reply-lab'])
    try:
        record.write_text(str(runner.pid) + '\n')
        memory = drive('real matching process clears dead-runner incident')
        assert 'runner-lab' not in memory['episodes']
    finally:
        runner.terminate()
        runner.wait(timeout=3)

    (pe / 'remote-reply-lab.source').unlink()
    (state / 'work.meta').touch()
    os.utime(state / '.last-watcher-beat', (time.time() - 600,) * 2)
    memory = drive('silent watcher durably reports unavailable recovery', mate=False)
    assert 'recovery' in memory['episodes']
    assert 'BACKSTOP FAILURE' in (state / '.wake-queue').read_text()
    (state / 'work.meta').unlink()
    drain = subprocess.run([str(ROOT / 'bin/fm-wake-drain.sh')], env=env, capture_output=True, text=True, timeout=20)
    assert drain.returncode == 0, drain.stderr
    assert 'BACKSTOP FAILURE' in drain.stdout
    print('\n### Actual wake-drain output\n' + drain.stdout, flush=True)
    print('\n### Durable notes\n' + notes(), flush=True)

    for function in (backstop.run, backstop.run_status):
        pidfile = base / ('child-' + function.__name__)
        command = ['bash', '-c', 'sleep 120 & echo $! > "$1"; wait', 'cleanup-proof', str(pidfile)]
        started = time.monotonic()
        try:
            function(command, env)
            raise AssertionError('hung command incorrectly succeeded')
        except backstop.ProbeError:
            pass
        elapsed = time.monotonic() - started
        pid = int(pidfile.read_text())
        proc = Path('/proc') / str(pid) / 'stat'
        try:
            status = proc.read_text().split(') ', 1)[1].split()[0]
        except FileNotFoundError:
            status = 'absent'
        assert status in ('Z', 'absent'), status
        assert 14 < elapsed < 19, elapsed
        print('### %s: one timed-out attempt, %.2fs, descendant=%s' % (function.__name__, elapsed, status), flush=True)
    print('PASS: real backstop CLI, file/delta readers, durable inbox/wake drain, runner processes, timeout cleanup; SSH and Herdr delivery not proven.', flush=True)
