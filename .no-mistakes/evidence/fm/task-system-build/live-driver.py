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
ship=lambda proj: [str(LAB/proj),'--mode','direct-PR','--yolo','off']
policy(); brief('enforce-missing'); call('enforce-missing',ship('proj'),False,'missing-slice')
# Verify refusal caused no branch, worktree allocation, record, or backlog transition.
for args in [['git','-C',str(LAB/'proj'),'branch','--format=%(refname:short)'],['git','-C',str(LAB/'proj'),'worktree','list','--porcelain']]:
 p=subprocess.run(args,text=True,capture_output=True); (E/('refusal-'+('branches' if 'branch' in args else 'worktrees')+'.txt')).write_text(p.stdout)
policy(); brief('enforce-malformed'); (HOME/'config/slicing.json').write_text('{"mode":"enforce","projects":["proj"]}')
call('enforce-malformed',ship('proj'),False,'policy-unavailable')
policy(); brief('enforce-validator-missing'); call('enforce-validator-missing',ship('proj'),False,'not readable',LAB/'absent.py')
policy('observe'); brief('observe-missing'); call('observe-missing',ship('proj'),True,'missing-slice')
policy(); brief('unlisted-installed'); call('unlisted-installed',ship('other'),True)
policy(); brief('valid','SLICE: ops/demo | demo outcome | role=owner'); (HOME/'data/valid/prep.md').write_text('SLICE: ops/demo | demo outcome | role=owner\n'); call('valid',ship('proj'),True)
