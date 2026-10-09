import os,pathlib,subprocess,time,shutil,json,sys
root=pathlib.Path('/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4F2NZEMTNTG7A1KQNEJ55Y7')
evid=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M4F2NZEMTNTG7A1KQNEJ55Y7')
harness=sys.argv[1] if len(sys.argv)>1 else 'claude'
lab=root/'.lp'
assert not lab.exists()
lab.mkdir()
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ['NO_MISTAKES_GATE','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_SESSION_ID','HERDR_PANE_ID']:env.pop(k)
env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'tmux'))
def run(args,check=True):
    p=subprocess.run(args,cwd=root,env=env,capture_output=True,text=True,timeout=30)
    print(json.dumps(dict(command=args,exit=p.returncode,stdout=p.stdout,stderr=p.stderr),ensure_ascii=False),flush=True)
    if check and p.returncode:raise RuntimeError('command failed')
    return p.stdout
try:
    run([str(root/'bin/fm-lab-home.sh'),'create',str(lab)])
    (lab/'tmux').mkdir()
    (lab/'config/supervision-host-off').touch()
    run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','100','-y','30','-c',str(root),'-e','FM_HOME='+str(lab),harness])
    time.sleep(6)
    text=run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary'])
    (evid/(harness+'-primary-screen.txt')).write_text(text)
    socket=run(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path}']).strip()
    env['TMUX']=socket+',0,0'
    (lab/'state/one.meta').write_text('kind=ship\nmode=local-only\nharness='+harness+'\nbackend=tmux\nwindow=primary:0\nworktree='+str(root)+'\n')
    state=run([str(root/'bin/fm-crew-state.sh'),'one'])
    (evid/(harness+'-primary-current-state.txt')).write_text(state)
finally:
    run(['tmux','-L','fm-lab','kill-server'],False)
    shutil.rmtree(lab)
    print('TEARDOWN private server stopped and marked lab home removed',flush=True)
