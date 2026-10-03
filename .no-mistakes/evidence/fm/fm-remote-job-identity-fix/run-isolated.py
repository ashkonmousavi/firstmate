import argparse, os, pathlib, signal, subprocess, tempfile, time, shutil
p = argparse.ArgumentParser()
p.add_argument('--log', required=True)
p.add_argument('--private-account', action='store_true')
p.add_argument('command', nargs=argparse.REMAINDER)
a = p.parse_args()
assert os.getpid() == 1, 'Run only in a disposable PID namespace'
lab = tempfile.mkdtemp(prefix='fm-identity-validation-')
env = os.environ.copy()
env['TMPDIR'] = lab
for key in ('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_REMOTE_JOB_STATE_ROOT', 'FM_PROC_ROOT_OVERRIDE'):
    env.pop(key, None)
log = open(a.log, 'w', buffering=1)
def emit(message):
    print(message, file=log, flush=True)
def children():
    return [int(x) for x in pathlib.Path('/proc/1/task/1/children').read_text().split()]
def reap():
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
            if pid == 0: break
        except ChildProcessError: break
emit('COMMAND=' + ' '.join(a.command))
emit('ISOLATION=private user/PID/mount namespaces; disposable TMPDIR')
if a.private_account:
    account = pathlib.Path(lab) / 'account-home'
    account.mkdir()
    subprocess.run(['mount', '--bind', str(account), '/root'], check=True)
    emit('ACCOUNT_ISOLATION=empty disposable /root mount visible only in this namespace')
code = 1
try:
    proc = subprocess.Popen(a.command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    deadline = time.monotonic() + 600
    while proc.poll() is None and time.monotonic() < deadline:
        for pid in children():
            if pid != proc.pid:
                try: os.waitpid(pid, os.WNOHANG)
                except ChildProcessError: pass
        time.sleep(0.02)
    if proc.poll() is None:
        emit('ERROR=targeted check exceeded 600 seconds')
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
    else:
        code = proc.returncode
    emit('COMMAND_EXIT=' + str(code))
finally:
    reap()
    emit('LAB_CHILDREN_BEFORE_CLEANUP=' + str(children()))
    for sig in (signal.SIGTERM, signal.SIGKILL):
        deadline = time.monotonic() + 4
        while children() and time.monotonic() < deadline:
            for pid in children():
                try: os.kill(pid, sig)
                except ProcessLookupError: pass
            reap()
            time.sleep(0.05)
    reap()
    remaining = children()
    emit('LAB_WORKERS_AFTER=' + str(len(remaining)))
    if a.private_account:
        subprocess.run(['umount', '/root'], check=True)
    shutil.rmtree(lab)
    emit('LAB_TMPDIR_REMOVED=true')
    log.close()
    print(pathlib.Path(a.log).read_text(), end='')
    if remaining: code = 1
raise SystemExit(code)
