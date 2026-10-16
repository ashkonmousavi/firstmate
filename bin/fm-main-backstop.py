#!/usr/bin/env python3
"""Cron backstop for Herdr primary wake delivery, independent of the watcher.

Usage: fm-main-backstop.py --home PATH [--code-root PATH] [--mate ID ...]
Run every three minutes. After a five-minute watcher silence with supervision
work, discover a unique live Claude/Codex primary in this exact home and nudge
it so its own turn-end owner re-arms. Never launches or kills an agent/watcher,
never types into a shell, and never treats data/main-pane as authority.
A failed discovery/send, dead registered reply runner, unreadable remote log,
or reply timestamp lag above fifteen minutes becomes a durable fm-inbox note
and check wake, visible at the next drain even when no watcher/pane is alive.
Only explicitly supplied --mate ids are monitored.
Remote reads use only the existing fm-on/fm-remote-file read path. Each command
has a fifteen-second timeout; a failed transport is retried once. Output bodies
are never logged. Missing/oversized/unreadable evidence alarms instead of
claiming caught-up. No remote source is changed or live runner reconciled.
Notes deduplicate for an incident until a healthy observation clears it.
Private state: .main-backstop.json (incident ids and successful nudge time),
.main-backstop.lock (cron exclusion), .main-backstop.log (bounded audit).
The caller deploys/backs up its private files and supplies the home's code root.
"""
import argparse
import fcntl
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


def run(argv, env, retry=False):
    for attempt in range(2 if retry else 1):
        process = None
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
        if attempt == (1 if retry else 0):
            raise ProbeError('command failed or timed out')
    raise ProbeError('command failed')


def newest(text):
    stamps = [int(s) for s in re.findall(r'\bat=(\d+)(?=[\] ;]|$)', text)]
    if text.strip() and not stamps:
        raise ProbeError('reply timestamps unavailable')
    return max(stamps, default=0)


def live_primary(home, env):
    listing = json.loads(run(['herdr', 'pane', 'list'], env))
    candidates = []
    for pane in listing['result']['panes']:
        agent = pane.get('agent')
        if agent not in ('claude', 'codex') or pane.get('cwd') != str(home):
            continue
        pane_id = pane['pane_id']
        info = json.loads(run(['herdr', 'pane', 'process-info', '--pane', pane_id], env))
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
        pid = int(path.read_text().strip())
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
    for mate in mates:
        source = state / 'procevent' / ('remote-reply-' + mate + '.source')
        if source.exists() and not runner_alive(source.with_suffix('.runner'), mate):
            message = 'REPLY RUNNER DOWN %s: registered runner is dead or missing; restore primary supervision to reconcile it.' % mate
            alarm('runner-' + mate, message)
            trouble.append('reply runner down: ' + mate)
        try:
            remote = newest(run([str(code / 'bin/fm-on.sh'), mate,
                                  'fm-remote-file.sh', 'get',
                                  'state/parent-replies.status', '1048576'], env, retry=True))
            local_path = state / (mate + '.status')
            local = newest(local_path.read_text()) if local_path.exists() else 0
            lag = remote - local
            if lag > 900:
                message = 'REPLY DELIVERY LAG %s: %ds (remote_at=%d ingested_at=%d); primary wake path needs recovery.' % (mate, lag, remote, local)
                alarm('lag-' + mate, message)
                trouble.append('reply lag: ' + mate)
        except (ProbeError, OSError, ValueError):
            alarm('read-' + mate, 'REPLY DELIVERY UNVERIFIED %s: bounded remote/local timestamp read failed; inspect delivery before assuming caught up.' % mate)
    if trouble:
        try:
            pane = live_primary(home, env)
            if now - memory.get('last_nudge', 0) >= 300:
                # Resolve the live foreground again just before sending; never
                # use a saved id when a primary has exited or changed panes.
                if live_primary(home, env) != pane:
                    raise ProbeError('primary changed during discovery')
                text = '[backstop] ' + '; '.join(trouble) + '. Drain wakes and handle the recovery; your turn-end owner re-arms supervision.'
                run(['herdr', 'pane', 'send-text', pane, text], env)
                run(['herdr', 'pane', 'send-keys', pane, 'enter'], env)
                memory['last_nudge'] = now
                (home / 'data/main-pane').write_text(pane + '\n')
                audit('nudged verified primary pane=' + pane)
        except (ProbeError, OSError, ValueError, KeyError, TypeError) as error:
            detail = str(error) if isinstance(error, ProbeError) else 'primary discovery unavailable'
            if detail == 'command failed or timed out':
                detail = 'primary nudge failed or discovery unavailable'
            alarm('recovery', 'BACKSTOP FAILURE: %s; %s. No watcher was started externally; restore the primary and let its own turn-end owner re-arm.' % (detail, '; '.join(trouble)))
    for key in list(episodes):
        if key not in active:
            del episodes[key]
    save()
    audit('checked watcher_age=%ds alarms=%d' % (beat_age, len(active)))


if __name__ == '__main__':
    main()
