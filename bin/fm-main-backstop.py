#!/usr/bin/env python3
"""Linux cron backstop for Herdr primary wake delivery, independent of the watcher.

Usage: fm-main-backstop.py --home PATH [--code-root PATH] [--mate ID ...]
       [--send-enabled-file HOME/config/main-backstop-send-enabled]
Run every three minutes. After a five-minute watcher silence with supervision
work and no state/.afk record, discover a unique live Claude/Codex primary in
this exact home and nudge it so its own turn-end owner re-arms.
Successful nudges are at least five minutes apart.
Nudges require the shared composer classifier to prove the input empty;
occupied or unknown input is preserved and reported as a recovery failure.
Never launches or kills an agent/watcher,
never types into a shell, and never treats data/main-pane as authority.
A failed discovery/send, a registered reply runner read as not alive on two
consecutive passes, remote/local timestamp reads failing on two consecutive
passes, or reply lag above fifteen
minutes becomes a durable fm-inbox note and check wake, visible at the next
drain even when no watcher/pane is alive.
Only explicitly supplied --mate ids are monitored.
Reply lag is the elapsed time since the oldest remote at= stamp not yet
mirrored in state/.remote-reply-mirrored-<mate>, or zero when caught up.
All reply and watermark timestamps use status_line_at_epoch in
bin/fm-classify-lib.sh, the canonical status timestamp grammar owner.
A nonblank line that grammar rejects is a continuation of the previous
entry's multi-line text and contributes no stamp, including a leading one
when a byte-cursor window begins mid-entry; a rejected line before the
first entry of a read from the log's beginning is corrupt and makes the
read fail rather than imply caught up.
An incident clears only when its oldest reply is mirrored.
Local status notices cannot advance that ingestion watermark, and a missing
or empty watermark counts as zero.
Reply monitoring remains active during .afk.
Remote reads use only existing fm-on read paths: one bounded fm-remote-file
get bootstraps a delta cursor, then fm-remote-delta-read returns only appended
lines. A moved log is re-read from the beginning, preserving unmirrored
stamps; a source past the whole-file bound is scanned from the beginning
through the bounded delta path across successive passes.
A delta scan must reach the current tail within four reads; exhausting that
budget counts as a failed read while preserving cursor progress for the next
pass, never reporting an intermediate timestamp as current. Delta reads allow one
reply-runner poll window in the shared remote job lane (ninety seconds); other
commands keep fifteen seconds. The job lane preempts a running read-only poll
(distinct exit 76) to unblock a queued command; such a poll is re-issued
unchanged, bounded per read without consuming the read budget, and only a lane
preempting every re-read counts as a failed read.
Output bodies are never logged. A read failing
on two consecutive passes alarms instead of claiming caught-up; a single
failed pass is audited as transport noise. A live runner removes its .runner
pid record while it applies each captured reply and rewrites it by
truncate-then-write on every poll, so an empty record is re-read briefly and a
runner read as not alive on a single pass is audited as transient. No remote
source is changed or live runner reconciled.
Notes deduplicate for an incident until a healthy observation clears it.
Runner identity requires Linux /proc process state and command-line records.
Private state: .main-backstop.json (incident ids, deferred alarms when gated,
successful nudge time, delta cursors and consecutive failure records),
.main-backstop.lock (cron exclusion), .main-backstop.log (bounded audit).
The caller deploys/backs up its private files and supplies the home's code root.
When --send-enabled-file is selected, its path must be exactly the resolved
HOME/config/main-backstop-send-enabled and its contents exactly enabled\n.
The config directory must be a nonsymlink directory owned by the home owner.
The file must be regular, nonsymlink, singly linked, and owned by both the home
owner and effective user; neither directory nor file may be group/world writable.
Reads are bounded and nonblocking, so a FIFO refuses permission without waiting.
Permission is rechecked before inbox notes, primary discovery and submission.
A missing or invalid capability leaves this pass observing and retaining
incidents without inbox notes or primary discovery/submission.
Deferred notes retain their request IDs and replay when enabled, even if the
incident resolved while stopped; a later incident receives a distinct ID.
Omitting the option preserves upstream send behavior; select it in the private
scheduler wrapper to enable the intentional-stop posture.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time
import uuid


class ProbeError(Exception):
    pass


TRANSFER_BOUND = 1048576  # fm-remote-file.sh's hard whole-file ceiling
DELTA_LOG = 'state/parent-replies.status'
DELTA_WAIT = '0'  # never block: a cron pass must stay bounded
DELTA_READ_BUDGET = 4
# The reply runner long-polls the same remote job lane with a 55-second window,
# and a queued delta read does not preempt a running one, so one delta call can
# legitimately wait a full window behind it before its own bounded read.
DELTA_TIMEOUT = 90
# A queued command for the same home preempts the running read-only delta poll
# (exit 76, lossless and cursor-anchored): re-issue the same read unchanged,
# and only a lane preempting every re-read counts as a failed read.
DELTA_PREEMPT_REREADS = 3
# The runner's truncate-then-write rewrite leaves its pid record empty for a
# moment; a few short re-reads read around it while keeping a pass bounded.
RUNNER_REREADS = 5
RUNNER_REREAD_DELAY = 0.02


def send_capability_enabled(home, path):
    """Read the exact private send capability without following a replaced link."""
    expected = home / 'config/main-backstop-send-enabled'
    if path != expected:
        return False
    fd = None
    try:
        config = os.lstat(expected.parent)
        owner = home.stat().st_uid
        if (not stat.S_ISDIR(config.st_mode) or config.st_uid != owner
                or config.st_mode & 0o022):
            return False
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
                     | os.O_NONBLOCK)
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != owner
                or info.st_uid != os.geteuid() or info.st_nlink != 1
                or info.st_mode & 0o022 or info.st_size != len(b'enabled\n')):
            return False
        content = os.read(fd, len(b'enabled\n') + 1)
        current = os.stat(path, follow_symlinks=False)
        return (content == b'enabled\n' and current.st_dev == info.st_dev
                and current.st_ino == info.st_ino and stat.S_ISREG(current.st_mode))
    except (OSError, ValueError):
        return False
    finally:
        if fd is not None:
            os.close(fd)


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


def run_status(argv, env, timeout=15, input_data=None):
    """One bounded attempt reporting (exit, stdout, stderr) for any command
    exit, so a caller can classify refusals; only a timeout or a spawn failure
    raises ProbeError."""
    try:
        process = subprocess.Popen(argv, env=env, stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        stdout, stderr = process.communicate(input=input_data, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=2)
        raise ProbeError('command failed or timed out')
    except OSError:
        raise ProbeError('command failed')
    return process.returncode, stdout, stderr


def stamps(text, at_start):
    """Entry epochs in one reply-log read, in file order.

    A nonblank line the canonical grammar rejects is a continuation of the
    previous entry's multi-line text and contributes no stamp. A read that
    starts at a byte cursor can start mid-entry, so a rejected leading line
    there is the tail of an entry from before the cursor; at_start marks a
    read of the log from its beginning, where a rejected line before the
    first entry is corrupt and fails the read rather than imply caught up.
    """
    rc, output, _ = run_status(['bash', '-c', r'''
. "$1" || exit 1
seen=0
while IFS= read -r line || [ -n "$line" ]; do
    [ -n "${line//[$' \t\r']/}" ] || continue
    if ! epoch=$(status_line_at_epoch "$line"); then
        if [ "$seen" -gt 0 ] || [ "$2" != log-start ]; then
            continue
        fi
        exit 1
    fi
    seen=1
    printf '%s\n' "$epoch"
done
''', 'backstop-timestamps', str(Path(__file__).parent / 'fm-classify-lib.sh'),
                               'log-start' if at_start else 'at-cursor'],
                               os.environ, input_data=text.encode('utf-8'))
    if rc != 0:
        raise ProbeError('reply timestamps unavailable')
    return [int(value) for value in output.splitlines()]


def newest(text):
    return max(stamps(text, True), default=0)


def valid_reader(record):
    """A persisted offset, prefix hash and unmirrored timestamp set."""
    if not isinstance(record, dict):
        return False
    try:
        offset = int(record['offset'])
        pending = record['pending_at']
        prefix = str(record['prefix'])
    except (KeyError, TypeError, ValueError):
        return False
    return (offset >= 0 and isinstance(pending, list)
            and all(type(stamp) is int and stamp >= 0 for stamp in pending)
            and re.fullmatch(r'[0-9a-f]{64}', prefix) is not None)


def delta_call(code, env, mate, offset, prefix):
    """One fm-remote-delta.v1 record as (fields, payload); fields is None when
    the window closed with no new complete line. A read the remote job lane
    preempted (exit 76) is lossless and cursor-anchored, so the same read is
    re-issued unchanged up to DELTA_PREEMPT_REREADS times; a preempted attempt
    consumes no read budget, and only a lane preempting every re-read raises."""
    argv = [str(code / 'bin/fm-on.sh'), mate, 'fm-remote-delta-read.sh',
            DELTA_LOG, str(offset), prefix, DELTA_WAIT]
    for _ in range(DELTA_PREEMPT_REREADS + 1):
        rc, stdout, _ = run_status(argv, env, DELTA_TIMEOUT)
        if rc != 76:
            break
    if rc == 75:
        return None, b''
    if rc == 76:
        raise ProbeError('delta read stayed preempted')
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


def drain_delta(code, env, readers, mate, local):
    for _ in range(DELTA_READ_BUDGET):
        record = readers[mate]
        record['pending_at'] = sorted({stamp for stamp in record['pending_at'] if stamp > local})
        fields, payload = delta_call(code, env, mate, record['offset'], record['prefix'])
        if fields is None:
            return min(record['pending_at'], default=0)
        if fields.get('status') == 'continuity-broken':
            return None
        if int(fields['payload_bytes']) != len(payload):
            raise ProbeError('delta record is malformed')
        # A window at a nonzero cursor can begin mid-entry; offset zero is
        # the head of the log, where no entry precedes the first line.
        found = stamps(payload.decode('utf-8', errors='replace'),
                       record['offset'] == 0)
        readers[mate] = {'offset': int(fields['to_offset']),
                         'prefix': fields['to_prefix_sha256'],
                         'pending_at': sorted(set(record['pending_at']) | {stamp for stamp in found if stamp > local})}
    raise ProbeError('remote reply tail not reached within read budget')


def remote_oldest(code, env, memory, mate, local, audit):
    readers = memory.setdefault('readers', {})
    pending = []
    if valid_reader(readers.get(mate)):
        oldest = drain_delta(code, env, readers, mate, local)
        if oldest is not None:
            return oldest
        pending = readers[mate]['pending_at']
        audit('read %s log moved; resyncing cursor' % mate)
    rc, body, error = run_status([str(code / 'bin/fm-on.sh'), mate,
                                  'fm-remote-file.sh', 'get', DELTA_LOG,
                                  str(TRANSFER_BOUND)], env)
    if rc == 0:
        found = stamps(body.decode('utf-8', errors='replace'), True)
        pending = sorted(set(pending) | {stamp for stamp in found if stamp > local})
        readers[mate] = {'offset': len(body),
                         'prefix': hashlib.sha256(body).hexdigest(),
                         'pending_at': pending}
        return min(pending, default=0)
    if rc != 1 or b'file exceeds max-bytes' not in error:
        raise ProbeError('command failed or timed out')
    readers[mate] = {'offset': 0, 'prefix': hashlib.sha256(b'').hexdigest(),
                     'pending_at': pending}
    oldest = drain_delta(code, env, readers, mate, local)
    if oldest is None:
        raise ProbeError('remote reply log kept moving')
    return oldest


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
    parser.add_argument('--send-enabled-file', type=Path)
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
    # An older private copy stored these as lists; reset any non-dict shape
    # to a fresh dict so the dict-typed bookkeeping below starts cleanly,
    # keeping last_nudge and any reader cursors. Reader records failing
    # valid_reader rebootstrap as on any first pass.
    for key in ('episodes', 'read_fails', 'runner_fails'):
        if not isinstance(memory.get(key), dict):
            memory[key] = {}
    episodes = memory.setdefault('episodes', {})
    deferred = memory.setdefault('deferred_alarms', {}) if args.send_enabled_file else {}
    for key in list(deferred):
        if key in episodes:
            deferred[episodes[key]] = deferred.pop(key)
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

    def send_enabled():
        return (args.send_enabled_file is None
                or send_capability_enabled(home, args.send_enabled_file))

    def deliver_alarm(request, message):
        if not send_enabled():
            audit('BACKSTOP ALARM HELD: ' + request)
            return
        try:
            run([str(code / 'bin/fm-inbox.sh'), 'note', '--request-id', request,
                 '--', message], env)
        except ProbeError:
            audit('BACKSTOP ALARM SAVE FAILED: ' + message)
            return
        deferred.pop(request, None)
        save()
        audit(message)

    def resolve_episode(key):
        episodes.pop(key, None)

    def alarm(key, message):
        active.add(key)
        request = episodes.setdefault(key, 'backstop-' + uuid.uuid4().hex)
        if args.send_enabled_file is not None:
            deferred[request] = message
        save()  # Preserve replay identity before an interrupted note submission.
        # Keep the same request id across a stop or interrupted note. The
        # inbox's idempotent retry repairs an uncertain prior submission.
        deliver_alarm(request, message)

    if send_enabled():
        for request, message in list(deferred.items()):
            deliver_alarm(request, message)

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
    lag_oldest = memory.setdefault('lag_oldest', {})
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
            resolve_episode('runner-' + mate)
        try:
            local_path = state / ('.remote-reply-mirrored-' + mate)
            local = newest(local_path.read_text()) if local_path.exists() else 0
            oldest = remote_oldest(code, env, memory, mate, local, audit)
            lag = max(0, now - oldest) if oldest else 0
            if mate in lag_oldest and local >= lag_oldest[mate]:
                resolve_episode('lag-' + mate)
                lag_oldest.pop(mate)
            if lag > 900:
                message = 'REPLY DELIVERY LAG %s: %ds (oldest_at=%d ingested_at=%d); primary wake path needs recovery.' % (mate, lag, oldest, local)
                lag_oldest.setdefault(mate, oldest)
                alarm('lag-' + mate, message)
                trouble.append('reply lag: ' + mate)
            elif not oldest:
                resolve_episode('lag-' + mate)
                lag_oldest.pop(mate, None)
            read_fails.pop(mate, None)
            resolve_episode('read-' + mate)
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
    if trouble and not send_enabled():
        alarm('recovery', 'BACKSTOP HELD: ' + '; '.join(trouble))
    elif trouble:
        try:
            if not send_enabled():
                raise ProbeError('send capability revoked')
            pane = live_primary(home, env)
            if now - memory.get('last_nudge', 0) >= 300:
                # Resolve the live foreground again just before sending; never
                # use a saved id when a primary has exited or changed panes.
                if live_primary(home, env) != pane:
                    raise ProbeError('primary changed during discovery')
                text = '[backstop] ' + '; '.join(trouble) + '. Drain wakes and handle the recovery; your turn-end owner re-arms supervision.'
                target = env.get('HERDR_SESSION', 'default') + ':' + pane
                if not send_enabled():
                    raise ProbeError('send capability revoked')
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
                resolve_episode('recovery')
        except (ProbeError, OSError, ValueError, KeyError, TypeError) as error:
            detail = str(error) if isinstance(error, ProbeError) else 'primary discovery unavailable'
            if detail == 'command failed or timed out':
                detail = 'primary nudge failed or discovery unavailable'
            alarm('recovery', 'BACKSTOP FAILURE: %s; %s. No watcher was started externally; restore the primary and let its own turn-end owner re-arm.' % (detail, '; '.join(trouble)))
    elif all(mate not in read_fails and mate not in runner_fails for mate in mates):
        resolve_episode('recovery')
    save()
    audit('checked watcher_age=%ds alarms=%d' % (beat_age, len(active)))


if __name__ == '__main__':
    main()
