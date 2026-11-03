import os,pathlib,subprocess,socket,shutil
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M6GJ8YJKZ2XE36Z9WMW993A5'); lab=R/'.remote-ack'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','REX_')) and k not in ('TMUX','NO_MISTAKES_GATE')}
log=(E/'live-remote-ack.log').open('w',buffering=1)
def run(args,expected=0):
 p=subprocess.run(list(map(str,args)),cwd=R,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30)
 log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'[exit {p.returncode}]\n')
 assert p.returncode==expected,(p.returncode,p.stdout)
 return p.stdout
try:
 run([R/'bin/fm-lab-home.sh','create',lab])
 env['FM_HOME']=str(lab)
 sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
 wrapper=lab/'ssh-isolated'
 wrapper.write_text(f'#!/bin/sh\nexec /usr/bin/ssh -F /dev/null -o HostName=127.0.0.1 -o Port={port} -o ConnectTimeout=1 -o IdentityFile=/dev/null -o IdentitiesOnly=yes "$@"\n');wrapper.chmod(0o700)
 env['FM_SSH_BIN']=str(wrapper)
 (lab/'data/secondmates.md').write_text(f'- eel-web - Disposable route (host: lab-peer; root: {R}; home: {lab}/remote; scope: verification; projects: none; added 2026-11-03)\n')
 record=lab/'config/secondmate-parked/eel-web'
 for verb in ('park','unpark'):
  out=run([R/'bin/fm-secondmate-park.sh',verb,'eel-web'],1)
  assert 'not confirmed; local park retained' in out and record.exists()
  assert 'parked: eel-web:' not in out and 'unparked: eel-web' not in out
  run([R/'bin/fm-secondmate-park.sh','status','eel-web'])
 sock.close()
 log.write('SCENARIO PASS: real SSH connection failure cannot report successful park or unpark; both retain the local recovery block\n')
finally:
 shutil.rmtree(lab,ignore_errors=True); log.close()
