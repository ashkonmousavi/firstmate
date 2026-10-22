import os, pathlib, subprocess, re, json
root=pathlib.Path.cwd()
lab=root/'.live-handoff'
repo=lab/'repo'
home=lab/'home'
env=os.environ.copy()
for key in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS'):
    env.pop(key,None)
env['NM_HOME']=str(lab/'nm')
def run(args, **kw):
    return subprocess.run(args, env=env, text=True, capture_output=True, **kw)
r=run(['bin/fm-lab-home.sh','create',str(home)])
assert r.returncode==0, r.stderr
env['FM_HOME']=str(home)
status=home/'state/ship.status'
meta=home/'state/ship.meta'
def append(kind,mode,text):
    meta.write_text(f'kind={kind}\nmode={mode}\nworktree={repo}\n')
    r=run(['bin/fm-status-append.sh',str(status),'done'],input=text+'\n')
    assert r.returncode==0, r.stderr
    line=status.read_text().splitlines()[-1]
    print(line)
    return line
sha=run(['git','-C',str(repo),'rev-parse','HEAD']).stdout.strip()
scout=append('scout','no-mistakes','scout report before promotion')
assert '[handoff=' not in scout
ship=append('ship','no-mistakes','café: complete before validation')
assert re.fullmatch(r'done \[at=\d+\] \[handoff='+sha+r'\]: café: complete before validation',ship),ship
r=run(['git','-C',str(repo),'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','--allow-empty','-m','new handoff head'])
assert r.returncode==0,r.stderr
newsha=run(['git','-C',str(repo),'rev-parse','HEAD']).stdout.strip()
assert sha!=newsha
new=append('ship','no-mistakes','handoff on new head')
assert f'[handoff={newsha}]' in new
direct=append('ship','direct-PR','direct PR complete')
assert '[handoff=' not in direct
print('Persisted status contract verified: promotion stamps only the ship event; UTF-8 is retained; a changed HEAD gets its own stamp; direct-PR stays untagged.')
r=run(['no-mistakes','axi','status'],cwd=repo)
print('Isolated no-mistakes inventory attempt (exit '+str(r.returncode)+'):\n'+r.stdout+r.stderr)
assert 'repo not initialized' in r.stdout+r.stderr
