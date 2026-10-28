import base64, hashlib, json, os, re, shutil, signal, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path('~/.no-mistakes/worktrees/049a88734b0e/01M61WRRBFWGKFM6VM24YW2TYM')
EVIDENCE = Path('~/.no-mistakes/evidence/01M61WRRBFWGKFM6VM24YW2TYM')
LOG = (EVIDENCE / ('live-scheduler-transcript.log' if '--scheduler-only' in sys.argv else ('live-walk-transcript.log' if '--walk-only' in sys.argv else 'live-product-transcript.log'))).open('w', buffering=1)
FIXTURE = Path(tempfile.mkdtemp(prefix='live-phase-', dir=ROOT / '.test-phase-tmp'))
BASE = {k: v for k, v in os.environ.items() if not (k.startswith('FM_') or k in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'TMUX', 'NO_MISTAKES_GATE'))}
BASE['TMPDIR'] = str(FIXTURE)
results = []

def emit(s):
    print(s, flush=True)
    LOG.write(s + '\n')

def run(args, home=None, extra=None, expected=0, timeout=35):
    env = dict(BASE)
    if home:
        env['FM_HOME'] = str(home)
        # No default tmux session can be addressed by best-effort inbox ringing.
        env['TMUX'] = str(home / 'absent-private-lab-socket') + ',0,0'
    if extra:
        env.update(extra)
    emit('$ ' + ' '.join(str(a) for a in args))
    p = subprocess.Popen([str(a) for a in args], cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGTERM)
        out, _ = p.communicate(timeout=10)
        emit(out)
        raise AssertionError('command timed out')
    emit(out.rstrip() if len(out) < 12000 else out[:1200] + f'\n[large public protocol payload: {len(out)} total characters; independently checked below]')
    emit(f'exit={p.returncode}')
    if expected is not None:
        assert p.returncode in (expected if isinstance(expected, tuple) else (expected,)), (args, p.returncode, out)
    return out

