import os, sys, time, json, pathlib, subprocess, shlex, html, runpy

ROOT = pathlib.Path.cwd()
WORK = ROOT / '.test-validation/run'
WORK.mkdir()
EVID = pathlib.Path('~/.no-mistakes/evidence/01M6JKE24FPBRQCPRY046P20Q5')
HELPER = str(ROOT / 'bin/fm-herdr-lab.sh')
env = os.environ.copy()
for key in list(env):
    if key.startswith('HERDR_') or key in ('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_GATE_REFUSE_BYPASS'):
        env.pop(key, None)
env['DISABLE_AUTOUPDATER'] = '1'
env['FM_HERDR_LAB_STATE_DIR'] = str(WORK / 'lab-state')
original_path = env['PATH']

def command(args, **kwargs):
    p = subprocess.run(args, env=kwargs.pop('env', env), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=kwargs.pop('timeout', 90), **kwargs)
    if p.returncode:
        raise RuntimeError(f'{args!r}: rc={p.returncode}\n{p.stdout}\n{p.stderr}')
    return p.stdout

session = command([HELPER, 'name', 'exit-proof']).strip()
labhome = WORK / 'live-home'
command([str(ROOT / 'bin/fm-lab-home.sh'), 'create', str(labhome)])
active = True
transcript = []

def lab(*args):
    return command([HELPER, 'run', session, *args])

def record(s):
    print(s, flush=True)
    transcript.append(s)
    (EVID / 'live-control.log').write_text('\n'.join(transcript) + '\n')

def capture():
    return lab('pane', 'read', pane, '--source', 'visible')

def wait_screen(predicate, seconds=60):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        shot = capture()
        if predicate(shot):
            return shot
        time.sleep(.5)
    (EVID / 'last-screen.txt').write_text(shot)
    raise RuntimeError('screen predicate timed out; retained last-screen.txt')

