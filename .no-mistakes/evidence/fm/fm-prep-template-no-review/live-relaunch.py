import os,pathlib,subprocess,tempfile,shutil,json,re
ROOT=pathlib.Path.cwd(); E=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M42JD1EGCXV3KJW39JC23GXS')
LAB=pathlib.Path(tempfile.mkdtemp(prefix='.live-relaunch-',dir=ROOT));logs=[];results=[]
env=dict(os.environ)
for k in list(env):
 if k.startswith('FM_') and (k.endswith('_OVERRIDE') or k in ['FM_HOME','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TASK_ID','FM_BACKEND']):env.pop(k,None)
env.update(FM_HOME=str(LAB),FM_BACKEND='tmux',FM_SPAWN_NO_GUARD='1',TMUX='sock,0,0')
def run(args):
 p=subprocess.run(args,cwd=LAB,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
 logs.append('$ '+subprocess.list2cmdline(args)+'\n'+p.stdout+'[exit '+str(p.returncode)+']');return p
try:
 assert run(['bash',str(ROOT/'bin/fm-lab-home.sh'),'create',str(LAB)]).returncode==0
 assert run(['tmux','-S','sock','new-session','-d','-s','fm-lab-prep','-x','100','-y','30','bash --noprofile --norc']).returncode==0
 socket=run(['tmux','-S','sock','display-message','-p','#{socket_path}']).stdout.strip();assert socket=='sock'
 pid=run(['tmux','-S','sock','display-message','-p','#{pid}']).stdout.strip();env['TMUX']='sock,'+pid+',0'
 project=LAB/'projects'/'proj';project.mkdir();assert run(['git','-C',str(project),'init','-q']).returncode==0
 for mode in ['no-mistakes','direct-PR','local-only']:
  id='refresh-'+mode.lower();task=LAB/'data'/id;task.mkdir()
  assert run(['bash',str(ROOT/'bin/fm-brief.sh'),id,'--prep']).returncode==0
  prep=task/'prep.md';text=prep.read_text()
  replacements={'Q1':'no','Q2':'no','UI_WIRING':'no, isolated CLI only.','INTENT_AND_BOXES':'Exercise current acceptance refresh in an isolated home.', 'OUTCOME':'Count','OBSERVABLE_RESULT':'Exact count observed','WHERE_AND_HOW':'Public count fixture','EXPECTED_VALUE':'42'}
  text=re.sub(r'\{([A-Z0-9_]+)\}',lambda m:replacements.get(m[1], 'Concrete isolated evidence.' if m[1] in ['SCOPE_ONLY_AS_ASKED','AUTHOR_GATE_CHECK'] else 'n/a: not applicable to this disposable check.'),text)
  prep.write_text(text)
  assert run(['bash','-c','. "$1/bin/fm-dod-lib.sh"; fm_prep_unfilled_reason "$2"','_',str(ROOT),str(prep)]).returncode==1
  (task/'brief.md').write_text("# Task\n## Captain's intent\nPreserve the exact current count.\n\n## Firstmate spec\nInvestigate the current count.\n\nShip branch: fm/safety-stop\n")
  assert run(['tmux','-S','sock','new-window','-d','-t','fm-lab-prep:','-n','fm-'+id,'bash --noprofile --norc']).returncode==0
  meta=LAB/'state'/(id+'.meta');meta.write_text('window=fm-lab-prep:fm-'+id+'\nbackend=tmux\nkind=scout\nproject='+str(project)+'\nworktree='+str(project)+'\nharness=claude\n')
  p=run(['bash',str(ROOT/'bin/fm-promote.sh'),id,'--mode',mode,'--yolo','off']);assert p.returncode==0,p.stdout
  original=(task/'brief.md').read_bytes();meta_before=meta.read_bytes()
  for state in ['changed','incomplete','missing']:
   if state=='changed':prep.write_text(text.replace('| 42 |','| 43 |'))
   elif state=='incomplete':prep.write_text(re.sub(r'(?m)^- Scope only as asked:.*\n','',text))
   else:prep.unlink()
   launch=task/'launch-brief.md'
   if launch.exists():launch.unlink()
   p=run(['bash',str(ROOT/'bin/fm-spawn.sh'),id,'--relaunch'])
   assert p.returncode!=0 and 'branch mismatch' in p.stdout,p.stdout
   output=launch.read_text()
   assert output.count('# Task preparation record\n')==(0 if state=='missing' else 1)
   assert '# Current ship Firstmate spec\n' in output
   assert (task/'brief.md').read_bytes()==original and meta.read_bytes()==meta_before
   if mode=='no-mistakes':
    assert output.count('# Current no-mistakes intent contract\n')==1
    h="## Accepted specification for --intent (preparation record, not the captain's words)\n"
    assert output.count(h)==(1 if state=='changed' else 0)
    if state=='changed':assert '| 43 |' in output and '| 42 |' not in output
    assert output.split('## Captain intent authorized for --intent\n')[1].strip()=='Preserve the exact current count.'
   else:assert '# Current no-mistakes intent contract\n' not in output
   (E/(id+'-'+state+'-launch.md')).write_text(output)
   results.append(mode+'/'+state+': real relaunch rendered current contract; stale/incomplete specification excluded; source/meta unchanged; branch guard stopped before worker launch')
 print(json.dumps(results,indent=2))
finally:
 p=run(['tmux','-S','sock','kill-server'])
 logs.append('Private tmux server stopped; disposable home removed.')
 shutil.rmtree(LAB)
 (E/'live-relaunch-transcript.log').write_text('\n\n'.join(logs)+'\n')
 (E/'live-relaunch-results.json').write_text(json.dumps(results,indent=2)+'\n')