def home(name):
    h = FIXTURE / name
    run([ROOT / 'bin/fm-lab-home.sh', 'create', h])
    (h / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (h / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (h / 'state/home-summary.json').write_text('{}\n')
    return h

def axi(h, *args, **kw):
    return run([ROOT / 'bin/fm-tasks-axi.sh', *args], h, **kw)

def watch(h, **extra):
    values = dict(FM_POLL='1', FM_CHECK_INTERVAL='0', FM_SIGNAL_GRACE='0', FM_WATCH_CHECKPOINT_SECONDS='8', FM_HEARTBEAT='999999999', FM_HOME_SUMMARY_INTERVAL='999999999')
    values.update(extra)
    out = run([ROOT / 'bin/fm-watch.sh'], h, values, expected=(0, 75), timeout=25)
    drain = run([ROOT / 'bin/fm-wake-drain.sh'], h)
    ack = re.search(r'WAKE_ACK_REQUIRED:.*?--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)', drain)
    if ack:
        run([ROOT / 'bin/fm-wake-drain.sh', '--ack-through', ack[1], '--recovery-generation', ack[2]], h)
    return out

def decisions(h, task):
    # The status fold is the actual consumer of the persisted decision protocol.
    return run(['bash', '-c', '. bin/fm-classify-lib.sh; status_open_decisions "$1"', '_', h / f'state/{task}.status'], h)

def record(h, corr):
    return dict(line.split('=', 1) for line in (h / f'state/walk-requests/{corr}.record').read_text().splitlines() if '=' in line)

def check(h):
    return run([ROOT / 'bin/fm-walk-request-check.sh', 'check'], h, dict(FM_WALK_REQUEST_DISPATCH=str(ROOT / 'bin/fm-grok-bot-dispatch.sh'), FM_WALK_REQUEST_SEND_BOUND='25'))

def wait_completion(h, corr, walk):
    p = h / f'state/walk-requests/{corr}.{walk}.log'
    for _ in range(100):
        if p.exists() and '__FM_WALK_DISPATCH_EXIT__=' in p.read_text():
            emit('DISPATCH REPORT\n' + p.read_text())
            return p
        time.sleep(.1)
    raise AssertionError('detached dispatcher did not finish')

try:
    emit('Oracle: user intent and recorded decisions: conditions wake once and remain open until disposition; confined UTF-8 briefs <=65536 bytes; dispatcher once-key and durable reply. No mock dispatcher, forge, send command, or ledger is used below.')
    if '--walk-only' not in sys.argv and '--scheduler-only' not in sys.argv:
        h = home('holds')
        axi(h, 'add', 'marker-case', 'Live activation gate', '--repo', 'demo')
        axi(h, 'hold', 'marker-case', '--reason', 'waiting', '--kind', 'external', expected=2)
        axi(h, 'hold', 'marker-case', '--reason', 'waiting', expected=2)
        assert 'held: no' in axi(h, 'show', 'marker-case')
        axi(h, 'hold', 'marker-case', '--reason', 'dated', '--until', '2099-01-01')
        assert not (h / 'state/hold-releases/marker-case').exists()
        results.append('PASS: undated external/kindless hold refused without mutation; dated hold accepted')
        flag = h / 'data/activation'
        axi(h, 'hold', 'marker-case', '--reason', 'activation', '--kind', 'external', '--release-on', 'marker:' + str(flag))
        watch(h)
        assert not (h / 'state/marker-case.status').exists()
        flag.touch()
        out = watch(h)
        assert 'hold condition met: marker-case' in out
        assert 'hold-release-marker-case' in decisions(h, 'marker-case')
        assert 'held: yes' in axi(h, 'show', 'marker-case')
        status_before = (h / 'state/marker-case.status').read_text()
        watch(h)
        assert (h / 'state/marker-case.status').read_text() == status_before
        assert not (h / 'state/.wake-queue').read_text().strip()
        assert 'hold-release-marker-case' in decisions(h, 'marker-case')
        axi(h, 'unhold', 'marker-case')
        assert not decisions(h, 'marker-case').strip()
        assert not (h / 'state/hold-releases/marker-case').exists()
        axi(h, 'hold', 'marker-case', '--reason', 'second episode', '--release-on', 'marker:' + str(flag))
        assert 'hold condition met: marker-case' in watch(h)
        axi(h, 'hold', 'marker-case', '--reason', 'deferred', '--until', '2099-01-01')
        assert not decisions(h, 'marker-case').strip()
        results.append('PASS: real watcher waits for marker, emits one wake per episode, retains held task/open decision, closes on unhold and dated re-hold')
        # Public read-only forge records are independent of the product evaluator.
        run(['gh-axi', 'pr', 'view', '14815', '-R', 'cli/cli'])
        run(['gh-axi', 'pr', 'view', '14858', '-R', 'cli/cli'])
        run(['gh-axi', 'pr', 'view', '14857', '-R', 'cli/cli'])
        for task, pr in [('merged-case', 14815), ('open-case', 14858), ('closed-case', 14857)]:
            axi(h, 'add', task, 'Public PR condition ' + task, '--repo', 'demo')
            axi(h, 'hold', task, '--reason', 'waiting for merge', '--release-on', f'pr:cli/cli#{pr}')
        for _ in range(3):
            watch(h)
        assert 'hold-release-merged-case' in decisions(h, 'merged-case')
        assert not (h / 'state/open-case.status').exists()
        assert not (h / 'state/closed-case.status').exists()
        assert 'held: yes' in axi(h, 'show', 'merged-case')
        axi(h, 'unhold', 'merged-case')
        assert not decisions(h, 'merged-case').strip()
        watch(h, FM_HOLD_RELEASE_GH=str(FIXTURE / 'unavailable-gh'))
        assert not (h / 'state/open-case.status').exists()
        assert not (h / 'state/closed-case.status').exists()
        results.append('PASS: real forge MERGED PR older than 24h wakes and requires disposition; OPEN/CLOSED/unavailable lookup never wake or release')

    m = home('main')
    mate = home('mate')
    (mate / '.fm-secondmate-home').write_text('lab-mate\n')
    (mate / '.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={m}\n')
    (m / 'state/lab-mate.meta').write_text(f'kind=secondmate\nhome={mate}\nbackend=tmux\nwindow=fm-lab-absent:fm-lab-mate\nharness=codex\n')
    run([ROOT / 'bin/fm-walk-request-check.sh', 'arm'], m)
    assert (m / 'state/walk-request.check-trust').exists()
    release = '0123456789abcdef0123456789abcdef01234567'
    body = 'Disposable live walk brief: report the result of this request. Café.\n'.encode()
    body += b'x' * (65536 - len(body))
    corr = 'abcde00000000001'
    # Deliberately use the public remote-style typed input, with no source path available on MAIN.
    line = f'note [corr={corr}]: walk-request: walks=bridge-unavailable brief64={base64.b64encode(body).decode()} release={release} bot=LabWalker\n'
    (mate / 'state/parent-replies.status').write_text(line)
    delta = run([ROOT / 'bin/fm-remote-delta-read.sh', 'state/parent-replies.status', '0', hashlib.sha256(b'').hexdigest(), '0'], mate)
    header, payload = delta.split('\n\n', 1)
    assert 'status=delta' in header
    assert payload == line
    assert 'payload_sha256=' + hashlib.sha256(line.encode()).hexdigest() in header
    (m / 'state/lab-mate.status').write_text(payload)
    results.append('PASS: actual remote delta reader transports an entire maximum-size inline request with matching payload hash')
    if '--scheduler-only' in sys.argv:
        (m / 'state/.secondmate-liveness-tick').touch()
        for _ in range(2):
            watch(m, FM_WALK_REQUEST_DISPATCH=str(ROOT / 'bin/fm-grok-bot-dispatch.sh'), FM_SECONDMATE_LIVENESS_SECS='999999999', FM_WATCH_CHECKPOINT_SECONDS='18')
            if list((m / 'state/lab-mate.inbox').glob('*.msg')):
                break
        assert record(m, corr)['phase'] == 'delivered'
        messages = list((m / 'state/lab-mate.inbox').glob('*.msg'))
        assert len(messages) == 1
        emit('SCHEDULER-DELIVERED INBOX RECORD\n' + messages[0].read_text())
        assert 'Grok Bot bridge not found' in messages[0].read_text()
        run([ROOT / 'bin/fm-walk-request-check.sh', 'disarm'], m)
        emit('PASS: the real watcher authenticates the registered walk-request check, launches the real dispatcher, and returns its outcome through real fm-send')
        sys.exit(0)
    check(m)
    wait_completion(m, corr, 'bridge-unavailable')
    assert (m / f'data/walk-requests/{corr}/brief.md').read_bytes() == body
    check(m)
    assert record(m, corr)['phase'] == 'delivered'
    inbox = list((m / 'state/lab-mate.inbox').glob('*.msg'))
    emit('ACTUAL MATE INBOX\n' + '\n'.join(p.read_text() for p in inbox))
    assert any('Grok Bot bridge not found' in p.read_text() for p in inbox)
    before = len(inbox)
    check(m)
    assert len(list((m / 'state/lab-mate.inbox').glob('*.msg'))) == before
    results.append('PASS: remote-style inline request reaches real dispatcher; missing-bridge failure and report pointer return through real fm-send exactly once')
    corr2 = 'abcde00000000002'
    claim = m / f'state/grok-bot-once/already-sent@{release}'
    claim.mkdir(parents=True)
    (claim / 'sent').write_text('fixture: prior completed dispatch\n')
    with (m / 'state/lab-mate.status').open('a') as f:
        f.write(f'note [corr={corr2}]: walk-request: walks=already-sent brief64={base64.b64encode(body).decode()} release={release} bot=LabWalker\n')
    check(m)
    wait_completion(m, corr2, 'already-sent')
    check(m)
    assert record(m, corr2)['phase'] == 'delivered'
    inbox = list((m / 'state/lab-mate.inbox').glob('*.msg'))
    emit('ACTUAL MATE INBOX AFTER ONCE-KEY\n' + '\n'.join(p.read_text() for p in inbox))
    assert any('already sent' in p.read_text() for p in inbox)
    results.append('PASS: real dispatcher suppresses a previously sent once-key and returns its exit-0 receipt into the mate inbox')
    # Resume persisted interruption states with the real launcher, dispatcher and send path.
    # A missing completion sentinel models a sweep/launcher interrupted before acknowledgement.
    def submit(c, walk):
        with (m / 'state/lab-mate.status').open('a') as f:
            f.write(f'note [corr={c}]: walk-request: walks={walk} brief64={base64.b64encode(body).decode()} release={release} bot=LabWalker\n')
        check(m)
        return wait_completion(m, c, walk)
    def patch_record(c, **fields):
        path = m / f'state/walk-requests/{c}.record'
        rows = record(m, c)
        rows.update(fields)
        path.write_text(''.join(f'{key}={value}\n' for key, value in rows.items()))
    recovery = 'abcde00000000006'
    report = submit(recovery, 'recovery')
    original = report.read_text().split('__FM_WALK_DISPATCH_EXIT__=')[0]
    report.write_text(original)
    os.utime(report, (time.time()-7200, time.time()-7200))
    patch_record(recovery, phase='dispatching', spawned='recovery', delivered='', retried='')
    check(m)
    assert record(m, recovery)['retried'] == 'recovery'
    assert record(m, recovery)['phase'] == 'dispatching'
    wait_completion(m, recovery, 'recovery')
    assert report.read_text().startswith(original)
    check(m)
    assert record(m, recovery)['phase'] == 'delivered'
    messages = [p.read_text() for p in (m / 'state/lab-mate.inbox').glob('*.msg')]
    assert any('walk recovery@' in message and 'Grok Bot bridge not found' in message for message in messages)
    assert not any('recovery exhausted' in message for message in messages)
    emit('RECOVERED DURABLE RECORD\n' + (m / f'state/walk-requests/{recovery}.record').read_text())
    results.append('PASS: seeded stale interrupted-launch state recovers via real launcher, preserves report prefix and delivers actual dispatcher outcome')
    partial = 'abcde00000000007'
    report = submit(partial, 'started')
    patch_record(partial, walks='started,unstarted')
    (m / f'data/walk-requests/{partial}/brief.md').unlink()
    check(m)
    if record(m, partial)['phase'] != 'delivered':
        check(m)
    assert record(m, partial)['phase'] == 'delivered'
    assert set(record(m, partial)['delivered'].split(',')) == {'started', 'unstarted'}
    messages = [p.read_text() for p in (m / 'state/lab-mate.inbox').glob('*.msg')]
    assert any('walk started@' in msg and 'Grok Bot bridge not found' in msg for msg in messages)
    assert any('walk unstarted@' in msg and 'this walk was not dispatched' in msg for msg in messages)
    emit('PARTIAL SWEEP DURABLE RECORD\n' + (m / f'state/walk-requests/{partial}.record').read_text())
    results.append('PASS: interrupted multi-walk state returns the started walk result and refuses only its unstarted sibling after snapshot removal')

    # Invalid inputs actively attempt to cross MAIN's public protocol boundary.
    for index, (name, data) in enumerate([('oversize', b'x' * 65537), ('binary', b'walk\x00secret'), ('invalidutf8', b'\xff')], 3):
        c = f'abcde{index:011x}'
        with (m / 'state/lab-mate.status').open('a') as f:
            f.write(f'note [corr={c}]: walk-request: walks={name} brief64={base64.b64encode(data).decode()} release={release} bot=LabWalker\n')
        check(m)
        assert record(m, c)['phase'] == 'delivered'
        assert '__FM_WALK_DISPATCH_EXIT__=2' in (m / f'state/walk-requests/{c}.{name}.log').read_text()
        assert not (m / f'data/walk-requests/{c}/brief.md').exists()
    # A local private path is rejected by the real mate-side carrier, before channel publication.
    (mate / 'data/walk-briefs').mkdir()
    secret = mate / 'data/walk-briefs/.env'
    secret.write_text('DISPOSABLE_FIXTURE=private\n')
    run([ROOT / 'bin/fm-walk-request.sh', '--brief', secret, '--release', release, '--walks', 'private', '--bot', 'LabWalker'], mate, expected=2)
    assert (m / 'state/lab-mate.status').read_text().count('walks=private') == 0
    emit('FINAL MATE INBOX\n' + '\n'.join(p.read_text() for p in (m / 'state/lab-mate.inbox').glob('*.msg')))
    results.append('PASS: MAIN refuses oversize, binary and invalid UTF-8 inline briefs; mate-side carrier refuses .env without publishing')
    run([ROOT / 'bin/fm-walk-request-check.sh', 'disarm'], m)
    assert not (m / 'state/walk-request.check-trust').exists()
    emit('\n'.join(results))
    (EVIDENCE / 'live-product-results.json').write_text(json.dumps(results, indent=2) + '\n')
finally:
    shutil.rmtree(FIXTURE)
    emit('Disposable fixture removed. No default tmux or Herdr session was started or addressed.')
    LOG.close()
