import os,json,subprocess,time,hashlib
from pathlib import Path
R=Path.cwd(); H=R/'.test-tmp/live-lab'; E=Path('~/.no-mistakes/evidence/01M6GJKPRDZQX6MMZMKMPS8WJ1')
log=(E/'live-product.log').open('w',buffering=1)
env=dict(os.environ,FM_HOME=str(H),TMUX_TMPDIR=str(R/'.t'),GIT_CEILING_DIRECTORIES=str(R/'.test-tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
for k in list(env):
 if k.startswith('FM_AUTOLAUNCH_') or k in ('FM_TEST_SEAM','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR'): env.pop(k,None)
def cmd(*args,ok=(0,),timeout=60):
 p=subprocess.run(list(map(str,args)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'[exit {p.returncode}]\n')
 assert p.returncode in ok,(args,p.returncode,p.stdout)
 return p.stdout
def w(p,s):
 p=H/p;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s)
def rows():
 p=H/'data/owner/slice-steps.log';return [json.loads(s) for s in p.read_text().splitlines()] if p.exists() else []
def step():return cmd('bash',R/'bin/fm-autolaunch.sh','--steps-only')
def snap():return {str(p.relative_to(H)):hashlib.sha256(p.read_bytes()).hexdigest() for p in H.rglob('*') if p.is_file()}
def record(name,detail):
 log.write('PROVEN '+name+': '+detail+'\n'); results.append(dict(name=name,result='pass',live=True,evidence='live-product.log',reason=''))
results=[]
w('.tasks.toml','backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
w('data/backlog.md','## In flight\n- [ ] owner - Disposable validation (repo: proj) (kind: ship)\n  SLICE: main/demo | lab | role=owner\n  TESTER TASK: special-tester\n  TESTER RULE: new\n  TESTER PATHS: tests/risk.py\n## Queued\n## Done\n')
(H/'projects/proj').mkdir(parents=True,exist_ok=True)
cmd('git','-C',H/'projects/proj','init','-q');cmd('git','-C',H/'projects/proj','-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','--allow-empty','-qm','disposable initial')
w('state/owner.meta',f'kind=ship\nbackend=tmux\nharness=codex\nmodel=gpt-6.1-sol\nspawn_gen=lab.1\nwindow=primary:fm-owner\nendpoint_task_id=owner\nmode=direct-PR\nbranch=fm/owner\nworktree={H}/projects/proj\nproject={H}/projects/proj\n')
w('data/owner/prep.md','REVISION: r1\nCUT: 1\nWALK ID: demo\nWALK LIST: screen-a,screen-b\nTESTER PATHS: tests/risk.py\nTESTER RULE: new\nRISKS: none\nDisposable validation only: respond LAB_ACK; do not run commands or edit any files.\n')
w('data/owner/brief.md','Delivery contract: mode=direct-PR\nShip branch: fm/owner\n')
w('state/owner.status','working [at=2]: prep ready data/owner/prep.md r1\n')
b=snap();assert step()=='';assert snap()==b
record('Absent step configuration leaves the home untouched','prepared owner, zero output and byte-identical files')
w('config/autolaunch-steps','observe owner\n');b=snap();out=step();assert snap()==b and not rows()
record('Observe lease reports a trigger without performing it',out.strip())
w('config/autolaunch-steps','act owner\n');w('config/crew-dispatch.json',json.dumps({'shared_quota':True,'default':{'harness':'codex','model':'gpt-6.1-sol'}}))
step();rr=rows();log.write('STEP RECEIPTS\n'+json.dumps(rr,indent=2)+'\n')
assert any(r['trigger']=='prep:r1:file' and r['receipt']=='completed' for r in rr)
assert not (H/'state/special-tester.meta').exists()
assert any(r['receipt']=='pending' and r.get('effect',{}).get('kind')=='launch-tester' for r in rr)
shown=cmd('bash',R/'bin/fm-tasks-axi.sh','show','special-tester','--full');assert 'role=tester owner=main:owner' in shown
b=rows();step();assert rows()==b
record('Prep files the named tester once and refuses the builder model','one real task, completed filing receipt, pending launch, no tester process or metadata, replay unchanged')
# Deliver a new, proof-reusing cut directly to the genuinely running lab owner.
w('config/autolaunch-steps','observe owner\n')
w('data/owner/slice-steps.log',json.dumps(dict(at=1,generation=1,step='build',owner='owner',trigger='tests-ready:none@r1',receipt='completed',revision='r1'))+'\n')
w('data/owner/prep.md',(H/'data/owner/prep.md').read_text().replace('REVISION: r1','REVISION: r2'))
w('state/owner.status','working [at=4]: cut ready data/owner/prep.md r2 walk_changed=no risk_changed=no\n')
socket=cmd('tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path},#{pid},0').strip();env['TMUX']=socket
assert cmd('bash',R/'bin/fm-autolaunch.sh','--step-agent','owner').strip()=='alive'
w('config/autolaunch-steps','act owner\n');step();rr=rows();log.write('CUT RECEIPTS\n'+json.dumps(rr,indent=2)+'\n')
assert any(r['trigger']=='cut:owner@1:r2' and r['receipt']=='completed' for r in rr)
inbox=list((H/'state/owner.inbox').glob('*.msg'))+list((H/'state/owner.inbox/handled').glob('*.msg'));assert len(inbox)==1
log.write('DURABLE INBOX RECORD\n'+inbox[0].read_text()+'\n')
b=rows();step();assert rows()==b
assert len(list((H/'state/owner.inbox').glob('*.msg'))+list((H/'state/owner.inbox/handled').glob('*.msg')))==1
record('A changed cut reaches a live owner once through its durable inbox','real Codex pane classified alive; one completed cut receipt and one inbox record after replay; no spawn')
# Simulate the accepted walk-only tester result as durable input, never a fake executable.
w('data/owner/prep.md',(H/'data/owner/prep.md').read_text().replace('REVISION: r2','REVISION: r3').replace('screen-a,screen-b','screen-a,screen-c'))
w('state/owner.status','working [at=5]: cut ready data/owner/prep.md r3 walk_changed=yes risk_changed=no\n')
w('state/special-tester.meta',f'kind=scout\nharness=codex\nmodel=gpt-6.1-sol\nspawn_gen=tester-record.1\nworktree={H}/projects/proj\nproject={H}/projects/proj\n')
step();assert not any(r['trigger']=='cut:owner@1:r3' and r['receipt']=='completed' for r in rows())
record('Changed walk coverage cannot resume the builder with an equal-model tester','cut tester handoff remains pending and no second owner inbox record appears')
# Real C2 evaluates an interrupted reasonless receipt after a completed pass.
r=rows()[-1];assert r['receipt']=='pending';r.pop('reason',None);p=H/'data/owner/slice-steps.log';p.write_text(p.read_text()+json.dumps(r)+'\n')
w('state/autolaunch-steps.pass',json.dumps(dict(at=int(time.time())+1,owners=['owner'])))
out=cmd('bash',R/'bin/fm-autolaunch-check.sh');assert out.count('RED')==1
assert cmd('bash',R/'bin/fm-autolaunch-check.sh')==''
r['receipt']='completed';p.write_text(p.read_text()+json.dumps(r)+'\n');w('config/autolaunch-steps','observe owner\n');assert cmd('bash',R/'bin/fm-autolaunch-check.sh')=='';assert not (H/'state/.autolaunch-check.red').exists()
record('C2 reports one reasonless pending episode and clears after completion','one RED line, silent second evaluation, cleared marker')
# Empty observation set is valid through both actual CLI consumers.
cmd('bash',R/'bin/fm-lab-home.sh','create',R/'.test-tmp/empty-lab');empty=R/'.test-tmp/empty-lab';(empty/'config/autolaunch-steps').write_text('observe\n');env['FM_HOME']=str(empty)
cmd('bash',R/'bin/fm-autolaunch.sh','--steps-only');assert cmd('bash',R/'bin/fm-autolaunch-check.sh')==''
record('Bare observe on a new home is a valid no-op','step pass and C2 both exit zero without alerts')
(E/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
log.write('ALL LIVE CHECKS COMPLETED\n')
