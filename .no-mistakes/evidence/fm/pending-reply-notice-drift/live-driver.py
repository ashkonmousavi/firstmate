import json, os, pathlib, shutil, signal, subprocess, time

ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path(__file__).parent
LAB = ROOT / '.l'
assert not LAB.exists()
env = {k: v for k, v in os.environ.items()
       if not k.startswith(('FM_', 'HERDR_', 'REX_')) and k not in ('TMUX', 'TERM_PROGRAM')}
env.update(FM_HOME=str(LAB), FM_BACKEND='tmux', FM_POLL='1', FM_SIGNAL_GRACE='0',
           TMUX_TMPDIR=str(LAB / 'tmux'), TERM='xterm-256color')
transcript = open(EVIDENCE / 'live-product.log', 'w', buffering=1)
watcher = None
watchlog = None
watcher_ttl = None
watcher_number = 0
watcher_restarts = 0
results = []

def run(args, extra=None, check=True, timeout=45):
    e = env | (extra or {})
    p = subprocess.run(list(map(str, args)), env=e, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=timeout)
    transcript.write('$ ' + ' '.join(map(str, args)) + '\n' + p.stdout + f'\nexit={p.returncode}\n')
    if check and p.returncode:
        raise RuntimeError(f'{args}: exit {p.returncode}: {p.stdout}')
    return p

def records():
    out = {}
    for p in (LAB / 'state/pending-replies').glob('*'):
        if p.is_file() and not p.name.startswith('.'):
            out[p.name] = dict(line.split('=', 1) for line in p.read_text().splitlines() if '=' in line)
    return out

def wait_for(test, seconds=35):
    global watcher_restarts
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if test(): return
        if watcher is not None and watcher.poll() is not None:
            rc = watcher.returncode
            ttl = watcher_ttl
            stop_watcher()
            assert rc == 0, f'watcher failed: {rc}'
            watcher_restarts += 1
            assert watcher_restarts <= 5, 'too many watcher wakes'
            start_watcher(ttl)
        time.sleep(.2)
    raise AssertionError('Timed out waiting for expected persisted product state')

def send(name, message):
    before = set(records())
    run([ROOT / 'bin/fm-send.sh', 'labmate', message])
    after = records()
    added = set(after) - before
    assert len(added) == 1, added
    corr = added.pop()
    assert after[corr]['delivered_epoch'], after[corr]
    transcript.write(f'{name}: delivered corr={corr}\n' + json.dumps(after[corr], indent=2) + '\n')
    return corr

def start_watcher(ttl=None):
    global watcher, watchlog, watcher_ttl, watcher_number
    watcher_number += 1
    watcher_ttl = ttl
    watchlog = open(EVIDENCE / f'watcher-{watcher_number}.log', 'w')
    e = env.copy()
    if ttl is not None: e['FM_PENDING_REPLY_ONEWAY_TTL'] = str(ttl)
    watcher = subprocess.Popen([str(ROOT / 'bin/fm-watch.sh')], env=e,
                               stdout=watchlog, stderr=subprocess.STDOUT, start_new_session=True)
    transcript.write(f'Started real fm-watch.sh pid={watcher.pid}, TTL={ttl or "default 7200"}\n')

def stop_watcher():
    global watcher, watchlog
    if watcher is None: return
    try: os.killpg(watcher.pid, signal.SIGTERM)
    except ProcessLookupError: pass
    try: rc = watcher.wait(timeout=15)
    except subprocess.TimeoutExpired:
        os.killpg(watcher.pid, signal.SIGKILL)
        rc = watcher.wait(timeout=5)
        raise RuntimeError('Watcher did not stop within teardown bound')
    transcript.write(f'Watcher stopped and reaped, exit={rc}\n')
    watcher = None
    watchlog.close()

