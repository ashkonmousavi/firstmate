import os,pathlib,subprocess,json
root=pathlib.Path.cwd();home=root/'.lv/home'
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6DT06J8Z2BFSHPD3NGJXK0H')
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') and (k.endswith('_OVERRIDE') or k=='FM_GATE_REFUSE_BYPASS'):env.pop(k)
sock=(root/'.lv/socket-dir').read_text().strip()
env.update(FM_HOME=str(home),FM_BACKEND='tmux',TMUX_TMPDIR=sock,TMUX=f'{sock}/tmux-{os.getuid()}/fm-lab,0,0',FM_SECONDMATE_PERSIST_WAIT='0')
(home/'state/baseprobe.meta').write_text(f'window=primary:fm-probe\nbackend=tmux\nharness=codex\nkind=secondmate\nworktree={root}\nhome={home}\n')
(home/'state/baseprobe.inbox').write_text('Blocked inbox for before/after reproduction\n')
outputs={}
for label,cmd in [('base','bin/.lv-base-restart.sh'),('target','bin/fm-secondmate-restart.sh')]:
    p=subprocess.run(['bash',cmd,'baseprobe'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
    assert p.returncode==3,p.stdout
    outputs[label]={'command':f'bash {cmd} baseprobe','exit':p.returncode,'output':p.stdout}
assert 'steer not sent' not in outputs['base']['output'],outputs
assert 'fm-gate-refuse: gate agent lifecycle permitted only against lab home' in outputs['base']['output'],outputs
assert outputs['target']['output'].count('steer not sent')==2,outputs
(evidence/'before-after-diagnostic.json').write_text(json.dumps(outputs,indent=2))
print(json.dumps(outputs,indent=2))
