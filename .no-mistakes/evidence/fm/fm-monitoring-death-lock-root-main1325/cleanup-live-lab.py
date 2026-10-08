import os,pathlib,signal,subprocess,time,shutil
root=pathlib.Path.cwd(); lab=root/'.nm-live-lab'; state=lab/'state'
evidence=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M4CTRP889M62SSJ6FJS0DFN7')
known=set()
for p in [state/'.watch.lock/pid',state/'.lock',lab/'holder-process']:
    if p.exists():
        try:known.add(int(p.read_text().strip()))
        except ValueError:pass
for p in state.glob('.supervision-host*'):
    if p.is_file() and not p.name.endswith('.log'):
        for line in p.read_text().splitlines():
            columns=line.split('\t')
            if len(columns)>1 and columns[0] in ['host','arm'] and columns[1].isdigit(): known.add(int(columns[1]))
p=state/'.claude-autoarm-epoch'
if p.exists():
    for word in p.read_text().split():
        if word.startswith('owner_pid='):known.add(int(word.split('=')[1]))
# Capture each recorded process birth before stopping only this private socket.
births={}
for pid in known:
    try:births[pid]=pathlib.Path('/proc',str(pid),'stat').read_text().split(') ')[1].split()[19]
    except FileNotFoundError:pass
env=os.environ.copy(); env['TMUX_TMPDIR']=(state/'.fm-lab-tmux-dir').read_text().strip()
p=subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,capture_output=True,text=True)
print('Private fm-lab tmux server stop: exit',p.returncode,p.stdout+p.stderr,flush=True)
time.sleep(1)
for sig in [signal.SIGTERM,signal.SIGKILL]:
    for pid,birth in births.items():
        try:
            data=pathlib.Path('/proc',str(pid),'stat').read_text().split(') ')[1].split()
            if data[19]==birth and data[0]!='Z':
                os.kill(pid,sig);print('Stopped lab-recorded process',pid,'signal',sig,flush=True)
        except FileNotFoundError:pass
    time.sleep(.3)
for pid,birth in births.items():
    try:
        data=pathlib.Path('/proc',str(pid),'stat').read_text().split(') ')[1].split()
        assert data[19]!=birth or data[0]=='Z',('still live',pid)
    except FileNotFoundError:pass
p=subprocess.run(['bash','bin/fm-lab-home.sh','teardown',str(lab)],capture_output=True,text=True)
print('Private socket directory teardown: exit',p.returncode,p.stdout+p.stderr,flush=True);assert p.returncode==0
shutil.rmtree(lab)
(root/'.fm-secondmate-home').unlink()
print('Lab home and temporary primary-scope marker removed. All recorded lab processes stopped.',flush=True)
