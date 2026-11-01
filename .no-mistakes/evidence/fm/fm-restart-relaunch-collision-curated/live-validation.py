import os, pathlib, subprocess, tempfile, time, json, shutil
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M6ABB3CG4YQMA6RX128VE4E6')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=E)); sm=pathlib.Path(tempfile.mkdtemp(prefix='sm.',dir=E))
log=open(E/'live-driver.log','w',buffering=1)
env=os.environ.copy()
for k in list(env):
 if k.endswith('_OVERRIDE') and k.startswith('FM_') or k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TASK_ID']: env.pop(k,None)
env.update(FM_HOME=str(lab),FM_BACKEND='tmux',TMUX_TMPDIR=str(lab/'tmux'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
def run(args,**kw):
 p=subprocess.run([str(x) for x in args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,**kw); log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+'\nexit='+str(p.returncode)+'\n'); return p
try:
 run(['bin/fm-lab-home.sh','create',lab]); run(['bin/fm-lab-home.sh','create',sm]); (lab/'tmux').mkdir()
 (lab/'config'/'supervision-host-off').touch(); (lab/'config'/'backend').write_text('tmux\n'); (lab/'config'/'secondmate-harness').write_text('codex\n')
 for k in ['supervision-host-off']: (sm/'config'/k).touch()
 (sm/'.fm-secondmate-home').write_text('sm1\n'); shutil.copyfile(R/'AGENTS.md',sm/'AGENTS.md'); (sm/'bin').symlink_to(R/'bin',target_is_directory=True)
 (sm/'.gitignore').write_text('state/\ndata/\nconfig/\nprojects/\n.fm-*\n')
 run(['git','-C',sm,'init','-q']); run(['git','-C',sm,'add','AGENTS.md','bin','.gitignore']); run(['git','-C',sm,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','disposable validation fixture'])
 (lab/'data'/'sm1').mkdir(); (lab/'data'/'sm1'/'brief.md').write_text('# Charter\nIsolated restart validation target. Do not run session-start, supervision, delegation, network checks, or edit anything outside this disposable home. There is no real work here. Acknowledge you are ready and await parent instructions. When asked to persist open work, there is none; reply done carrying the correlation token using bin/fm-secondmate-report.sh with FM_HOME set to this home.\n# Routing scope\nDisposable restart lab only.\n')
 run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',R,'-e','FM_HOME='+str(lab),'codex'])
 time.sleep(3)
 p=run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary']); (E/'primary-start.txt').write_text(p.stdout)
 actor=lab/'spawn.sh'; actor.write_text('#!/bin/bash\ncd '+str(R)+'\n'+str(R)+'/bin/fm-spawn.sh sm1 '+str(sm)+' --secondmate --harness codex > '+str(E/'live-spawn.log')+' 2>&1\nprintf "%s\\n" "$?" > '+str(lab/'spawn.rc')+'\n')
 run(['tmux','-L','fm-lab','new-window','-d','-t','primary','-n','driver','-c',R,'bash',actor])
 deadline=time.time()+100
 while time.time()<deadline and not (lab/'spawn.rc').exists():
  time.sleep(2)
  p=run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-sm1']); (E/'mate-start.txt').write_text(p.stdout)
 if (lab/'spawn.rc').exists(): log.write('spawn exit='+ (lab/'spawn.rc').read_text())
 # Give the controlling test agent a bounded inspection window, then clean up.
 (R/'.test-tmp'/'live-paths.json').write_text(json.dumps({'lab':str(lab),'sm':str(sm)}))
 deadline=time.time()+600
 while time.time()<deadline and not (lab/'finish').exists(): time.sleep(1)
finally:
 run(['tmux','-L','fm-lab','kill-server'])
 shutil.rmtree(lab); shutil.rmtree(sm); log.write('CLEANUP complete\n'); log.close()
