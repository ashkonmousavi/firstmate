import os, json, subprocess, pathlib, time
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.test-tmp/live'; HOME=LAB/'home'; E=pathlib.Path('~/.no-mistakes/evidence/01M6NY9S7GT8ZQD7TVD95RD89G')
socketdir=(LAB/'socket-dir').read_text().strip()
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k.startswith('HERDR_') or k in ['NO_MISTAKES_GATE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX','TMUX_PANE']: env.pop(k,None)
env.update(FM_HOME=str(HOME),TREEHOUSE_ROOT=str(LAB/'pool'),TMUX_TMPDIR=socketdir)
def tmux(*args):
 return subprocess.run(['tmux','-L','fm-lab',*args],env=env,text=True,capture_output=True)
env['TMUX']=tmux('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
results=[]
def policy(mode='enforce'):
 p=HOME/'config/slicing.json'
 if mode is None: p.unlink(missing_ok=True); return
 p.write_text(json.dumps({'schema':'slice-policy.v1','mode':mode,'projects':['proj'],'catalog':str(LAB/'catalog.json'),'revision':'r1','activated_at':'2026-11-05T00:00:00Z','home':'test'}))
def brief(id,line=''):
 d=HOME/'data'/id; d.mkdir(exist_ok=True)
 (d/'brief.md').write_text('# Task\n## Captain\'s intent\nThis is a disposable live admission check. Reply LAB_OK and wait. Do not edit files or call tools.\n\n## Firstmate spec\nReply LAB_OK and wait for the supervisor.\n'+line+'\n')
def call(id,args,expected,needle='',validator=None):
 e=env.copy()
 if validator is not None: e['FM_SLICE_VALIDATOR']=str(validator)
 cmd=[str(ROOT/'bin/fm-spawn.sh'),id,*args]
 try:
  p=subprocess.run(cmd,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=110)
  out=p.stdout; rc=p.returncode
 except subprocess.TimeoutExpired as x:
  out=(x.stdout or b'').decode() if isinstance(x.stdout,bytes) else x.stdout or ''; rc=124
 log=E/(id+'.log'); log.write_text('$ '+' '.join(cmd)+'\n'+out+'\nEXIT_STATUS='+str(rc)+'\n')
 meta=HOME/'state'/(id+'.meta')
 proof={'id':id,'exit':rc,'expected_success':expected,'notice_or_reason':needle,'meta_exists':meta.exists(),'log':str(log)}
 if meta.exists():
  text=meta.read_text(); (E/(id+'.meta.txt')).write_text(text)
  fields=dict(l.split('=',1) for l in text.splitlines() if '=' in l)
  endpoint=fields.get('window','')
  if endpoint:
   cap=tmux('capture-pane','-p','-S','-180','-t',endpoint)
   (E/(id+'.terminal.txt')).write_text(cap.stdout+cap.stderr)
 proof['passed']=((rc==0)==expected and rc!=124 and (not needle or needle in out) and (meta.exists() if expected else not meta.exists()))
 results.append(proof); (E/'live-results.json').write_text(json.dumps(results,indent=2))
 print(json.dumps(proof),flush=True)
 return proof

results=json.loads((E/'live-results.json').read_text())
ship=lambda proj: [str(LAB/proj),'--mode','direct-PR','--yolo','off']
# Refusal with a readable authoritative task; compare durable state around admission.
policy(); brief('enforce-missing')
def snapshot():
 return {'branches':subprocess.check_output(['git','-C',str(LAB/'proj'),'branch','--format=%(refname)'],text=True),'worktrees':subprocess.check_output(['git','-C',str(LAB/'proj'),'worktree','list','--porcelain'],text=True),'backlog':(HOME/'data/backlog.md').read_text()}
before=snapshot(); call('enforce-missing',ship('proj'),False,'missing-slice'); after=snapshot()
(E/'refusal-side-effects.json').write_text(json.dumps({'before':before,'after':after,'unchanged':before==after},indent=2))
assert before==after
# A recovery must not even invoke the validator, despite newly invalid metadata.
for suffix in ['log','meta.txt','terminal.txt']:
 src=E/('valid.'+suffix)
 if src.exists(): src.rename(E/('valid-first.'+suffix))
p=subprocess.run([str(ROOT/'bin/fm-control.sh'),'valid','exit'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
(E/'relaunch-stop.log').write_text(p.stdout+'\nEXIT_STATUS='+str(p.returncode)+'\n'); print('control exit:',p.returncode,flush=True)
assert p.returncode==0,p.stdout
brief('valid'); (HOME/'data/valid/prep.md').unlink(missing_ok=True)
spy=LAB/'must-not-run.py'; spy.write_text("from pathlib import Path\nPath("+repr(str(LAB/'unexpected-gate-call'))+").write_text('called')\nraise SystemExit(2)\n")
old=(HOME/'state/valid.meta').read_text()
proof=call('valid',['--relaunch'],True,validator=spy)
assert not (LAB/'unexpected-gate-call').exists(), 'relaunch consulted gate'
new=(HOME/'state/valid.meta').read_text()
fields=lambda text: dict(l.split('=',1) for l in text.splitlines() if '=' in l)
(E/'relaunch-identity.json').write_text(json.dumps({'before':fields(old),'after':fields(new),'validator_invocations':0,'same_worktree':fields(old)['worktree']==fields(new)['worktree'],'same_endpoint':fields(old)['window']==fields(new)['window']},indent=2))
assert fields(old)['worktree']==fields(new)['worktree'] and fields(old)['window']==fields(new)['window']
(E/'relaunch.log').write_text((E/'valid.log').read_text())
# A new follow-up is fresh work and cannot use recovery's exemption.
brief('fresh-followup'); call('fresh-followup',ship('proj'),False,'missing-slice')
policy(); brief('unlisted-no-validator'); call('unlisted-no-validator',ship('other'),True,validator=LAB/'absent.py')
policy('observe'); brief('observe-no-validator'); call('observe-no-validator',ship('proj'),True,'not readable',LAB/'absent.py')
policy(None); brief('no-policy'); call('no-policy',ship('proj'),True,validator=spy)
assert not (LAB/'unexpected-gate-call').exists()
policy(); brief('scout'); call('scout',[str(LAB/'proj'),'--scout'],True,validator=spy)
assert not (LAB/'unexpected-gate-call').exists()
(E/'bypass-consultation.json').write_text(json.dumps({'validator_invocations_for_relaunch_no_policy_scout':0}))
