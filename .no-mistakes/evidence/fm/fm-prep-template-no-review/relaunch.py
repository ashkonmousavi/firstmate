import os,subprocess,shutil,re,json
from pathlib import Path
root=Path.cwd();base=root/'.test-phase/relaunch-live';home=base/'home'
evidence=Path('/home/tegris/.no-mistakes/evidence/01M43C5X37ANEHYTB6YAW1JDX1')
base.mkdir();env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('NO_MISTAKES_GATE','TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):env.pop(k)
env.update(FM_HOME=str(home),FM_BACKEND='tmux',FM_SPAWN_NO_GUARD='1',TMPDIR=str(root/'.test-phase/tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
log=(evidence/'live-relaunch-transcript.txt').open('w');sock=None

def run(args,expected=None):
 p=subprocess.run(args,cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
 log.write('$ '+__import__('shlex').join(map(str,args))+'\n'+p.stdout+'\nraw exit: '+str(p.returncode)+'\n');log.flush()
 if expected is not None:assert p.returncode==expected,p.stdout
 return p

def tmux(*args,expected=0):return run(['tmux','-L','fm-lab',*args],expected)
try:
 run(['bash','bin/fm-lab-home.sh','create',str(home)],0)
 sock=run(['bash','bin/fm-lab-home.sh','tmux-dir',str(home)],0).stdout.strip();env['TMUX_TMPDIR']=sock
 project=home/'projects/proj';project.mkdir();run(['git','-C',str(project),'init','-q'],0)
 tmux('new-session','-d','-s','fixture','-n','fm-relaunch','-x','120','-y','40','-c',str(project),'-e','FM_HOME='+str(home),'bash')
 env['TMUX']=tmux('display-message','-p','-t','fixture:fm-relaunch','#{socket_path},#{pid},0').stdout.strip()
 # The real shell is an agent-free historical endpoint; no harness is impersonated.
 rows=[]
 for mode in ('no-mistakes','direct-PR','local-only'):
  id='relaunch-'+mode.lower();d=home/'data'/id;d.mkdir()
  tmux('new-window','-d','-t','fixture:','-n','fm-'+id,'-c',str(project),'bash')
  run(['bash','-c','. tests/prep-record-helper.sh; fm_test_prep_record "$1" "$2"','_',str(home/'data'),id],0)
  prep=d/'prep.md';prep.write_text(prep.read_text().replace('| Brief present; no real endpoint created |','| 42 |'))
  brief=d/'brief.md';brief.write_text("# Task\n## Captain's intent\nPreserve the current specification.\n\n## Firstmate spec\nCheck regenerated handoff.\n")
  meta=home/'state'/(id+'.meta');meta.write_text('window=fixture:fm-'+id+'\nkind=scout\nproject='+str(project)+'\nworktree='+str(project)+'\nharness=claude\n')
  run(['bash','bin/fm-promote.sh',id,'--mode',mode,'--yolo','off'],0)
  # Stop at the existing mode guard AFTER rendering; never launch a new worker.
  other='direct-PR' if mode!='direct-PR' else 'no-mistakes'
  brief.write_text(brief.read_text().replace('Delivery contract: mode='+mode,'Delivery contract: mode='+other))
  durable=brief.read_bytes();original=prep.read_text()
  for state in ('changed','incomplete','missing'):
   if state=='changed':prep.write_text(original.replace('| 42 |','| 43 |'))
   elif state=='incomplete':prep.write_text(re.sub(r'^- Scope only as asked:.*\n','',original,flags=re.M))
   elif prep.exists():prep.unlink()
   launch=d/'launch-brief.md'
   if launch.exists():launch.unlink()
   p=run(['bash','bin/fm-spawn.sh',id,'--relaunch'])
   assert p.returncode!=0 and 'delivery mismatch' in p.stdout,p.stdout
   assert launch.exists(),p.stdout
   output=launch.read_text()
   assert output.count('# Current no-mistakes intent contract\n')==(1 if mode=='no-mistakes' else 0)
   count=output.count('## Accepted specification for --intent (preparation record, not the captain\'s words)\n')
   assert count==(1 if mode=='no-mistakes' and state=='changed' else 0),(mode,state,count)
   if count:assert '| 43 |' in output and '| 42 |' not in output
   assert output.count('# Task preparation record\n')==(0 if state=='missing' else 1)
   assert brief.read_bytes()==durable
   shutil.copyfile(launch,evidence/(id+'-'+state+'-launch.md'))
   rows.append({'mode':mode,'prep':state,'result':'current contract rendered then controlled delivery mismatch refused'})
 (evidence/'live-relaunch-results.json').write_text(json.dumps(rows,indent=2)+'\n')
 print(json.dumps(rows,indent=2))
finally:
 if sock:
  tmux('kill-server',expected=None)
  run(['bash','bin/fm-lab-home.sh','teardown',str(home)])
 for p in base.rglob('*'):
  if p.is_dir() and not p.is_symlink():p.chmod(p.stat().st_mode|0o700)
 shutil.rmtree(base);log.write('Private fm-lab server and disposable lab removed.\n');log.close()
