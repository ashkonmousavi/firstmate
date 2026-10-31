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


def main():
    version = subprocess.check_output(['claude', '--version'], text=True).strip()
    print('# %s Claude %s' % (time.strftime('%Y-%m-%d', time.gmtime()), version), flush=True)
    processes = []
    with tempfile.TemporaryDirectory(prefix='.lock-live-', dir=ROOT) as tmp:
        base = Path(tmp)
        home = base / 'project'
        state = home / 'state'
        state.mkdir(parents=True)
        (home / 'config').mkdir()
        (home / 'config/supervision-host-off').touch()
        (home / 'AGENTS.md').touch()
        shutil.copytree(ROOT / 'bin', home / 'bin')
        config = base / 'claude-config'
        config.mkdir()
        original_config = Path(os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude')))
        for name in ('.credentials.json', '.claude.json'):
            source = original_config / name
            if source.is_file():
                shutil.copyfile(source, config / name)
                (config / name).chmod(0o600)
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('CLAUDE_CODE_', 'FM_'))
               and k not in ('CLAUDECODE', 'CLAUDE_PID', 'TMUX')}
        env.update(CLAUDE_CONFIG_DIR=str(config), FM_HOME=str(home),
                   FM_ROOT_OVERRIDE=str(home), FM_GATE_REFUSE_BYPASS='1',
                   DISABLE_AUTOUPDATER='1', CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',
                   FM_CLAUDE_AUTOARM_SYNC_WAIT_MS='0', FM_POLL='1', FM_HEARTBEAT='999999')
        subprocess.run(['git', 'init', '-q', str(home)], env=env, check=True)
        shim = base / 'clock'
        shim.mkdir()
        python = shutil.which('python3')
        date = shutil.which('date')
        (shim / 'python3').write_text('''#!/bin/bash
if [ "${FM_LOCK_LIVE_CLOCK:-0}" != 0 ] && [ "${1:-}" = - ]; then
  exec REAL_PYTHON -c 'import sys,time; offset=float(sys.argv.pop(1)); sys.argv=sys.argv[1:]; real=time.time; time.time=lambda:real()+offset; exec(compile(sys.stdin.read(),"<stdin>","exec"))' "$FM_LOCK_LIVE_CLOCK" "$@"
fi
exec REAL_PYTHON "$@"
'''.replace('REAL_PYTHON', shlex.quote(python)))
        (shim / 'date').write_text('''#!/bin/bash
if [ "${FM_LOCK_LIVE_CLOCK:-0}" != 0 ] && [ "$#" = 1 ] && [ "$1" = +%s ]; then
  now=$(REAL_DATE +%s)
  printf '%s\\n' "$((now + FM_LOCK_LIVE_CLOCK))"
else
  exec REAL_DATE "$@"
fi
'''.replace('REAL_DATE', shlex.quote(date)))
        for path in shim.iterdir():
            path.chmod(0o755)
        env['PATH'] = str(shim) + os.pathsep + env['PATH']
        arm = home / 'bin/fm-watch-arm.sh'
        arm.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$(cat "$FM_HOME/state/.lock")" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:live-lock\\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\\nstale: live-lock actionable\\n' "$$"
''')
        hook = base / 'hook.sh'
        hook.write_text('''#!/usr/bin/env bash
payload=$(cat)
sid=$(printf '%s' "$payload" | jq -r '.session_id')
[ "$sid" = "${CLAUDE_CODE_SESSION_ID:-}" ] || exit 1
[ -n "${CLAUDE_PID:-}" ] || exit 1
out="$FM_HOME/state/$FM_LOCK_LIVE_TAG"
if [ "$1" = start ]; then
  printf '%s\\n%s\\n' "$sid" "$CLAUDE_PID" > "$out.identity"
  if [ "$FM_LOCK_LIVE_TAG" = terminal ]; then
    bash "$FM_HOME/bin/fm-lock.sh" > "$out.acquire" 2>&1
    printf '%s\\n' "$?" > "$out.rc"
  else
    bash "$FM_HOME/bin/fm-lock.sh" > "$out.recent" 2>&1
    printf '%s\\n' "$?" > "$out.recent-rc"
    if [ "$FM_LOCK_LIVE_TAG" = phone ]; then
      FM_LOCK_LIVE_CLOCK=3600 bash "$FM_HOME/bin/fm-lock.sh" > "$out.acquire" 2>&1
      printf '%s\\n' "$?" > "$out.rc"
    fi
  fi
