import contextlib
import struct
import threading
import fcntl
import json
import os
from pathlib import Path
import pty
import shlex
import shutil
import signal
import subprocess
import tempfile
import termios
import time
import uuid

ROOT = Path(os.environ['ROOT'])
EVIDENCE = Path(__file__).parent


@contextlib.contextmanager
def lab_directory():
    lab = ROOT / 'l'
    lab.mkdir()
    try:
        yield str(lab)
    finally:
        shutil.rmtree(lab)


def main():
    version = subprocess.check_output(['claude', '--version'], text=True).strip()
    print('# %s Claude %s' % (time.strftime('%Y-%m-%d', time.gmtime()), version), flush=True)
    processes = []
    observer = None
    with lab_directory() as tmp:
        base = Path(tmp)
        home = base / 'p'
        subprocess.run(['bash', str(ROOT / 'bin/fm-lab-home.sh'), 'create', str(home)], check=True)
        (home / 'tmux').mkdir()
        state = home / 'state'
        state.mkdir(parents=True, exist_ok=True)
        (home / 'config').mkdir(exist_ok=True)
        (home / 'config/supervision-host-off').touch()
        (home / 'AGENTS.md').touch()
        shutil.copytree(ROOT / 'bin', home / 'bin')
        config = base / 'claude-config'
        config.mkdir()
        original_config = Path(os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude')))
        for name in ('.credentials.json',):
            source = original_config / name
            if source.is_file():
                shutil.copyfile(source, config / name)
                (config / name).chmod(0o600)
        client_path = config / '.claude.json'
        client = json.loads(client_path.read_text()) if client_path.exists() else {}
        client['hasCompletedOnboarding'] = True
        client['theme'] = 'dark'
        client.setdefault('projects', {}).setdefault(str(home), {})['hasTrustDialogAccepted'] = True
        client['projects'].setdefault(str(ROOT), {})['hasTrustDialogAccepted'] = True
        client_path.write_text(json.dumps(client))
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('CLAUDE_CODE_', 'FM_'))
               and k not in ('CLAUDECODE', 'CLAUDE_PID', 'TMUX', 'NO_MISTAKES_GATE')}
        env.update(CLAUDE_CONFIG_DIR=str(config), FM_HOME=str(home),
                   TMUX_TMPDIR=str(home / 'tmux'),
                   DISABLE_AUTOUPDATER='1', CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',
                   FM_CLAUDE_AUTOARM_SYNC_WAIT_MS='0', FM_POLL='1', FM_HEARTBEAT='1')
        subprocess.run(['git', 'init', '-q', str(home)], env=env, check=True)
        shim = base / 'clock'
        shim.mkdir()
        python = shutil.which('python3')
        date = shutil.which('date')
        (shim / 'python3').write_text('''#!/bin/bash
if [ ! -e "$FM_HOME/state/real-clock" ] && [ "${FM_LOCK_LIVE_CLOCK:-0}" != 0 ] && [ "${1:-}" = - ]; then
  exec REAL_PYTHON -c 'import sys,time; offset=float(sys.argv.pop(1)); sys.argv=sys.argv[1:]; real=time.time; time.time=lambda:real()+offset; exec(compile(sys.stdin.read(),"<stdin>","exec"))' "$FM_LOCK_LIVE_CLOCK" "$@"
fi
exec REAL_PYTHON "$@"
'''.replace('REAL_PYTHON', shlex.quote(python)))
        (shim / 'date').write_text('''#!/bin/bash
if [ ! -e "$FM_HOME/state/real-clock" ] && [ "${FM_LOCK_LIVE_CLOCK:-0}" != 0 ] && [ "$#" = 1 ] && [ "$1" = +%s ]; then
  now=$(REAL_DATE +%s)
  printf '%s\\n' "$((now + FM_LOCK_LIVE_CLOCK))"
else
  exec REAL_DATE "$@"
fi
'''.replace('REAL_DATE', shlex.quote(date)))
        for path in shim.iterdir():
            path.chmod(0o755)
        env['PATH'] = str(shim) + os.pathsep + env['PATH']
        # End the classifier-only simulated idle period before executing the real watcher.
        arm = home / 'bin/fm-watch-arm.sh'
        arm.rename(home / 'bin/fm-watch-arm-real.sh')
        arm.write_text('#!/bin/bash\ntouch "$FM_HOME/state/real-clock"\nexec "${BASH_SOURCE[0]%/*}/fm-watch-arm-real.sh" "$@"\n')
        arm.chmod(0o755)
        hook = base / 'hook.sh' 
        hook.write_text('''#!/usr/bin/env bash
payload=$(cat)
sid=$(printf '%s' "$payload" | jq -r '.session_id')
[ "$sid" = "${CLAUDE_CODE_SESSION_ID:-}" ] || exit 1
[ -n "${CLAUDE_PID:-}" ] || exit 1
out="$FM_HOME/state/$FM_LOCK_LIVE_TAG"
if [ -e "$FM_HOME/state/probe-now" ]; then
  . "$FM_HOME/bin/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$FM_HOME/state"
  printf '%s\\n' "$?" > "$FM_HOME/state/$sid.ownership"
  exit 0
fi
if [ "$FM_LOCK_LIVE_TAG" = terminal ] && [ "$(printf '%s' "$payload" | jq -r '.source')" = clear ]; then
  out="$FM_HOME/state/cleared"
  printf '%s' "$payload" | jq -r '.transcript_path' > "$out.transcript"
fi
if [ "$1" = start ]; then
  printf '%s\\n%s\\n' "$sid" "$CLAUDE_PID" > "$out.identity"
  if [ "$FM_LOCK_LIVE_TAG" = terminal ]; then
    bash "$FM_HOME/bin/fm-lock.sh" > "$out.acquire" 2>&1
    printf '%s\\n' "$?" > "$out.rc"
  else
    bash "$FM_HOME/bin/fm-lock.sh" > "$out.recent" 2>&1
    printf '%s\\n' "$?" > "$out.recent-rc"
    if [ "$FM_LOCK_LIVE_TAG" != return ]; then
      FM_LOCK_LIVE_CLOCK=3600 bash "$FM_HOME/bin/fm-lock.sh" > "$out.acquire" 2>&1
      printf '%s\\n' "$?" > "$out.rc"
    fi
  fi
else
  if [ "$FM_LOCK_LIVE_TAG" = return ]; then
    printf 'project=live-lock\\n' > "$FM_HOME/state/task.meta"
    before=$(cat "$FM_HOME/state/.lock")
    printf '%s' "$payload" | bash "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$out.stop-recent" 2>&1
    printf '%s\\n' "$?" > "$out.stop-recent-rc"
    [ "$(cat "$FM_HOME/state/.lock")" = "$before" ] || exit 1
    printf '%s' "$payload" | FM_LOCK_LIVE_CLOCK=3600 bash "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$out.stop" 2>&1
    printf '%s\\n' "$?" > "$out.rc"
  fi
  touch "$out.done"
fi
exit 0
''')
        settings = base / 'settings.json'
        settings.write_text(json.dumps({'feedbackDrafts': 'off', 'hooks': {
            event: [{'hooks': [{'type': 'command', 'command': 'bash %s %s' % (shlex.quote(str(hook)), arg),
                               'timeout': 90}]}]
            for event, arg in (('SessionStart', 'start'), ('Stop', 'stop'))}}))

        def wait_file(path, proc):
            deadline = time.monotonic() + 120
            while not path.exists():
                if proc is not None and proc.poll() is not None:
                    raise AssertionError('Claude exited before ' + path.name + ': ' +
                                         (base / (path.name.split('.')[0] + '.log')).read_text()[-2000:])
                if time.monotonic() >= deadline:
                    raise AssertionError('Claude timed out before ' + path.name)
                time.sleep(0.1)

        def tmux_cli(*args):
            result = subprocess.run(['tmux', '-L', 'fm-lab', '-f', '/dev/null', *args],
                                    cwd=home, env=dict(env, FM_LOCK_LIVE_TAG='terminal'),
                                    capture_output=True, text=True, timeout=15)
            if result.returncode:
                raise AssertionError('tmux %s: %s' % (args[0], result.stderr))
            return result.stdout

        def native_clear_predecessor():
            session = str(uuid.uuid4())
            args = ['claude', '--tools', '', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
                    '--setting-sources', '', '--settings', str(settings), '--session-id', session]
            tmux_cli('new-session', '-d', '-s', 'primary', '-x', '160', '-y', '44',
                     '-c', str(ROOT), shlex.join(args))
            wait_file(state / 'terminal.identity', None)
            time.sleep(1)
            tmux_cli('send-keys', '-t', 'primary', '-l', 'Reply with exactly OK. Do not use tools.')
            tmux_cli('send-keys', '-t', 'primary', 'Enter')
            wait_file(state / 'terminal.done', None)
            actual, pid = (state / 'terminal.identity').read_text().splitlines()
            assert actual == session
            assert (state / 'terminal.rc').read_text().strip() == '0'
            tmux_cli('send-keys', '-t', 'primary', '-l', '/clear')
            tmux_cli('send-keys', '-t', 'primary', 'Enter')
            wait_file(state / 'cleared.rc', None)
            cleared, clear_pid = (state / 'cleared.identity').read_text().splitlines()
            assert cleared != session and clear_pid == pid, 'native clear did not rekey the same process'
            assert (state / 'cleared.rc').read_text().strip() == '0'
            assert (state / '.lock-session').read_text().splitlines() == [cleared, session]
            assert (state / '.lock').read_text() == pid + '\n'
            transcript = Path((state / 'cleared.transcript').read_text().strip())
            transcript.relative_to(config)
            transcript.touch(exist_ok=True)
            assert not any(json.loads(line).get('type') in ('user', 'assistant')
                           for line in transcript.read_text().splitlines()), 'B is not empty after clear'
            print('ok - native /clear: same terminal pid=%s rekeyed A to readable empty B, prior A retained' % pid,
                  flush=True)
            # Drive the actual backstop CLI and actual inbox against a live vendor holder.
            (state / 'alert.meta').write_text('project=lab\n')
            beat = state / '.last-watcher-beat'
            beat.touch()
            os.utime(beat, (time.time() - 600,) * 2)
            def backstop():
                out = subprocess.run(['python3', str(ROOT / 'bin/fm-main-backstop.py'),
                    '--home', str(home), '--code-root', str(ROOT)], env=env,
                    text=True, capture_output=True, timeout=30)
                assert out.returncode == 0, out.stderr
                print(out.stdout.strip(), flush=True)
            backstop()
            assert not list((state / 'inbox').glob('*.note'))
            os.utime(beat, (time.time() - 901,) * 2)
            backstop()
            backstop()
            notes = list((state / 'inbox').glob('*.note'))
            assert len(notes) == 1, notes
            note = notes[0].read_text()
            assert 'Idle lock holder' in note and ('pid=%s' % pid) in note
            assert 'tty=' in note and 'idle=' in note
            memory = json.loads((state / '.main-backstop.json').read_text())
            assert not memory.get('last_nudge'), memory
            print('BACKSTOP_NOTE ' + note, flush=True)
            (EVIDENCE / 'backstop-inbox-note.txt').write_text(note)
            (state / 'alert.meta').unlink()
            print('ok - live terminal holder: no ask at 10m; exactly one queued ask at 15m1s across two passes; no nudge', flush=True)
            return session, cleared, int(pid)

        def launch(tag, predecessor=None):
            session = str(uuid.uuid4())
            args = ['claude', '-p', '--input-format', 'stream-json', '--output-format', 'stream-json',
                    '--verbose', '--tools', '', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
                    '--setting-sources', '', '--settings', str(settings), '--session-id', session]
            if predecessor:
                args += ['--fork-session', '--resume', predecessor]
            child_env = dict(env, FM_LOCK_LIVE_TAG=tag)
            master = slave = None
            preexec = None
            if tag == 'return':
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 44, 160, 0, 0))

                def terminal():
                    os.setsid()
                    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                preexec = terminal
            with (base / (tag + '.log')).open('w') as log:
                proc = subprocess.Popen(args, cwd=ROOT, env=child_env, stdin=subprocess.PIPE,
                                        stdout=log, stderr=log, text=True, preexec_fn=preexec,
                                        start_new_session=(tag != 'return'),
                                        pass_fds=(() if slave is None else (slave,)))
            processes.append((proc, master))
            if master is not None:
                def drain(fd):
                    try:
                        while os.read(fd, 8192):
                            pass
                    except OSError:
                        pass
                threading.Thread(target=drain, args=(master,), daemon=True).start()
            if slave is not None:
                os.close(slave)
            proc.stdin.write(json.dumps({'type': 'user', 'message': {'role': 'user', 'content':
                              'Reply with exactly OK. Do not use tools.'}}) + '\n')
            proc.stdin.flush()
            wait_file(state / (tag + '.done'), proc)
            actual_id, pid_s = (state / (tag + '.identity')).read_text().splitlines()
            assert actual_id == session, 'vendor hook session identity differs from requested session'
            pid = int(pid_s)
            os.kill(pid, 0)
            tty = subprocess.check_output(['ps', '-o', 'tty=', '-p', str(pid)], text=True).strip()
            assert (tty in ('?', '')) == (tag != 'return'), 'background/terminal topology differs'
            refused = tag.startswith('unrelated')
            expected = '1' if refused else ('2' if tag == 'return' else '0')
            assert (state / (tag + '.rc')).read_text().strip() == expected, tag
            if predecessor:
                assert (state / (tag + '.recent-rc')).read_text().strip() == '1', 'recent holder was taken'
            if not refused:
                assert (state / '.lock').read_text() == str(pid) + '\n'
                assert (state / '.lock-session').read_text().strip() == session
            print('ok - %s holder pid=%s tty=%s' % (tag, pid, tty), flush=True)
            return session, pid

        try:
            sid, cleared_sid, terminal_pid = native_clear_predecessor()
            unrelated_sid, _ = launch('unrelated-seed')
            launch('unrelated', unrelated_sid)
            assert (state / '.lock-session').read_text().splitlines() == [cleared_sid, sid]
            print('ok - unrelated real fork refused after native A-to-B clear', flush=True)
            observer_log = EVIDENCE / 'coherent-holder-observations.tsv'
            with observer_log.open('w') as observations:
                observer = subprocess.Popen(['bash', '-c',
                    '. "$1/bin/fm-session-lock-lib.sh"; while [ ! -e "$FM_HOME/state/observer-stop" ]; do fm_session_lock_read_record "$FM_HOME/state" || exit 1; printf "%s\t%s\n" "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_SESSION"; sleep 0.05; done',
                    'observer', str(ROOT)], env=env, stdout=observations, stderr=subprocess.PIPE, text=True)
            phone_sid, phone_pid = launch('phone', sid)
            return_sid, return_pid = launch('return', phone_sid)
            assert (state / 'return.stop-recent-rc').read_text().strip() == '0'
            assert not (state / 'return.stop-recent').read_text().strip()
            print('ok - real Stop refuses a recently active live predecessor without moving lock or arming', flush=True)
            (state / 'observer-stop').touch()
            _, observer_error = observer.communicate(timeout=15)
            assert observer.returncode == 0, observer_error
            samples = [tuple(row.split('\t')) for row in observer_log.read_text().splitlines()]
            expected_pairs = {(str(terminal_pid), cleared_sid), (str(phone_pid), phone_sid), (str(return_pid), return_sid)}
            assert set(samples) == expected_pairs, (set(samples), expected_pairs)
            print('ok - %s concurrent coherent ownership reads observed only the three real holder pid/session pairs across both handovers' % len(samples), flush=True)
            checks = []
            for stem in ('terminal.acquire', 'cleared.acquire', 'unrelated.acquire', 'phone.recent', 'phone.acquire', 'return.recent', 'return.stop-recent', 'return.stop'):
                checks.append(stem + '\n' + (state / stem).read_text())
            (EVIDENCE / 'lock-check-output.txt').write_text('\n'.join(checks))
            for proc, _master in processes:
                assert proc.poll() is None, 'a predecessor exited instead of remaining live'
            rows = [json.loads(line) for line in (state / '.lock-handover.jsonl').read_text().splitlines()]
            assert [(row['from_pid'], row['to_pid'], row['from_session'], row['to_session']) for row in rows] == [
                (terminal_pid, phone_pid, cleared_sid, phone_sid), (phone_pid, return_pid, phone_sid, return_sid)]
            stop_output = (state / 'return.stop').read_text()
            assert 'firstmate watcher wake' in stop_output, stop_output
            assert (state / '.last-watcher-beat').is_file()
            print('REAL_STOP_OUTPUT ' + stop_output, flush=True)
            # Ask every still-running real CLI to execute its own ownership reader in Stop.
            (state / 'probe-now').touch()
            tmux_cli('send-keys', '-t', 'primary', '-l', 'Reply with exactly OK. Do not use tools.')
            tmux_cli('send-keys', '-t', 'primary', 'Enter')
            for proc, _master in processes:
                proc.stdin.write(json.dumps({'type':'user','message':{'role':'user','content':'Reply with exactly OK. Do not use tools.'}}) + '\n')
                proc.stdin.flush()
            identities = [cleared_sid, unrelated_sid, phone_sid, return_sid]
            # Include the second unrelated fork, whose id comes from its real SessionStart payload.
            identities.append((state / 'unrelated.identity').read_text().splitlines()[0])
            for identity in identities:
                wait_file(state / (identity + '.ownership'), None)
            owners = [identity for identity in identities if (state / (identity + '.ownership')).read_text().strip() == '0']
            assert owners == [return_sid], owners
            proof = {identity: (state / (identity + '.ownership')).read_text().strip() for identity in identities}
            print('OWNERSHIP_VERDICTS ' + json.dumps(proof), flush=True)
            (EVIDENCE / 'ownership-verdicts.json').write_text(json.dumps(proof, indent=2) + '\n')
            (EVIDENCE / 'stop-hook-output.txt').write_text(stop_output)
            (EVIDENCE / 'lock-handover.jsonl').write_text((state / '.lock-handover.jsonl').read_text())
            transcripts = list((config / 'projects').glob('*/*.jsonl'))
            for session in (sid, phone_sid, return_sid):
                matches = [path for path in transcripts if path.stem == session]
                assert len(matches) == 1
                rows = [json.loads(line) for line in matches[0].read_text().splitlines()]
                assert any(row.get('type') == 'user' and row.get('uuid') and row.get('timestamp') for row in rows)
                assert any(row.get('type') == 'assistant' and row.get('uuid') and row.get('timestamp') for row in rows)
            print('ok - live fork-resume terminal -> background phone -> terminal: two recorded handovers; '
                  'recent-turn refusal; Stop recovery armed; predecessor processes stayed live; '
                  'native A-to-empty-B clear and unrelated-fork refusal; classifier clock advanced 3600s; vendor turns unmodified', flush=True)
        except Exception as error:
            try:
                screen = tmux_cli('capture-pane', '-p', '-t', 'primary')
            except AssertionError:
                screen = ''
            raise AssertionError('Claude %s: %s; terminal=%s' % (version, error, screen)) from error
        finally:
            if observer is not None and observer.poll() is None:
                (state / 'observer-stop').touch()
                observer.communicate(timeout=15)
                assert observer.returncode == 0
            if (state / '.watch.lock').exists():
                stopped = subprocess.run(['bash', str(home / 'bin/fm-watch-arm.sh'), '--stop'], env=env, text=True, capture_output=True, timeout=30)
                print('LAB_WATCHER_CLEANUP ' + stopped.stdout.strip(), flush=True)
                assert stopped.returncode == 0, stopped.stderr
            for proc, master in reversed(processes):
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGTERM)
                proc.wait(timeout=15)
                proc.stdin.close()
                if master is not None:
                    os.close(master)
            pane_pid = int(tmux_cli('display-message', '-p', '-t', 'primary', '#{pane_pid}').strip())
            result = subprocess.run(['tmux', '-L', 'fm-lab', 'kill-server'], env=env,
                           capture_output=True, timeout=15)
            assert result.returncode == 0, result.stderr
            # kill-server returns before the pane's Claude has finished its exit writes.
            deadline = time.monotonic() + 15
            while True:
                try:
                    os.kill(pane_pid, 0)
                except ProcessLookupError:
                    break
                if time.monotonic() >= deadline:
                    raise AssertionError('terminal Claude still alive after private tmux teardown')
                time.sleep(0.1)
            print('ok - cleanup: all launched CLI processes exited, watcher stopped, private tmux server stopped', flush=True)


if __name__ == '__main__':
    main()
