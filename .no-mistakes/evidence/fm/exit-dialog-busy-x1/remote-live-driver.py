import os, pathlib, shutil, subprocess, socket, time, shlex, json

def run(root, work, evid, env, session, pane, ws, record):
    hostroot = work / 'remote-root'
    hosthome = work / 'remote-home'
    parent = work / 'parent-home'
    for home in (hostroot, hosthome, parent):
        subprocess.run([str(root / 'bin/fm-lab-home.sh'), 'create', str(home)], env=env, check=True, stdout=subprocess.DEVNULL)
    shutil.copytree(root / 'bin', hostroot / 'bin')
    for dest in (hostroot, hosthome):
        shutil.copyfile(root / 'AGENTS.md', dest / 'AGENTS.md')
    (hosthome / 'bin').mkdir()
    (hosthome / '.fm-secondmate-home').write_text('busyproof\n')
    subprocess.run(['git', 'init', '-q', str(hostroot)], check=True)
    # A separate disposable code checkout is the host's product installation.
    # It avoids assigning any host-controller state to the gate's source root.
    (hosthome / 'state/parent-route').mkdir()
    hostmeta = '\n'.join([
        'backend=herdr', 'endpoint_task_id=busyproof', f'window={session}:{pane}',
        f'herdr_session={session}', f'herdr_workspace_id={ws["root_pane"]["workspace_id"]}',
        f'herdr_tab_id={ws["root_pane"]["tab_id"]}', f'herdr_pane_id={pane}',
        f'worktree={hosthome}', f'project={hostroot}', f'home={hosthome}',
        'harness=claude', 'kind=secondmate', 'mode=secondmate', 'spawn_gen=s1.1.1', 'yolo=on',
    ]) + '\n'
    (hosthome / 'state/parent-route/busyproof.meta').write_text(hostmeta)
    parentmeta = '\n'.join([
        'window=remote:busyproof', 'endpoint_task_id=busyproof', f'worktree={hosthome}',
        f'project={hostroot}', f'home={hosthome}', 'harness=claude',
        'kind=secondmate', 'mode=secondmate', 'remote_host=fm-lab-loopback',
        f'remote_root={hostroot}', 'remote_backend=herdr', f'remote_herdr_session={session}', f'remote_target={session}:{pane}',
    ]) + '\n'
    (parent / 'state/busyproof.meta').write_text(parentmeta)
    (parent / 'data/secondmates.md').write_text(f'- busyproof - Lab (host: fm-lab-loopback; root: {hostroot}; home: {hosthome}; scope: lab; projects: lab; added 2026-11-04)\n')
    keydir = work / 'ssh'
    keydir.mkdir()
    for name in ('host', 'client'):
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(keydir / name)], check=True)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    hostpub = (keydir / 'host.pub').read_text().split()
    (keydir / 'known_hosts').write_text(f'[127.0.0.1]:{port} {hostpub[0]} {hostpub[1]}\n')
    bridge = keydir / 'entry.py'
    bridge_env = {key: env[key] for key in ('PATH', 'HOME', 'USER', 'LANG', 'TERM', 'DISABLE_AUTOUPDATER', 'FM_HERDR_LAB_STATE_DIR') if key in env}
    # This SSH fixture implements only the existing encoded bootstrap protocol;
    # it executes the real host control script and never synthesizes its result.
    bridge.write_text('import os,sys,shlex,base64\n'
        'args=shlex.split(os.environ["SSH_ORIGINAL_COMMAND"])\n'
        'assert len(args)==5 and args[0]=="fm-remote-entrypoint.sh"\n'
        'root=base64.b64decode(args[2]).decode(); home=base64.b64decode(args[3]).decode()\n'
        'argv=base64.b64decode(args[4]).decode().rstrip("\\0").split("\\0")\n'
        f'assert root=={str(hostroot)!r} and home=={str(hosthome)!r}\n'
        'assert argv==["fm-remote-secondmate-control.sh","relaunch","busyproof","claude","-","-"]\n'
        f'env={dict(bridge_env, FM_HOME=str(hosthome), FM_ROOT_OVERRIDE=str(hostroot), PATH=str(work / "safe-bin") + ":" + env["PATH"])!r}\n'
        'env.pop("NO_MISTAKES_GATE",None)\n'
        'os.chdir(root)\n'
        'os.execve(root+"/bin/"+argv[0],argv,env)\n')
    sshbin = keydir / 'ssh-client'
    sshbin.write_text('#!/usr/bin/env bash\nexec /usr/bin/ssh -F /dev/null -p ' + str(port) + ' -i ' + shlex.quote(str(keydir / 'client')) + ' -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=' + shlex.quote(str(keydir / 'known_hosts')) + ' -o Hostname=127.0.0.1 "$@"\n')
    sshbin.chmod(0o755)
    config = keydir / 'sshd_config'
    config.write_text(f'Port {port}\nListenAddress 127.0.0.1\nHostKey {keydir / "host"}\nPidFile {keydir / "sshd.pid"}\nAuthorizedKeysFile {keydir / "client.pub"}\nStrictModes no\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nAllowUsers {os.environ["USER"]}\nForceCommand {shutil.which("python3")} {bridge}\nLogLevel ERROR\n')
    with (evid / 'loopback-sshd.log').open('w') as log:
        server = subprocess.Popen([shutil.which('sshd'), '-D', '-e', '-f', str(config)], env=env, stdout=log, stderr=log)
        try:
            for attempt in range(50):
                if server.poll() is not None:
                    raise RuntimeError('disposable sshd exited: ' + (evid / 'loopback-sshd.log').read_text())
                with socket.socket() as probe:
                    if probe.connect_ex(('127.0.0.1', port)) == 0:
                        break
                time.sleep(.1)
            childenv = dict(env, FM_HOME=str(parent), FM_SSH_BIN=str(sshbin))
            p = subprocess.run([str(root / 'bin/fm-remote-secondmate-relaunch.sh'), 'busyproof', 'claude', '-', '-'], env=childenv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
            record(f'$ fm-remote-secondmate-relaunch.sh busyproof claude - - (real loopback SSH to actual host control)\nexit={p.returncode}\n{p.stdout}{p.stderr}')
            if p.returncode == 1 and "expected 'fm-remote'" in p.stderr:
                record('UNTESTED full remote busy propagation: actual SSH and real host controller reached the endpoint guard, which requires fm-remote; the mandatory lab helper permits only fm-lab-* names. The full path cannot reach fm-control without changing that production guard or using a forbidden non-lab session. Targeted remote wrapper fixtures cover status-75 propagation separately.')
                return
            assert p.returncode == 75 and 'busy: background shell running' in p.stderr
            assert (parent / 'state/busyproof.meta').read_text() == parentmeta
            assert (hosthome / 'state/parent-route/busyproof.meta').read_text() == hostmeta
            assert not (work / 'control-input.log').exists()
            record('PASS remote relaunch over actual SSH: status 75 preserved; parent and host metadata unchanged; no lifecycle input')
        finally:
            server.terminate()
            rc = server.wait(timeout=10)
            record(f'loopback sshd stopped and reaped: exit={rc}')
