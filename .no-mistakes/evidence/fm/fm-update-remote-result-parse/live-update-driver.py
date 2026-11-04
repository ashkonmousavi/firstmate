"""Disposable SSH integration driver. Run from the gate worktree with Paramiko on PYTHONPATH.
The SSH server dispatches real remote-control commands directly, avoiding account-wide
entrypoint installation and remote-job daemons. It appends real rearm output and can
inject transport-response corruption. No update parser or Git operation is replaced.
No real harness is launched: an intentionally unverified endpoint exercises the
product's conservative restart-candidate policy; this never executes a restart.
"""
import base64, io, json, os, pathlib, shlex, shutil, socket, subprocess, tarfile, threading, time
import paramiko
R = pathlib.Path.cwd()
E = pathlib.Path(__file__).parent
W = R / '.test-phase/live'
W.mkdir(parents=True)
ENV = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'GIT_', 'HERDR_', 'REX_', 'TASKS_AXI_')) and k not in ['HOME','TMUX','CLAUDECODE','NO_MISTAKES_GATE']}
ENV.update(HOME=str(W/'account'), TMPDIR=str(R/'.test-phase/tmp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid', GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid', PATH='/usr/bin:/bin')
(W/'account').mkdir()
def call(args, **kw):
    return subprocess.run([str(a) for a in args], env=ENV, capture_output=True, text=True, check=True, timeout=120, **kw).stdout.strip()
def git(at, *args): return call(['git','-C',at,*args])
seed=W/'seed'
seed.mkdir()
archive=subprocess.check_output(['git','archive','HEAD','bin','AGENTS.md','README.md','.gitignore','.agents'])
with tarfile.open(fileobj=io.BytesIO(archive)) as tf: tf.extractall(seed, filter='data')
call(['git','init','-q','--initial-branch=main',seed])
git(seed,'add','-A'); git(seed,'commit','-qm','seed with actual gate product')
origin=W/'origin.git'
call(['git','clone','-q','--bare',seed,origin])
git(seed,'remote','add','origin',origin)
primary=W/'primary'; remote=W/'remote'; home=W/'mate'; parent=W/'parent'
for p in [primary,remote,home]: call(['git','clone','-q',origin,p])
call(['bash',R/'bin/fm-lab-home.sh','create',parent])
for p in [remote,home]:
    for name in ['state','data','config']: (p/name).mkdir(exist_ok=True)
(home/'.fm-secondmate-home').write_text('sm1\n')
(home/'state/parent-route').mkdir()
# Deliberately unverified, with no server/session reference. Real state command
# returns unverified before it can access any Herdr server or fleet endpoint.
(home/'state/parent-route/sm1.meta').write_text('kind=secondmate\n')
(parent/'state/.last-watcher-beat').touch()
(parent/'state/sm1.meta').write_text(f'kind=secondmate\nharness=claude\nwindow=remote:sm1\nendpoint_task_id=sm1\nremote_host=loopback-lab\nremote_backend=herdr\nhome={home}\n')
(parent/'data/secondmates.md').write_text(f'- sm1 - isolated SSH integration (host: loopback-lab; root: {remote}; home: {home}; scope: parser proof; projects: fixture; added 2026-11-04)\n')
with (seed/'README.md').open('a') as f: f.write('\nDisposable integration update.\n')
git(seed,'add','README.md'); git(seed,'commit','-qm','advance isolated origin'); git(seed,'push','-q','origin','main')
target=git(seed,'rev-parse','HEAD')
listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(); listener.settimeout(.3)
port=listener.getsockname()[1]
hostkey=paramiko.RSAKey.generate(2048); key=paramiko.RSAKey.generate(2048)
key.write_private_key_file(str(W/'client-key')); os.chmod(W/'client-key',0o600)
(W/'known_hosts').write_text(f'[127.0.0.1]:{port} {hostkey.get_name()} {hostkey.get_base64()}\n')
(W/'ssh-config').write_text(f'Host loopback-lab\n HostName 127.0.0.1\n Port {port}\n User disposable\n IdentityFile {W}/client-key\n IdentitiesOnly yes\n UserKnownHostsFile {W}/known_hosts\n StrictHostKeyChecking yes\n BatchMode yes\n LogLevel ERROR\n')
(W/'ssh').write_text('#!/bin/bash\nexec /usr/bin/ssh -F '+shlex.quote(str(W/'ssh-config'))+' "$@"\n'); (W/'ssh').chmod(0o755)
mode='normal'; raw=[]; failures=[]; stop=threading.Event(); threads=[]; transports=[]
class Server(paramiko.ServerInterface):
    def check_auth_publickey(self,user,k): return paramiko.AUTH_SUCCESSFUL if user=='disposable' and k==key else paramiko.AUTH_FAILED
    def get_allowed_auths(self,user): return 'publickey'
    def check_channel_request(self,kind,cid): return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_exec_request(self,ch,command):
        self.command=command.decode(); self.ready.set(); return True
    def __init__(self): self.ready=threading.Event()
def serve(conn):
    transport=paramiko.Transport(conn); transports.append(transport)
    try:
        transport.add_server_key(hostkey); server=Server(); transport.start_server(server=server)
        ch=transport.accept(15)
        if ch is None or not server.ready.wait(15): raise RuntimeError('SSH session command missing')
        wire=shlex.split(server.command)
        assert wire[:2]==['fm-remote-entrypoint.sh','1'],wire
        root_arg,home_arg=[base64.b64decode(x).decode() for x in wire[2:4]]
        argv=[a.decode() for a in base64.b64decode(wire[4]).split(b'\0') if a]
        assert root_arg==str(remote) and home_arg==str(home),wire
        assert argv[0]=='fm-remote-secondmate-control.sh' and argv[1] in ['update','state'],argv
        env=ENV | {'FM_ROOT_OVERRIDE':str(remote),'FM_HOME':str(home),'FM_STATE_OVERRIDE':str(home/'state'),'FM_CONFIG_OVERRIDE':str(home/'config')}
        p=subprocess.run(['bash',str(remote/'bin'/argv[0]),*argv[1:]],cwd=remote,env=env,capture_output=True,timeout=90)
        out,err=p.stdout,p.stderr
        producer_out=out.decode(errors='replace')
        active_mode=mode
        if argv[1]=='update' and p.returncode==0:
            # A real helper emits the trailing diagnostics; not a canned status.
            rearm=subprocess.run(['bash',str(remote/'bin/fm-pr-check-rearm.sh')],env=env,capture_output=True,timeout=20,check=True)
            if active_mode=='earlier-status': out=b'current: '+b'b'*40+b'\n'+out
            if active_mode=='earlier-status-wrong-final': out=b'synced: '+target.encode()+b'\n'+out.replace(target.encode(),b'b'*40)
            if active_mode in ['missing','malformed']:
                out=b'\n'.join(line for line in out.splitlines() if not line.startswith((b'synced:',b'current:')))+b'\n'
                if active_mode=='malformed': out+=b'diagnostic: synced: '+target.encode()+b'\nsynced without colon\n'
            out+=rearm.stdout
            err+=rearm.stderr
        raw.append({'mode':active_mode,'argv':argv,'exit':p.returncode,'actual_product_stdout':producer_out,'wire_stdout':out.decode(errors='replace'),'wire_stderr':err.decode(errors='replace')})
        ch.sendall(out); ch.sendall_stderr(err); ch.send_exit_status(p.returncode)
        ch.shutdown_write()
        # Wait until the genuine SSH client consumes the result and closes.
        for _ in range(100):
            if ch.closed: break
            time.sleep(.01)
        ch.close()
    except Exception as e: failures.append(repr(e))
    finally: transport.close(); conn.close()
def accept():
    while not stop.is_set():
        try: c,_=listener.accept()
        except socket.timeout: continue
        except OSError: break
        t=threading.Thread(target=serve,args=(c,)); threads.append(t); t.start()
accept_thread=threading.Thread(target=accept); accept_thread.start()
results=[]
def drive(name, response_mode, expected, restart=True):
    global mode
    mode=response_mode
    env=ENV | {'FM_HOME':str(parent),'FM_ROOT_OVERRIDE':str(primary),'FM_SSH_BIN':str(W/'ssh'),'FM_UPDATE_REMOTE_UPDATE_SECONDS':'110','FM_UPDATE_REMOTE_STATE_SECONDS':'20'}
    p=subprocess.run(['bash',str(R/'bin/fm-update.sh')],cwd=R,env=env,text=True,capture_output=True,timeout=120)
    output=p.stdout+p.stderr
    (E/(name+'.log')).write_text(f'UTC: {time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())}\ncommand: bash bin/fm-update.sh (disposable FM_HOME, FM_ROOT_OVERRIDE, real SSH transport)\nresponse mode: {response_mode}\nexpected target: {target}\nexit status: {p.returncode}\n'+output)
    assert p.returncode==0,(name,output)
    assert expected in output,(name,expected,output)
    assert ('restart-secondmates: fm-sm1' if restart else 'restart-secondmates: none') in output,(name,output)
    assert 'nudge-secondmates: none' in output,(name,output)
    assert f'pr-poll-rearm: home={home} rearmed=0 left=0' in output,(name,output)
    for location in [primary,remote,home]: assert git(location,'rev-parse','HEAD')==target
    results.append({'name':name,'mode':response_mode,'exit':p.returncode,'primary_head':git(primary,'rev-parse','HEAD'),'remote_head':git(remote,'rev-parse','HEAD'),'mate_head':git(home,'rev-parse','HEAD'),'evidence':name+'.log'})
try:
    drive('live-synced','earlier-status',f'remote secondmate sm1: updated on loopback-lab ({target})')
    drive('live-current','earlier-status',f'remote secondmate sm1: already current on loopback-lab ({target})')
    drive('live-wrong-final','earlier-status-wrong-final',f'host reports {"b"*40}, not update target {target}',False)
    drive('live-missing','missing','skipped on loopback-lab: malformed update result',False)
    drive('live-malformed','malformed','skipped on loopback-lab: malformed update result',False)
    # Actual stopped endpoint boundary: the same settled home has no remote record.
    (home/'state/parent-route/sm1.meta').unlink()
    drive('live-missing-endpoint','normal',f'remote secondmate sm1: already current on loopback-lab ({target})',False)
finally:
    stop.set(); listener.close(); accept_thread.join(timeout=5)
    for transport in transports: transport.close()
    for t in threads: t.join(timeout=10)
    remaining=[t.name for t in threads if t.is_alive()]
    (E/'live-wire-transcript.json').write_text(json.dumps(raw,indent=2)+'\n')
    (E/'live-results.json').write_text(json.dumps({'target':target,'results':results,'server_errors':failures,'remaining_threads':remaining,'scope':'Real fm-update + fm-on + OpenSSH client + disposable Paramiko SSH server + real fm-remote-secondmate-control + real Git + real fm-pr-check-rearm. Test SSH dispatcher bypasses account-wide remote-job installation. Earlier status/corruption is fault injection. Endpoint unverified; no harness or restart launched.'},indent=2)+'\n')
    shutil.rmtree(W)
assert not failures,failures
assert not remaining,remaining
assert len(results)==6,results
print(json.dumps({'scenarios':results,'server_errors':failures,'remaining_threads':remaining},indent=2))
