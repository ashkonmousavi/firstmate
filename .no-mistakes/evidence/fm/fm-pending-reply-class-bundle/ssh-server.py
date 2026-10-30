import asyncio, asyncssh, base64, json, os, pathlib, shlex, sys
root=pathlib.Path.cwd(); lab=root/'.lv'; log=open(lab/'ssh.log','a',buffering=1)
key=asyncssh.generate_private_key('ssh-ed25519'); key.write_private_key(lab/'client-key'); (lab/'client-key').chmod(0o600)
class Server(asyncssh.SSHServer):
    def begin_auth(self,username): return True
    def public_key_auth_supported(self): return True
    def validate_public_key(self,username,public): return public==key.convert_to_public()
async def execute(proc):
    child=None
    try:
        args=shlex.split(proc.command)
        assert len(args)==5 and args[0]=='fm-remote-entrypoint.sh' and args[1]=='1',args
        home=pathlib.Path(base64.b64decode(args[3]).decode()); argv=base64.b64decode(args[4]).decode().rstrip('\0').split('\0')
        assert home.is_relative_to(lab) and argv[0]=='fm-remote-secondmate-control.sh',argv
        assert argv[1] in ('probe','inbox'),argv
        log.write(json.dumps({'event':'start','argv':argv,'time':asyncio.get_running_loop().time()})+'\n')
        slow=lab/'slow-corr'
        if argv[1]=='probe' and slow.exists() and argv[-1]==slow.read_text().strip():
            (lab/'probe-started').touch(); await asyncio.sleep(25)
        env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','NO_MISTAKES','TASKS_AXI'))}
        env.update(FM_HOME=str(home),HOME=str(lab/'account'),TMPDIR=str(lab/'tmp'))
        child=await asyncio.create_subprocess_exec(str(root/'bin'/argv[0]),*argv[1:],env=env,stdin=asyncio.subprocess.DEVNULL,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
        out,err=await child.communicate(); proc.stdout.write(out.decode()); proc.stderr.write(err.decode())
        log.write(json.dumps({'event':'end','argv':argv,'exit':child.returncode,'stdout':out.decode(),'stderr':err.decode()})+'\n'); proc.exit(child.returncode)
    except Exception as exc:
        log.write(json.dumps({'event':'error','error':str(exc)})+'\n')
        try: proc.exit(255)
        except Exception: pass
    finally:
        if child and child.returncode is None: child.terminate(); await child.wait()
async def main():
    listener=await asyncssh.create_server(Server,'127.0.0.1',0,server_host_keys=[asyncssh.generate_private_key('ssh-ed25519')],process_factory=execute)
    port=listener.get_port()
    (lab/'ssh-config').write_text(f'Host fm-validation\n HostName 127.0.0.1\n Port {port}\n User lab\n IdentityFile {lab}/client-key\n IdentitiesOnly yes\n StrictHostKeyChecking no\n UserKnownHostsFile /dev/null\n LogLevel ERROR\n')
    wrapper=lab/'ssh';wrapper.write_text(f'#!/bin/sh\nexec /usr/bin/ssh -F {shlex.quote(str(lab/"ssh-config"))} "$@"\n');wrapper.chmod(0o700)
    (lab/'ssh-ready').write_text(str(port)); await listener.wait_closed()
asyncio.run(main())