def control(verb, *args):
    childenv = env.copy()
    childenv.update(FM_HOME=str(labhome), PATH=str(WORK / 'safe-bin') + ':' + original_path, FM_CONTROL_POLL='0.1', FM_CONTROL_EXIT_WAIT='10')
    p = subprocess.run([str(ROOT / 'bin/fm-control.sh'), 'busyproof', verb, *args], env=childenv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
    record(f'$ bin/fm-control.sh busyproof {verb} {shlex.join(args)}\nexit={p.returncode}\n{p.stdout}{p.stderr}')
    return p

try:
    command([HELPER, 'provision', session])
    status = json.loads(lab('status', '--json'))
    record('UTC=' + command(['date', '-u', '+%Y-%m-%dT%H:%M:%SZ']).strip())
    record('Claude=' + command(['claude', '--version']).strip() + '; Herdr=' + status['server']['version'] + '; session=' + session)
    ws = json.loads(lab('workspace', 'create', '--cwd', str(labhome), '--label', 'fm-busyproof', '--no-focus'))['result']
    (EVID / 'lab-workspace.json').write_text(json.dumps(ws, indent=2))
    pane = ws['root_pane']['pane_id']
    pidfile = labhome / 'claude.pid'
    shellpidfile = labhome / 'shell.pid'
    launch = 'env -u CLAUDECODE DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF=1 CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false bash -c ' + shlex.quote('echo $$ > ' + shlex.quote(str(pidfile)) + '; exec claude --dangerously-skip-permissions --setting-sources user --settings \'{"disableAllHooks":true,"disableAgentView":true}\'')
    lab('pane', 'run', pane, launch)
    wait_screen(lambda s: 'bypass permissions on' in s)
    cli_pid = int(pidfile.read_text())
    meta = '\n'.join([
        'backend=herdr', 'endpoint_task_id=busyproof', f'window={session}:{pane}',
        f'herdr_session={session}', f'herdr_workspace_id={ws["root_pane"]["workspace_id"]}',
        f'herdr_tab_id={ws["root_pane"]["tab_id"]}', f'herdr_pane_id={pane}',
        f'worktree={labhome}', f'project={ROOT}', 'harness=claude', 'kind=ship', 'mode=ship', 'spawn_gen=s1.1.1', 'yolo=on',
    ]) + '\n'
    (labhome / 'state/busyproof.meta').write_text(meta)
    (WORK / 'safe-bin').mkdir(exist_ok=True)
    wrapper = WORK / 'safe-bin/herdr'
    wrapper.write_text('#!/usr/bin/env bash\nset -eu\nargs=("$@")\nn=${#args[@]}\n[ "$n" -ge 2 ] && [ "${args[n-2]}" = --session ] && [ "${args[n-1]}" = ' + shlex.quote(session) + ' ] || exit 97\nargs=("${args[@]:0:n-2}")\ncase "${args[0]:-} ${args[1]:-}" in "pane send-text"|"pane send-keys") printf "%s\\n" "${args[*]}" >> ' + shlex.quote(str(WORK / 'control-input.log')) + ' ;; esac\nPATH=' + shlex.quote(original_path) + ' exec ' + shlex.quote(HELPER) + ' run ' + shlex.quote(session) + ' "${args[@]}"\n')
    wrapper.chmod(0o755)
    hold = labhome / 'hold.sh'
    hold.write_text('#!/usr/bin/env bash\necho $$ > shell.pid\nexec sleep 300\n')
    hold.chmod(0o755)
    shellcommand = '! ./hold.sh'
    lab('pane', 'send-text', pane, shellcommand)
    time.sleep(1)
    lab('pane', 'send-keys', pane, 'Enter')
    wait_screen(lambda s: 'ctrl+b to run in background' in s)
    shell_pid = int(shellpidfile.read_text())
    lab('pane', 'send-keys', pane, 'ctrl+b')
    shot = wait_screen(lambda s: '1 shell' in s)
    (EVID / 'live-status-only.txt').write_text(shot)
    for verb, args in [('exit', ['--landed-work']), ('relaunch', ['--note', 'retry live shell'])]:
        p = control(verb, *args)
        assert p.returncode == 75 and 'busy: background shell running' in p.stderr
        os.kill(cli_pid, 0); os.kill(shell_pid, 0)
        assert (labhome / 'state/busyproof.meta').read_text() == meta
    assert not (WORK / 'control-input.log').exists(), 'busy status sent lifecycle input'
    record(f'PASS status-only exit/relaunch: Claude pid={cli_pid} and shell pid={shell_pid} alive; metadata unchanged; no lifecycle input')
    lab('pane', 'send-text', pane, '/exit')
    lab('pane', 'send-keys', pane, 'Enter')
    shot = wait_screen(lambda s: 'Background work is running' in s and 'shell ·' in s)
    (EVID / 'live-exit-dialog.txt').write_text(shot)
    (EVID / 'live-exit-dialog.html').write_text('<!doctype html><meta charset="utf-8"><title>Actual Claude lab terminal capture</title><style>body{background:#161616;color:#eee;margin:24px}pre{font:14px/1.4 monospace;white-space:pre}</style><p>Actual visible terminal capture, Claude 2.1.318 on Herdr 0.9.5. No confirming input was sent.</p><pre>' + html.escape(shot) + '</pre>')
    for verb, args in [('exit', ['--landed-work']), ('relaunch', ['--note', 'retry dialog'])]:
        p = control(verb, *args)
        assert p.returncode == 75 and 'busy: background shell running' in p.stderr
        os.kill(cli_pid, 0); os.kill(shell_pid, 0)
        assert (labhome / 'state/busyproof.meta').read_text() == meta
    assert not (WORK / 'control-input.log').exists(), 'dialog received confirming input'
    record('PASS open-dialog exit/relaunch: retryable 75; both processes alive; no input and no metadata/checkpoint changes')
    runpy.run_path(str(ROOT / '.test-validation/remote-live.py'))['run'](ROOT, WORK, EVID, env, session, pane, ws, record)
    os.kill(cli_pid, 0); os.kill(shell_pid, 0)
    # Dismiss without selecting the destructive row, and let the real shell finish.
    lab('pane', 'send-keys', pane, 'Escape')
    os.kill(shell_pid, 15)
    wait_screen(lambda s: 'Background work is running' not in s and '1 shell' not in s)
    # Keep an actual fm-send waiting on the normal recipient metadata lock.
    # Its recipient is an agent-free disposable pane, so release enqueues a
    # durable steer without submitting a model prompt anywhere.
    recipient = json.loads(lab('workspace', 'create', '--cwd', str(labhome), '--label', 'fm-recipient', '--no-focus'))['result']['root_pane']
    recipient_meta = meta.replace('busyproof', 'recipient').replace(pane, recipient['pane_id']).replace(ws['root_pane']['tab_id'], recipient['tab_id']).replace('herdr_workspace_id=' + ws['root_pane']['workspace_id'], 'herdr_workspace_id=' + recipient['workspace_id'])
    recipient_path = labhome / 'state/recipient.meta'
    recipient_path.write_text(recipient_meta)
    childenv = dict(env, FM_HOME=str(labhome))
    holder = subprocess.Popen(['bash', '-c', 'source "$1/bin/fm-wake-lib.sh"; lock=$(fm_meta_lock_path "$2"); fm_lock_acquire_wait "$lock"; echo ready; read -r release; fm_lock_release "$lock"', '_', str(ROOT), str(recipient_path)], env=childenv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert holder.stdout.readline().strip() == 'ready'
        send_script = labhome / 'send.sh'
        send_pidfile = labhome / 'send.pid'
        send_log = EVID / 'unfinished-live-send.log'
        send_script.write_text('#!/usr/bin/env bash\necho $$ > send.pid\nexec env FM_HOME=' + shlex.quote(str(labhome)) + ' FM_TASK_INBOX_LOCK_WAIT_SECS=120 PATH=' + shlex.quote(str(WORK / 'safe-bin') + ':' + original_path) + ' ' + shlex.quote(str(ROOT / 'bin/fm-send.sh')) + ' recipient "unfinished live delivery must survive exit" > ' + shlex.quote(str(send_log)) + ' 2>&1\n')
        send_script.chmod(0o755)
        lab('pane', 'send-text', pane, '! ./send.sh')
        time.sleep(1)
        lab('pane', 'send-keys', pane, 'Enter')
        wait_screen(lambda s: 'ctrl+b to run in background' in s)
        send_pid = int(send_pidfile.read_text())
        lab('pane', 'send-keys', pane, 'ctrl+b')
        wait_screen(lambda s: '1 shell' in s)
        lab('pane', 'send-text', pane, '/exit')
        time.sleep(.5)
        lab('pane', 'send-keys', pane, 'Enter')
        shot = wait_screen(lambda s: 'Background work is running' in s and 'shell ·' in s)
        (EVID / 'unfinished-send-dialog.txt').write_text(shot)
        before_input = (WORK / 'control-input.log').read_text() if (WORK / 'control-input.log').exists() else ''
        p = control('exit', '--landed-work')
        assert p.returncode == 75 and 'busy: background shell running' in p.stderr
        os.kill(send_pid, 0)
        proc = command(['ps', '-p', str(send_pid), '-o', 'pid,ppid,stat,args'])
        record('PASS real unfinished fm-send survives exit refusal:\n' + proc)
        after_input = (WORK / 'control-input.log').read_text() if (WORK / 'control-input.log').exists() else ''
        assert before_input == after_input
        lab('pane', 'send-keys', pane, 'Escape')
    finally:
        holder.stdin.write('release\n'); holder.stdin.flush()
        out, err = holder.communicate(timeout=10)
        assert holder.returncode == 0, err
    wait_screen(lambda s: 'Background work is running' not in s and '1 shell' not in s)
    until = time.monotonic() + 15
    while pathlib.Path(f'/proc/{send_pid}').exists() and time.monotonic() < until:
        time.sleep(.1)
    assert not pathlib.Path(f'/proc/{send_pid}').exists()
    messages = list((labhome / 'state/recipient.inbox').glob('*.msg'))
    assert len(messages) == 1 and 'unfinished live delivery must survive exit' in messages[0].read_text()
    (EVID / 'unfinished-send-durable-record.txt').write_text(messages[0].read_text())
    record('PASS released sender completes and its real durable unacknowledged steer remains in recipient.inbox')
    # A real shell's printed capture must be treated as transcript text, not
    # as an active dialog. The renderer supplies the actual lower composer.
    quoted = labhome / 'quoted.sh'
    quoted.write_text('#!/usr/bin/env bash\ncat ' + shlex.quote(str(ROOT / 'tests/fixtures/claude-exit-background-shell-2.1.318.capture')) + '\n')
    quoted.chmod(0o755)
    lab('pane', 'send-text', pane, '! ./quoted.sh')
    time.sleep(1)
    lab('pane', 'send-keys', pane, 'Enter')
    shot = wait_screen(lambda s: 'Background work is running' in s and 'bypass permissions on' in s and '1 shell' not in s)
    (EVID / 'live-quoted-dialog.txt').write_text(shot)
    childenv = dict(env, FM_HOME=str(labhome))
    inbox_record = command(['bash', '-c', 'source "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2/state" busyproof "old unread message must not veto landed exit"', '_', str(ROOT), str(labhome)], env=childenv).strip()
    old_message = pathlib.Path(inbox_record).read_text()
    (EVID / 'old-unread-message.txt').write_text(old_message)
    p = control('exit', '--landed-work')
    assert p.returncode == 0 and 'stopped busyproof' in p.stdout
    assert not pathlib.Path(f'/proc/{cli_pid}').exists(), 'Claude survived claimed successful exit'
    assert pathlib.Path(inbox_record).read_text() == old_message
    record('PASS after shell completion: quoted capture and an old unread message do not veto landed exit; Claude stopped, endpoint and unread message preserved')
finally:
    if active:
        try:
            command([HELPER, 'teardown', session])
            record('PASS teardown: named lab removed; default-session tripwire unchanged')
        except Exception as e:
            record('TEARDOWN FAILED: ' + str(e))
            raise