else
  if [ "$FM_LOCK_LIVE_TAG" = return ]; then
    printf 'project=live-lock\\n' > "$FM_HOME/state/task.meta"
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
                if proc.poll() is not None:
                    raise AssertionError('Claude exited before ' + path.name + ': ' +
                                         (base / (path.name.split('.')[0] + '.log')).read_text()[-2000:])
                if time.monotonic() >= deadline:
                    raise AssertionError('Claude timed out before ' + path.name)
                time.sleep(0.1)

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
            if tag != 'phone':
                master, slave = pty.openpty()

                def terminal():
                    os.setsid()
                    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                preexec = terminal
            with (base / (tag + '.log')).open('w') as log:
                proc = subprocess.Popen(args, cwd=home, env=child_env, stdin=subprocess.PIPE,
                                        stdout=log, stderr=log, text=True, preexec_fn=preexec,
                                        start_new_session=(tag == 'phone'),
                                        pass_fds=(() if slave is None else (slave,)))
            processes.append((proc, master))
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
            assert (tty in ('?', '')) == (tag == 'phone'), 'background/terminal topology differs'
            assert (state / (tag + '.rc')).read_text().strip() == ('2' if tag == 'return' else '0'), tag
            if predecessor:
                assert (state / (tag + '.recent-rc')).read_text().strip() == '1', 'recent holder was taken'
            assert (state / '.lock').read_text() == str(pid) + '\n'
            assert (state / '.lock-session').read_text().strip() == session
            print('ok - %s holder pid=%s tty=%s' % (tag, pid, tty), flush=True)
            return session, pid

        try:
            sid, terminal_pid = launch('terminal')
            phone_sid, phone_pid = launch('phone', sid)
            return_sid, return_pid = launch('return', phone_sid)
            for proc, _master in processes:
                assert proc.poll() is None, 'a predecessor exited instead of remaining live'
            rows = [json.loads(line) for line in (state / '.lock-handover.jsonl').read_text().splitlines()]
            assert [(row['from_pid'], row['to_pid'], row['from_session'], row['to_session']) for row in rows] == [
                (terminal_pid, phone_pid, sid, phone_sid), (phone_pid, return_pid, phone_sid, return_sid)]
            arms = (state / 'arm-ran').read_text().splitlines()
            assert arms and all(pid == str(return_pid) for pid in arms), arms
            transcripts = list((config / 'projects').glob('*/*.jsonl'))
            for session in (sid, phone_sid, return_sid):
                matches = [path for path in transcripts if path.stem == session]
                assert len(matches) == 1
                rows = [json.loads(line) for line in matches[0].read_text().splitlines()]
                assert any(row.get('type') == 'user' and row.get('uuid') and row.get('timestamp') for row in rows)
                assert any(row.get('type') == 'assistant' and row.get('uuid') and row.get('timestamp') for row in rows)
            print('ok - live fork-resume terminal -> background phone -> terminal: two recorded handovers; '
                  'recent-turn refusal; Stop recovery armed; predecessor processes stayed live; '
                  'classifier clock advanced 3600s, vendor transcripts unmodified', flush=True)
        except Exception as error:
            raise AssertionError('Claude %s: %s (logs in %s while running)' % (version, error, base)) from error
        finally:
            for proc, master in reversed(processes):
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGTERM)
                proc.wait(timeout=15)
                proc.stdin.close()
                if master is not None:
                    os.close(master)


if __name__ == '__main__':
    main()
