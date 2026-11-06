import json, os, pathlib, shutil, subprocess, time
R=pathlib.Path.cwd(); L=R/'.l'; E=pathlib.Path('~/.no-mistakes/evidence/01M6QATZCFP0RNDVNFA21RW85H')
log=[]; launched=False
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ['TMUX','NO_MISTAKES_GATE','TASKS_AXI_FILE']}
env.update(FM_HOME=str(L),TMUX_TMPDIR=str(L/'tmux'),TERM='xterm-256color')
def run(*args,check=True,timeout=30):
 p=subprocess.run([str(a) for a in args],env=env,text=True,capture_output=True,timeout=timeout)
 log.append('$ '+' '.join(str(a) for a in args)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
 if check and p.returncode: raise RuntimeError(log[-1])
 return p
try:
 run(R/'bin/fm-lab-home.sh','create',L)
 (L/'tmux').mkdir(); (L/'config/supervision-host').touch()
 # Nonzero 120x40 PTY; the only server addressed is this lab's fm-lab socket.
 run('tmux','-L','fm-lab','new-session','-d','-s','primary','-n','fm-lab-live','-x','120','-y','40','-c',R,'-e','FM_HOME='+str(L),'codex --no-daemon -c features.hooks=false')
 launched=True
 for i in range(12):
  time.sleep(1)
  shot=run('tmux','-L','fm-lab','capture-pane','-p','-t','primary').stdout
  if 'Ask Codex to do anything' in shot or 'context left' in shot or 'Hooks need review' in shot or 'trust this' in shot.lower(): break
 (E/'codex-live-terminal.txt').write_text(shot)
 assert ('Ask Codex to do anything' in shot or 'context left' in shot), 'Ready composer not observed: '+shot
 # The window endpoint belongs only to this lab task.
 run('tasks-axi','add','lab-live','live guard fixture','--kind','ship','--start','--file',L/'data/backlog.md')
 (L/'data/lab-live').mkdir()
 (L/'data/lab-live/brief.md').write_text("# Task\n## Captain's intent\nExercise the live guard.\n\n## Firstmate spec\nPreserve this real running TUI.\n")
 meta=L/'state/lab-live.meta'
 meta.write_text('window=primary:fm-lab-live\nendpoint_task_id=lab-live\nworktree='+str(R)+'\nproject='+str(R)+'\nharness=codex\nkind=ship\nmode=local-only\nyolo=off\nmodel=default\neffort=default\n')
 (L/'state/lab-live.status').write_text('done: ready in branch\n')
 socket=run('tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
 env['TMUX']=socket
 eligible=run(R/'bin/fm-stage-transition.sh','_eligible','lab-live').stdout.strip()
 assert eligible=='live',eligible
 before=meta.read_bytes()
 result=run(R/'bin/fm-control.sh','lab-live','relaunch','--if-stopped','--note','live refusal proof',check=False,timeout=90)
 assert result.returncode==3 and 'live' in result.stdout,result.stdout+result.stderr
 assert meta.read_bytes()==before
 assert not (L/'state/lab-live.control-relaunch').exists()
 run('tmux','-L','fm-lab','has-session','-t','primary')
 log.append('PASS: real Codex 0.166.0 remained alive; stopped-only relaunch deferred with exit 3 and unchanged metadata/no journal.\n')
finally:
 if launched:
  run('tmux','-L','fm-lab','kill-server')
  alive=run('tmux','-L','fm-lab','has-session','-t','primary',check=False)
  assert alive.returncode!=0
 (E/'live-worker-transcript.log').write_text('\n'.join(log))
 if L.exists(): shutil.rmtree(L)
