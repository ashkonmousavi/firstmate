#!/usr/bin/env python3
"""Linux cron backstop for Herdr primary wake delivery, independent of the watcher.

Usage: fm-main-backstop.py --home PATH [--code-root PATH] [--mate ID ...]
Run every three minutes. After a five-minute watcher silence with supervision
work and no state/.afk record, discover a unique live Claude/Codex primary in
this exact home and nudge it so its own turn-end owner re-arms.
Successful nudges are at least five minutes apart.
Never launches or kills an agent/watcher,
never types into a shell, and never treats data/main-pane as authority.
A failed discovery/send, a registered reply runner read as not alive on two
consecutive passes, remote/local timestamp reads failing on two consecutive
passes, or reply lag above fifteen
minutes becomes a durable fm-inbox note and check wake, visible at the next
drain even when no watcher/pane is alive.
Only explicitly supplied --mate ids are monitored.
Reply lag compares remote at= stamps with state/.remote-reply-mirrored-<mate>;
local status notices cannot advance that ingestion watermark, and a missing
or empty watermark counts as zero.
Reply monitoring remains active during .afk.
Remote reads use only existing fm-on read paths: one bounded fm-remote-file
get bootstraps a delta cursor, then fm-remote-delta-read returns only appended
lines. A moved log re-reads its current tail, and a source already past the
whole-file transfer bound is bootstrapped through the delta path alone.
A delta scan must reach the current tail within four reads; exhausting that
budget counts as a failed read while preserving cursor progress for the next
pass, never reporting an intermediate timestamp as current. Delta reads allow one
reply-runner poll window in the shared remote job lane (ninety seconds); other
commands keep fifteen seconds. Output bodies are never logged. A read failing
on two consecutive passes alarms instead of claiming caught-up; a single
failed pass is audited as transport noise. A live runner removes its .runner
pid record while it applies each captured reply and rewrites it by
truncate-then-write on every poll, so an empty record is re-read briefly and a
runner read as not alive on a single pass is audited as transient. No remote
source is changed or live runner reconciled.
Notes deduplicate for an incident until a healthy observation clears it.
Runner identity requires Linux /proc process state and command-line records.
Private state: .main-backstop.json (incident ids, successful nudge time,
delta cursors and consecutive failure records),
.main-backstop.lock (cron exclusion), .main-backstop.log (bounded audit).
The caller deploys/backs up its private files and supplies the home's code root.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import uuid


class ProbeError(Exception):
    pass


TRANSFER_BOUND = 1048576  # fm-remote-file.sh's hard whole-file ceiling
DELTA_LOG = 'state/parent-replies.status'
DELTA_WAIT = '0'  # never block: a cron pass must stay bounded
DELTA_CHUNK = 65536  # fm-remote-delta-read.sh's fixed payload bound
DELTA_READ_BUDGET = 4
DELTA_PROBE = 1 << 40  # above any real log: forces a size-reporting break
# The reply runner long-polls the same remote job lane with a 55-second window,
# and a queued delta read does not preempt a running one, so one delta call can
# legitimately wait a full window behind it before its own bounded read.
DELTA_TIMEOUT = 90
# The runner's truncate-then-write rewrite leaves its pid record empty for a
# moment; a few short re-reads read around it while keeping a pass bounded.
RUNNER_REREADS = 5
RUNNER_REREAD_DELAY = 0.02


def run(argv, env):
    try:
        process = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        stdout, _ = process.communicate(timeout=15)
        if process.returncode == 0:
            return stdout
    except subprocess.TimeoutExpired:
        # Only the exact group this call created, never a name match or
        # another home's runner. Killing the shell alone leaves ssh holding
        # the capture pipes and can wedge cron even after its timeout.
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=2)
    except OSError:
        pass
    raise ProbeError('command failed or timed out')


def run_status(argv, env, timeout=15):
    """One bounded attempt reporting (exit, stdout, stderr) for any command
    exit, so a caller can classify refusals; only a timeout or a spawn failure
    raises ProbeError."""
    try:
        process = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=2)
        raise ProbeError('command failed or timed out')
    except OSError:
        raise ProbeError('command failed')
    return process.returncode, stdout, stderr


def stamps(text):
    found = [int(s) for s in re.findall(r'\bat=(\d+)(?=[\] ;]|$)', text)]
    if text.strip() and not found:
        raise ProbeError('reply timestamps unavailable')
    return found


def newest(text):
    return max(stamps(text), default=0)


def valid_reader(record):
    """A persisted (offset, prefix hash, newest stamp) delta cursor."""
    if not isinstance(record, dict):
        return False
    try:
        offset = int(record['offset'])
        stamp = int(record['stamp'])
        prefix = str(record['prefix'])
    except (KeyError, TypeError, ValueError):
        return False
    return (offset >= 0 and stamp >= 0
            and re.fullmatch(r'[0-9a-f]{64}', prefix) is not None)


def delta_call(code, env, mate, offset, prefix):
    """One fm-remote-delta.v1 record as (fields, payload); fields is None when
    the window closed with no new complete line."""
    argv = [str(code / 'bin/fm-on.sh'), mate, 'fm-remote-delta-read.sh',
            DELTA_LOG, str(offset), prefix, DELTA_WAIT]
    rc, stdout, _ = run_status(argv, env, DELTA_TIMEOUT)
    if rc == 75:
        return None, b''
    if rc != 0:
        raise ProbeError('command failed or timed out')
    header, split, payload = stdout.partition(b'\n\n')
    fields = {}
    for line in header.decode('ascii').splitlines():
        key, equals, value = line.partition('=')
        if not equals:
            raise ProbeError('delta record is malformed')
        fields[key] = value
    status = fields.get('status')
    checks = {'delta': ('to_offset', 'payload_bytes'),
              'continuity-broken': ('to_offset',)}
    if status not in checks or fields.get('schema') != 'fm-remote-delta.v1' or not split:
        raise ProbeError('delta record is malformed')
    for key in checks[status] + ('to_prefix_sha256',):
        pattern = r'[0-9a-f]{64}' if key.endswith('sha256') else r'\d+'
        if re.fullmatch(pattern, fields.get(key, '')) is None:
            raise ProbeError('delta record is malformed')
    return fields, payload


def adopt_prefix(code, env, mate, offset):
    """The continuity break's actual prefix hash at <offset>; the cursor
    protocol offers it instead of rebasing, so a tail read adopts it."""
    fields, _ = delta_call(code, env, mate, offset, hashlib.sha256(b'').hexdigest())
    if fields is None or fields.get('status') != 'continuity-broken':
        raise ProbeError('delta record is malformed')
    return int(fields['to_offset']), fields['to_prefix_sha256']


def drain_delta(code, env, readers, mate):
    for _ in range(DELTA_READ_BUDGET):
        record = readers[mate]
        fields, payload = delta_call(code, env, mate, record['offset'], record['prefix'])
        if fields is None:
            return int(record['stamp'])
        if fields.get('status') == 'continuity-broken':
            return None
        if int(fields['payload_bytes']) != len(payload):
            raise ProbeError('delta record is malformed')
        found = stamps(payload.decode('utf-8', errors='replace'))
        readers[mate] = {'offset': int(fields['to_offset']),
                         'prefix': fields['to_prefix_sha256'],
                         'stamp': max([int(record['stamp'])] + found)}
    raise ProbeError('remote reply tail not reached within read budget')


def remote_stamp(code, env, memory, mate, audit):
    """Newest remote at= stamp after a bounded scan reaches the current tail."""
    readers = memory.setdefault('readers', {})
    if valid_reader(readers.get(mate)):
        stamp = drain_delta(code, env, readers, mate)
        if stamp is not None:
            return stamp
        audit('read %s log moved; resyncing cursor' % mate)
    rc, body, error = run_status([str(code / 'bin/fm-on.sh'), mate,
                                  'fm-remote-file.sh', 'get', DELTA_LOG,
                                  str(TRANSFER_BOUND)], env)
    if rc == 0:
        found = stamps(body.decode('utf-8', errors='replace'))
        readers[mate] = {'offset': len(body),
                         'prefix': hashlib.sha256(body).hexdigest(),
                         'stamp': max(found, default=0)}
        return readers[mate]['stamp']
    if rc != 1 or b'file exceeds max-bytes' not in error:
        raise ProbeError('command failed or timed out')
    # Past the whole-file bound: learn the size, adopt the offered prefix hash,
    # then read only the last chunk through the same cursor protocol.
    fields, _ = delta_call(code, env, mate, DELTA_PROBE,
                           hashlib.sha256(b'').hexdigest())
    if fields is None or fields.get('status') != 'continuity-broken':
        raise ProbeError('delta record is malformed')
    if fields.get('reason') == 'missing':
        raise ProbeError('remote reply log is missing')
    size = int(fields['to_offset'])
    offset = max(0, size - DELTA_CHUNK)
    for _ in range(2):
        if offset == 0:
            prefix = hashlib.sha256(b'').hexdigest()
        else:
            reported, prefix = adopt_prefix(code, env, mate, offset)
            if reported < offset:
                size = reported  # The log shrank mid-read; follow it once.
                offset = max(0, size - DELTA_CHUNK)
                continue
        readers[mate] = {'offset': offset, 'prefix': prefix, 'stamp': 0}
        stamp = drain_delta(code, env, readers, mate)
        if stamp is not None:
            return stamp
        raise ProbeError('remote reply log is unreadable')
    raise ProbeError('remote reply log kept moving')


def live_primary(home, env):
    listing = json.loads(run(['herdr', 'pane', 'list', '--session',
                              env.get('HERDR_SESSION', 'default')], env))
    candidates = []
    for pane in listing['result']['panes']:
        agent = pane.get('agent')
        if agent not in ('claude', 'codex') or pane.get('cwd') != str(home):
            continue
        pane_id = pane['pane_id']
        info = json.loads(run(['herdr', 'pane', 'process-info', '--pane', pane_id,
                               '--session', env.get('HERDR_SESSION', 'default')], env))
        processes = info['result']['process_info']['foreground_processes']
        # Herdr's live foreground process observation is required in addition
        # to display metadata. A stale agent label over bash is not an agent.
        running = any(p.get('pid', 0) > 0 and p.get('name') == agent
                      and p.get('cwd') == str(home) for p in processes)
        if running:
            candidates.append(pane_id)
    if len(candidates) != 1:
        raise ProbeError('no verified live primary (or multiple candidates)')
    return candidates[0]


def runner_alive(path, mate):
    try:
        text = path.read_text().strip()
        for _ in range(RUNNER_REREADS):
            if text:
                break
            time.sleep(RUNNER_REREAD_DELAY)
            text = path.read_text().strip()
        pid = int(text)
        if pid <= 1:
            return False
        os.kill(pid, 0)
        # Linux is the deployment target. Never mistake a zombie/reused pid
        # for a registered runner. No environment or credential files are read.
        proc = Path('/proc') / str(pid)
        if proc.exists():
            if (proc / 'stat').read_text().split(') ', 1)[1].split()[0] == 'Z':
                return False
            args = (proc / 'cmdline').read_bytes().split(b'\0')
            return b'_start' in args and ('remote-reply-' + mate).encode() in args
        return False
    except (OSError, ValueError, IndexError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--code-root', type=Path)
    parser.add_argument('--mate', action='append', default=[])
    args = parser.parse_args()
    home = args.home.resolve(strict=True)
    code = (args.code_root or home).resolve(strict=True)
    state = home / 'state'
    mates = args.mate
    if any(not re.fullmatch(r'[A-Za-z0-9._-]+', mate) for mate in mates):
        parser.error('mate ids must be path safe')
    env = dict(os.environ, FM_HOME=str(home))
    for key in ('FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE',
                'FM_ROOT_OVERRIDE', 'FM_PROCEVENT_IN_RUNNER'):
        env.pop(key, None)
    lock = (state / '.main-backstop.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    journal = state / '.main-backstop.json'
    try:
        memory = json.loads(journal.read_text())
    except (OSError, ValueError):
        memory = {}
    episodes = memory.setdefault('episodes', {})
    active = set()
    now = int(time.time())
    log = state / '.main-backstop.log'

    def audit(message):
        stamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        if log.exists() and log.stat().st_size > 262144:
            log.write_text(''.join(log.read_text().splitlines(keepends=True)[-500:]))
        with log.open('a') as out:
            out.write(stamp + ' ' + message + '\n')
        print(message, flush=True)

    def save():
        tmp = journal.with_suffix('.tmp')
        tmp.write_text(json.dumps(memory, sort_keys=True) + '\n')
        tmp.replace(journal)

    def alarm(key, message):
        active.add(key)
        request = episodes.setdefault(key, 'backstop-' + uuid.uuid4().hex)
        save()  # Preserve replay identity before an interrupted note submission.
        try:
            run([str(code / 'bin/fm-inbox.sh'), 'note', '--request-id', request,
                 '--', message], env)
        except ProbeError:
            # Keep the same request id; note may already be saved, and its
            # idempotent retry repairs announcement rather than duplicating it.
            audit('BACKSTOP ALARM SAVE FAILED: ' + message)
            return
        audit(message)

    try:
        beat_age = now - int((state / '.last-watcher-beat').stat().st_mtime)
    except OSError:
        beat_age = now
    need = (any(state.glob('*.meta')) or any(state.glob('*.check.sh'))
            or any((state / 'procevent').glob('*.source')))
    trouble = []
    if need and beat_age >= 300 and not (state / '.afk').exists():
        trouble.append('watcher silent for %ds' % beat_age)
    read_fails = memory.setdefault('read_fails', {})
    runner_fails = memory.setdefault('runner_fails', {})
    for mate in mates:
        source = state / 'procevent' / ('remote-reply-' + mate + '.source')
        if source.exists() and not runner_alive(source.with_suffix('.runner'), mate):
            # A live runner's record is absent for seconds while it applies
            # each captured reply; two consecutive not-alive passes are a
            # genuinely missing runner.
            repeated = mate in runner_fails
            runner_fails[mate] = now
            if repeated:
                message = 'REPLY RUNNER DOWN %s: registered runner is dead or missing; restore primary supervision to reconcile it.' % mate
                alarm('runner-' + mate, message)
                trouble.append('reply runner down: ' + mate)
            else:
                audit('runner not alive once, tolerating one pass: ' + mate)
                save()
        else:
            runner_fails.pop(mate, None)
            episodes.pop('runner-' + mate, None)
        try:
            remote = remote_stamp(code, env, memory, mate, audit)
            local_path = state / ('.remote-reply-mirrored-' + mate)
            local = newest(local_path.read_text()) if local_path.exists() else 0
            lag = remote - local
            if lag > 900:
                message = 'REPLY DELIVERY LAG %s: %ds (remote_at=%d ingested_at=%d); primary wake path needs recovery.' % (mate, lag, remote, local)
                alarm('lag-' + mate, message)
                trouble.append('reply lag: ' + mate)
            else:
                episodes.pop('lag-' + mate, None)
            read_fails.pop(mate, None)
            episodes.pop('read-' + mate, None)
        except (ProbeError, OSError, ValueError):
            # One failed pass is transport noise under load; two consecutive
            # passes are a genuinely unverified delivery state and alarm
            # durably, preserving the incident id until a successful read.
            repeated = mate in read_fails
            read_fails[mate] = now
            if repeated:
                alarm('read-' + mate, 'REPLY DELIVERY UNVERIFIED %s: bounded remote/local timestamp read failed; inspect delivery before assuming caught up.' % mate)
            else:
                audit('read failed once, tolerating one pass: ' + mate)
                save()
    if trouble:
        try:
            pane = live_primary(home, env)
            if now - memory.get('last_nudge', 0) >= 300:
                # Resolve the live foreground again just before sending; never
                # use a saved id when a primary has exited or changed panes.
                if live_primary(home, env) != pane:
                    raise ProbeError('primary changed during discovery')
                text = '[backstop] ' + '; '.join(trouble) + '. Drain wakes and handle the recovery; your turn-end owner re-arms supervision.'
                target = env.get('HERDR_SESSION', 'default') + ':' + pane
                verdict = run(['bash', '-c', '''
. "$1" || exit 1
state=$(fm_backend_composer_state herdr "$2") || exit 1
[ "$state" = empty ] || { printf 'refused'; exit 0; }
fm_backend_send_text_submit herdr "$2" "$3" 2 0.4 0.3
''', 'backstop-nudge', str(code / 'bin/fm-backend.sh'), target, text], env)
                if verdict.strip() != 'empty':
                    raise ProbeError('primary nudge failed: composer occupied or submission unconfirmed')
                memory['last_nudge'] = now
                (home / 'data/main-pane').write_text(pane + '\n')
                audit('nudged verified primary pane=' + pane)
                episodes.pop('recovery', None)
        except (ProbeError, OSError, ValueError, KeyError, TypeError) as error:
            detail = str(error) if isinstance(error, ProbeError) else 'primary discovery unavailable'
            if detail == 'command failed or timed out':
                detail = 'primary nudge failed or discovery unavailable'
            alarm('recovery', 'BACKSTOP FAILURE: %s; %s. No watcher was started externally; restore the primary and let its own turn-end owner re-arm.' % (detail, '; '.join(trouble)))
    elif all(mate not in read_fails and mate not in runner_fails for mate in mates):
        episodes.pop('recovery', None)
    save()
    audit('checked watcher_age=%ds alarms=%d' % (beat_age, len(active)))


if __name__ == '__main__':
    main()