try:
    run([ROOT / 'bin/fm-lab-home.sh', 'create', LAB])
    (LAB / 'tmux').mkdir()
    mate = LAB / 'mate'
    (mate / 'state').mkdir(parents=True)
    (mate / '.fm-secondmate-home').write_text('labmate\n')
    (mate / '.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={LAB}\n')
    # A real terminal is the external endpoint; no model response is required
    # by these scenarios. The sender's documented durable inbox is delivery.
    run(['tmux', '-L', 'fm-lab', 'new-session', '-d', '-s', 'lab', '-n', 'fm-labmate',
         '-x', '120', '-y', '40', '-c', ROOT, 'cat'])
    socket = run(['tmux', '-L', 'fm-lab', 'display-message', '-p', '#{socket_path}']).stdout.strip()
    env['TMUX'] = f'{socket},0,0'
    (LAB / 'state/labmate.meta').write_text(
        f'window=lab:fm-labmate\nendpoint_task_id=labmate\nbackend=tmux\n'
        f'worktree={mate}\nproject={mate}\nharness=terminal\nkind=secondmate\n'
        f'mode=secondmate\nyolo=off\nhome={mate}\nprojects=lab\n')
    constants = run(['bash', '-c', '. bin/fm-secondmate-nudge-lib.sh; printf "%s\\n%s\\n" "$FM_SECOND_MATE_NUDGE_MESSAGE" "$FM_REMOTE_SECOND_MATE_NUDGE_MESSAGE"']).stdout.splitlines()
    stock, remote = constants
    local = send('stock local update notice', stock)
    old = send('previous supported update wording', stock.replace('firstmate was updated', 'firstmate updated', 1))
    requests = []
    for suffix in (' Is that clear?', ' Please report the result.', ' Reply with the result.',
                   ' Respond with the result.', ' Please investigate the failure.'):
        requests.append(send('reply-bearing suffix' + suffix, stock + suffix))
    inherited = send('stock inherited-material notice', remote)
    config = send('CONFIG_REREAD pointer', f'CONFIG_REREAD: {mate}/instructions.md')
    (EVIDENCE / 'before-watcher.json').write_text(json.dumps(records(), indent=2))
    start_watcher()
    wait_for(lambda: all(records()[c]['phase'] == 'resolved' for c in (local, old)))
    first = records()
    for c in (local, old):
        assert first[c]['resolved_via'] == 'one-way-notice'
        assert int(first[c]['resolved_epoch']) - int(first[c]['created_epoch']) < 120
        assert not first[c]['recovery_attempted_epoch'] and not first[c]['escalated_epoch']
    for c in requests:
        assert first[c]['phase'] == 'awaiting_report' and first[c].get('one_way', '') == ''
    for c in (inherited, config): assert first[c]['phase'] == 'awaiting_report'
    results.append('PASS: stock local notice and previous wording retire on first watcher reconciliation, before default TTL, with no report')
    results.append('PASS: question/report/reply/respond/investigate suffixes retain delivered awaiting_report records')
    (EVIDENCE / 'after-default-watcher.json').write_text(json.dumps(first, indent=2))
    run([ROOT / 'bin/fm-secondmate-report.sh', 'done', requests[0], 'The requested check is complete.'], {'FM_HOME': str(mate)})
    wait_for(lambda: records()[requests[0]]['phase'] == 'resolved')
    assert records()[requests[0]]['resolved_via'] in ('status', 'helper')
    results.append('PASS: a genuine correlated helper report resolves the question request')
    time.sleep(2)
    assert all(records()[c]['phase'] == 'resolved' for c in (local, old))
    stop_watcher()
    start_watcher(ttl=1)
    wait_for(lambda: all(records()[c]['phase'] == 'resolved' for c in (inherited, config)))
    final = records()
    for c in (inherited, config): assert final[c]['resolved_via'] == 'expired-one-way'
    for c in requests[1:]: assert final[c]['phase'] == 'awaiting_report'
    results.append('PASS: stock inherited-material notice and CONFIG_REREAD expire through the supported TTL; explicit local update requests remain open')
    (EVIDENCE / 'after-short-ttl-watcher.json').write_text(json.dumps(final, indent=2))
    run(['tmux', '-L', 'fm-lab', 'capture-pane', '-p', '-t', 'lab:fm-labmate'])
    inbox_files = sorted((LAB / 'state/labmate.inbox').glob('*.msg'))
    (EVIDENCE / 'delivered-inbox.txt').write_text('\n\n'.join(p.read_text() for p in inbox_files))
    (EVIDENCE / 'parent-status.txt').write_text((LAB / 'state/labmate.status').read_text())
    transcript.write('\n'.join(results) + '\n')
    (EVIDENCE / 'live-results.json').write_text(json.dumps({'results': results, 'messages': len(inbox_files)}, indent=2))
finally:
    try:
        stop_watcher()
    finally:
        try:
            if (LAB / 'tmux').exists():
                run(['tmux', '-L', 'fm-lab', 'kill-server'])
                p = run(['tmux', '-L', 'fm-lab', 'list-sessions'], check=False)
                assert p.returncode != 0, 'private tmux server is still live'
        finally:
            if LAB.exists(): shutil.rmtree(LAB)
            assert not LAB.exists()
            transcript.write('Disposable terminal and lab home removed.\n')
            transcript.close()
