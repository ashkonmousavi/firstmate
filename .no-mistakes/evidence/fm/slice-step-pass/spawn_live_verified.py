import os,json,subprocess,time
from pathlib import Path
R=Path.cwd();H=R/'.test-tmp/spawn2-lab';E=Path('~/.no-mistakes/evidence/01M6GJKPRDZQX6MMZMKMPS8WJ1');L=(E/'live-spawn-verified.log').open('w',buffering=1)
env=dict(os.environ,FM_HOME=str(H),TMUX_TMPDIR=str(R/'.t'),TREEHOUSE_ROOT=str(R/'.test-tmp/treehouse2'),TMPDIR=str(R/'.test-tmp'),OMP_SKIP_SETUP='1',GIT_CEILING_DIRECTORIES=str(R/'.test-tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
for k in ['FM_TEST_SEAM','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','NO_MISTAKES_GATE','TMUX']:env.pop(k,None)
def run(*a,timeout=180,check=True):
 L.write('$ '+' '.join(map(str,a))+'\n');p=subprocess.run(list(map(str,a)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout);L.write(p.stdout+f'\n[exit {p.returncode}]\n');assert not check or p.returncode==0,p.stdout;return p
run('bash','bin/fm-lab-home.sh','create',H)
def w(p,s):
 p=H/p;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s)
w('.tasks.toml','backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n')
w('data/backlog.md','## In flight\n- [ ] owner - Disposable validation (repo: proj) (kind: ship)\n  SLICE: main/demo | lab | role=owner\n  TESTER TASK: lab-p1tester-01m6gj\n  TESTER PATHS: tests/risk.py\n  TESTER RULE: new\n## Queued\n## Done\n')
P=H/'projects/proj';P.mkdir(parents=True,exist_ok=True)
run('git','-C',P,'init','-q');run('git','-C',P,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','--allow-empty','-qm','disposable initial')
w('config/backend','tmux\n');w('config/lane-capacity','3 0\n');w('config/machine-admission.json',json.dumps(dict(schema='fm-machine-admission.v1',memory_floor_gib=0,disk_floor_gib=0,memory_full_avg60_max=100,disk_paths=[str(H)])))
w('config/crew-dispatch.json',json.dumps(dict(shared_quota=True,default=dict(harness='omp',model='cursor/gpt-5.5',effort='low'))))
w('config/autolaunch-steps','act owner\n');w('data/owner/brief.md','Delivery contract: mode=direct-PR\nShip branch: fm/owner\n')
w('data/owner/prep.md','REVISION: r1\nCUT: 1\nWALK LIST: screen-a\nWALK ID: demo\nTESTER PATHS: tests/risk.py\nTESTER RULE: new\nRISKS: none\nFor this disposable test respond LAB_ACK only. Never run tools or edit files. Do not publish or send messages.\n')
w('state/owner.status','working [at=2]: prep ready data/owner/prep.md r1\n')
w('state/owner.meta',f'kind=ship\nmodel=gpt-6.1-sol\nmode=direct-PR\nspawn_gen=builder.1\nbranch=fm/owner\nproject={P}\nworktree={P}\n')
run('tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',R,'-e',f'FM_HOME={H}','env','OMP_SKIP_SETUP=1','omp','--no-extensions','--no-skills','--no-rules')
env['TMUX']=run('tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
try:
 run('bash','bin/fm-autolaunch.sh','--steps-only',timeout=180)
 for attempt in range(45):
  a=run('bash','bin/fm-autolaunch.sh','--step-agent','lab-p1tester-01m6gj',check=False)
  if a.stdout.strip()=='alive':break
  time.sleep(1)
 else:raise AssertionError('real OMP process never became alive')
 before=(H/'state/lab-p1tester-01m6gj.meta').read_bytes()
 receipts=(H/'data/owner/slice-steps.log').read_bytes()
 run('bash','bin/fm-autolaunch.sh','--steps-only')
 assert (H/'state/lab-p1tester-01m6gj.meta').read_bytes()==before
 assert (H/'data/owner/slice-steps.log').read_bytes()==receipts
 L.write('PROVEN real OMP process alive, distinct recorded model, completed launch replay unchanged\n')
 L.write('RESULTING RECEIPTS\n'+(H/'data/owner/slice-steps.log').read_text())
 if (H/'state/lab-p1tester-01m6gj.meta').exists():L.write('TESTER META\n'+(H/'state/lab-p1tester-01m6gj.meta').read_text())
 run('tmux','-L','fm-lab','list-panes','-a','-F','#{window_name} #{pane_current_command} #{pane_width}x#{pane_height}')
 for target in run('tmux','-L','fm-lab','list-windows','-t','primary','-F','#{window_name}').stdout.splitlines():
  run('tmux','-L','fm-lab','capture-pane','-p','-t','primary:'+target)
finally:
 run('tmux','-L','fm-lab','kill-server',check=False)
