import os
from pathlib import Path
import shutil
import socket
import subprocess as sp
import tempfile
import shlex

ROOT = Path.cwd()
EVID = Path('~/.no-mistakes/evidence/01M6JJF9V56MYTKS7S9ATC35F9')
W = Path(tempfile.mkdtemp(prefix='live-update-', dir=ROOT / '.test-tmp'))
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'GIT_', 'HERDR_'))}
env.update(HOME=str(W / 'account'), TMPDIR=str(W / 'tmp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='lab', GIT_AUTHOR_EMAIL='lab@example.invalid', GIT_COMMITTER_NAME='lab', GIT_COMMITTER_EMAIL='lab@example.invalid')
for d in ['account', 'tmp']:
    (W / d).mkdir()
server = None
log = open(EVID / 'live-update-transcript.log', 'w', buffering=1)

def note(s):
    print(s, file=log)
    print(s, flush=True)

def run(*args, check=True, **kw):
    return sp.run([str(a) for a in args], env=env, text=True, stdout=sp.PIPE, stderr=sp.STDOUT, check=check, **kw).stdout

def git(where, *args):
    return run('git', '-C', W / where, *args).strip()

def script(name, body):
    p = W / name
    p.write_text('#!/usr/bin/env bash\nset -eu\n' + body)
    p.chmod(0o700)
    return p

try:
    note('Real fm-update.sh + real SSH + real remote-secondmate-control.sh in disposable Git repositories.')
    note('SSH test endpoint decodes fm-on argv and invokes the real control command directly; it does not use the production account job queue.')
    note('No agent is launched or restarted. A deliberately unavailable endpoint returns real unverified state; the summary conservatively retains restart eligibility.')
    run('git', 'init', '-q', '--bare', '--initial-branch=main', W / 'origin.git')
    run('git', 'clone', '-q', W / 'origin.git', W / 'seed')
    archive = sp.run(['git', 'archive', 'HEAD'], check=True, stdout=sp.PIPE).stdout
    sp.run(['tar', '-x', '-C', str(W / 'seed')], input=archive, check=True)
    with open(W / 'seed/.gitignore', 'a') as f:
        f.write('\n.fm-lab-home\n')
    git('seed', 'add', '.')
    git('seed', 'commit', '-qm', 'lab initial')
    git('seed', 'push', '-q', 'origin', 'main')
    old = git('seed', 'rev-parse', 'HEAD')
    for d in ['primary', 'remote-root', 'remote-home']:
        run('git', 'clone', '-q', W / 'origin.git', W / d)
    with open(W / 'seed/README.md', 'a') as f:
        f.write('\nDisposable update target.\n')
    git('seed', 'add', 'README.md')
    git('seed', 'commit', '-qm', 'lab target')
    git('seed', 'push', '-q', 'origin', 'main')
    target = git('seed', 'rev-parse', 'HEAD')
    git('primary', 'pull', '-q', '--ff-only')
    for d in ['home', 'remote-root', 'remote-home']:
        if d == 'home':
            run('bash', ROOT / 'bin/fm-lab-home.sh', 'create', W / d)
        for sub in ['state', 'config', 'data']:
            (W / d / sub).mkdir(exist_ok=True)
    (W / 'remote-home/.fm-secondmate-home').write_text('sm1\n')
    (W / 'remote-home/state/parent-route').mkdir()
    # Invalid endpoint metadata is intentional: the real state command returns
    # unverified, which the existing public contract treats as possibly alive.
    (W / 'remote-home/state/parent-route/sm1.meta').write_text('kind=secondmate\n')
    (W / 'home/data/secondmates.md').write_text(f'- sm1 - disposable remote (host: lab-peer; root: {W}/remote-root; home: {W}/remote-home; scope: test; projects: p; added 2026-11-03)\n')
    (W / 'home/state/sm1.meta').write_text(f'window=remote:sm1\nendpoint_task_id=sm1\nharness=claude\nkind=secondmate\nhome={W}/remote-home\nremote_host=lab-peer\nremote_backend=herdr\n')
    # Private transport endpoint: all real product executables remain unchanged.
    endpoint = script('endpoint', f'''
cd {shlex.quote(str(W))}
eval "set -- $SSH_ORIGINAL_COMMAND"
[ "$1" = fm-remote-entrypoint.sh ] && [ "$2" = 1 ]
rroot=$(printf %s "$3" | base64 --decode)
rhome=$(printf %s "$4" | base64 --decode)
args=()
while IFS= read -r -d '' a; do args+=("$a"); done < <(printf %s "$5" | base64 --decode)
[ "$rroot" = "$PWD/remote-root" ] && [ "$rhome" = "$PWD/remote-home" ]
export HOME="$PWD/account" TMPDIR="$PWD/tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_ROOT_OVERRIDE="$rroot" FM_HOME="$rhome"
mode=$(cat mode)
if [ "${{args[1]}}" = update ]; then
  if [ "$mode" = multi ]; then bash "$rroot/bin/fm-remote-secondmate-control.sh" sync sm1; fi
  bash "$rroot/bin/${{args[0]}}" "${{args[@]:1}}" > remote-response 2>&1
  case "$mode" in
    missing) sed '/^synced:/d; /^current:/d' remote-response ;;
    malformed) sed 's/^synced:/diagnostic: synced:/; s/^current:/diagnostic: current:/' remote-response ;;
    wrong-target)
      sed -E 's/^(synced:|current:) [0-9a-f]{{40}}/\\1 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' remote-response ;;
    *) cat remote-response ;;
  esac
  # Emit an actual rearm diagnostic AFTER the actual control command's result.
  bash "$rroot/bin/fm-pr-check-rearm.sh"
else
  exec bash "$rroot/bin/${{args[0]}}" "${{args[@]:1}}"
fi
''')
    run('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', W / 'key')
    s = socket.socket(); s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]; s.close()
    (W / 'sshd-config').write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {W}/key
PidFile {W}/sshd.pid
AuthorizedKeysFile {W}/key.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers {os.environ['USER']}
PermitUserRC no
DisableForwarding yes
PrintMotd no
ForceCommand {endpoint}
''')
    server_log = open(W / 'sshd.log', 'w')
    server = sp.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(W / 'sshd-config')], stdout=server_log, stderr=sp.STDOUT, env=env)
    (W / 'ssh-config').write_text(f'''Host lab-peer
  HostName 127.0.0.1
  User {os.environ['USER']}
  Port {port}
  IdentityFile {W}/key
  IdentitiesOnly yes
  UserKnownHostsFile {W}/known-hosts
  StrictHostKeyChecking accept-new
  LogLevel ERROR
''')
    ssh = script('ssh', f'exec /usr/bin/ssh -F {shlex.quote(str(W / "ssh-config"))} "$@"\n')
    # A real connection readiness probe, without issuing a product command.
    import time
    for _ in range(50):
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                break
        except OSError:
            time.sleep(0.1)
    else:
        raise RuntimeError('sshd did not listen')
    (W / 'base-bin').mkdir()
    for p in (ROOT / 'bin').iterdir():
        if p.name != 'fm-update.sh':
            (W / 'base-bin' / p.name).symlink_to(p)
    base = sp.run(['git', 'show', '06cd6721cad90ed00ef393fff101602c9e9bdcf9:bin/fm-update.sh'], check=True, text=True, stdout=sp.PIPE).stdout
    (W / 'base-bin/fm-update.sh').write_text(base)
    (W / 'base-bin/fm-update.sh').chmod(0o700)
    parent_env = env | dict(FM_HOME=str(W / 'home'), FM_ROOT_OVERRIDE=str(W / 'primary'), FM_SSH_BIN=str(ssh), FM_UPDATE_REMOTE_UPDATE_SECONDS='40', FM_UPDATE_REMOTE_STATE_SECONDS='20')

    def reset_remote():
        for d in ['remote-root', 'remote-home']:
            git(d, 'reset', '--hard', old)

    def drive(name, mode, executable, expected, restart, reset=False):
        if reset:
            reset_remote()
        (W / 'mode').write_text(mode)
        proc = sp.run(['bash', str(executable)], env=parent_env, text=True, stdout=sp.PIPE, stderr=sp.STDOUT, timeout=65)
        note(f'\n=== {name} (exit {proc.returncode}) ===\n{proc.stdout}')
        assert proc.returncode == 0
        assert expected in proc.stdout, expected
        assert f'restart-secondmates: {restart}' in proc.stdout
        assert 'nudge-secondmates: none' in proc.stdout
        assert 'pr-poll-rearm:' in proc.stdout
        assert git('remote-root', 'rev-parse', 'HEAD') == target
        assert git('remote-home', 'rev-parse', 'HEAD') == target
        note(f'persisted remote-root HEAD={target}; remote-home HEAD={target}')
        note('PASS: output, action summary, and persisted Git commits agree')

    drive('RED: baseline misreads successful sync with trailing rearm output', 'normal', W / 'base-bin/fm-update.sh', 'skipped on lab-peer: malformed update result', 'none', reset=True)
    drive('GREEN: synced survives trailing rearm output', 'normal', ROOT / 'bin/fm-update.sh', f'updated on lab-peer ({target})', 'fm-sm1', reset=True)
    drive('GREEN: already current survives trailing rearm output', 'normal', ROOT / 'bin/fm-update.sh', f'already current on lab-peer ({target})', 'fm-sm1')
    drive('GREEN: last real status wins after an earlier current status', 'multi', ROOT / 'bin/fm-update.sh', f'updated on lab-peer ({target})', 'fm-sm1', reset=True)
    drive('GREEN: missing status is refused', 'missing', ROOT / 'bin/fm-update.sh', 'skipped on lab-peer: malformed update result', 'none')
    drive('GREEN: diagnostic-embedded status is refused', 'malformed', ROOT / 'bin/fm-update.sh', 'skipped on lab-peer: malformed update result', 'none')
    drive('GREEN: trailing diagnostics cannot hide wrong commit', 'wrong-target', ROOT / 'bin/fm-update.sh', f'host reports {"b" * 40}, not update target {target}', 'none')
    note('\nAll isolated real-command scenarios passed.')
finally:
    if server:
        server.terminate()
        rc = server.wait(timeout=10)
        note(f'Disposable SSH server stopped and reaped: exit={rc}')
    shutil.rmtree(W)
    note('Disposable repositories, keys, configuration, and runtime state removed.')
    log.close()
