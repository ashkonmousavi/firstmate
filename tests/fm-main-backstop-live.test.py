"""Exercise discovery with real installed harnesses in a private Herdr server."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(os.environ['ROOT'])
spec = importlib.util.spec_from_file_location('backstop', ROOT / 'bin/fm-main-backstop.py')
backstop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backstop)


def check_refused(home, env):
    try:
        backstop.live_primary(home, env)
    except backstop.ProbeError:
        return
    raise AssertionError('accepted a home without a live agent')


def main():
    installed = [name for name in ('claude', 'codex') if shutil.which(name)]
    for name in ('claude', 'codex'):
        if name not in installed:
            print('skip: %s absent' % name, flush=True)
    if not installed:
        raise AssertionError('no real harness installed')
    with tempfile.TemporaryDirectory(prefix='.bl-', dir=ROOT) as tmp:
        base = Path(tmp)
        os.chdir(base)
        env = dict(os.environ)
        for key in ('HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_TAB_ID', 'HERDR_WORKSPACE_ID', 'HERDR_SOCKET_PATH'):
            env.pop(key, None)
        env.update(HERDR_SESSION='fm-lab-backstop',
                   XDG_CONFIG_HOME='x', XDG_DATA_HOME=str(base / 'data'),
                   XDG_STATE_HOME=str(base / 'state'), XDG_CACHE_HOME=str(base / 'cache'),
                   CLAUDE_CONFIG_DIR=str(base / 'claude-config'),
                   CODEX_HOME=str(base / 'codex-config'), DISABLE_AUTOUPDATER='1')
        for key in ('XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME',
                    'CLAUDE_CONFIG_DIR', 'CODEX_HOME'):
            Path(env[key]).mkdir()
        shell = base / 'shell'
        shell.write_text('#!/bin/sh\nexec /bin/bash --noprofile --norc\n')
        shell.chmod(0o755)
        config = base / 'x/herdr/config.toml'
        config.parent.mkdir()
        config.write_text('[terminal]\ndefault_shell = %s\nshell_mode = "non_login"\n'
                          '[update]\nversion_check = false\nmanifest_check = false\n'
                          % json.dumps(str(shell)))

        def cli(*args):
            result = subprocess.run(['herdr', *args, '--session', env['HERDR_SESSION']], env=env, capture_output=True,
                                    text=True, timeout=15)
            if result.returncode:
                raise AssertionError('herdr %s: %s' % (' '.join(args[:2]), result.stderr or result.stdout))
            return result.stdout

        with (base / 'server.log').open('w') as log:
            server = subprocess.Popen(['herdr', 'server', '--session', env['HERDR_SESSION']], cwd=base, env=env,
                                      stdout=log, stderr=log, start_new_session=True)
            try:
                deadline = time.monotonic() + 30
                while True:
                    if server.poll() is not None:
                        raise AssertionError('isolated Herdr server exited: ' + (base / 'server.log').read_text())
                    try:
                        cli('pane', 'list')
                        break
                    except AssertionError:
                        if time.monotonic() >= deadline:
                            raise
                        time.sleep(0.2)
                herdr_version = subprocess.run(['herdr', '--version'], env=env,
                                               capture_output=True, text=True, timeout=15).stdout.strip()
                print('# ' + herdr_version, flush=True)
                shell_home = base / 'shell-home'
                shell_home.mkdir()
                shell_pane = json.loads(cli('workspace', 'create', '--cwd', str(shell_home),
                                            '--label', 'backstop-shell', '--no-focus'))['result']['root_pane']['pane_id']
                for harness in installed:
                    version = subprocess.run([harness, '--version'], env=env, capture_output=True,
                                             text=True, timeout=15).stdout.strip()
                    try:
                        home = base / harness
                        home.mkdir()
                        pane = json.loads(cli('workspace', 'create', '--cwd', str(home),
                                              '--label', 'backstop-' + harness, '--no-focus'))['result']['root_pane']['pane_id']
                        args = ([harness, '--settings', '{"disableAllHooks":true}', '--setting-sources', '']
                                if harness == 'claude' else [harness, '--disable', 'hooks'])
                        cli('pane', 'run', pane, shlex.join(args))
                        deadline = time.monotonic() + 60
                        while True:
                            try:
                                found_pane, found_pid = backstop.live_primary(home, env)
                                assert found_pane == pane
                                assert type(found_pid) is int and found_pid > 1
                                os.kill(found_pid, 0)
                                info = json.loads(cli('pane', 'process-info', '--pane', pane))['result']
                                assert found_pid in {p['pid'] for p in
                                                     info['process_info']['foreground_processes']}
                                break
                            except (backstop.ProbeError, AssertionError) as error:
                                if time.monotonic() >= deadline:
                                    raise AssertionError('real harness was not discovered: %s; listing=%s; processes=%s' % (
                                        error, cli('pane', 'list').strip(),
                                        cli('pane', 'process-info', '--pane', pane).strip()))
                                time.sleep(0.2)
                        check_refused(home / 'wrong-home', env)
                        cli('pane', 'report-agent', shell_pane, '--source', 'backstop-live',
                            '--agent', harness, '--state', 'idle')
                        listing = json.loads(cli('pane', 'list'))['result']['panes']
                        actual = next(p for p in listing if p['pane_id'] == shell_pane)
                        assert actual['agent'] == harness, 'shell lacks stale harness label'
                        info = json.loads(cli('pane', 'process-info', '--pane', shell_pane))['result']
                        processes = info['process_info']['foreground_processes']
                        assert processes and all(p.get('name') == 'bash' and p.get('pid', 0) > 0
                                                 for p in processes), 'shell case is not a live bash'
                        check_refused(shell_home, env)
                        cli('pane', 'release-agent', shell_pane, '--source', 'backstop-live', '--agent', harness)
                        print('ok - %s (%s): exact-home discovery, wrong-home and stale-label shell refusal'
                              % (harness, version), flush=True)
                    except Exception as error:
                        raise AssertionError('%s (%s): %s' % (harness, version, error)) from error
            finally:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
                os.chdir(ROOT)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('not ok - backstop live discovery: %s' % error, flush=True)
        sys.exit(1)
