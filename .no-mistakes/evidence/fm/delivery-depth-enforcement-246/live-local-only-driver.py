import os,pathlib,tempfile,subprocess,re,shutil,json
r=pathlib.Path.cwd(); e=pathlib.Path('/home/zcrew/.no-mistakes/evidence/01M45JNGXNRJ522PPBNYHJF1VA'); l=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=r/'.test-phase'))
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('TASKS_AXI') or k.startswith('TMUX'))};env.update(FM_HOME=str(l),FM_BACKEND='tmux',TMUX='.test-phase/absent-private-socket,0,0',TMPDIR=str(r/'.test-phase/tmp'))
log=(e/'live-local-only-transcript.log').open('w'); results=[]
def run(args):
 p=subprocess.run(args,cwd=r,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40);log.write('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+'\nraw exit: '+str(p.returncode)+'\n');log.flush();return p
try:
 assert run(['bash','bin/fm-lab-home.sh','create',str(l)]).returncode==0
 proj=l/'projects/proj';proj.mkdir();assert run(['git','-C',str(proj),'init','-q']).returncode==0
 for fmt in ['full','surgical']:
  for label,replacement in [('missing',''),('third-answer','- Delivery depth: local-only, isolated local branch.')]:
   id='local-'+fmt+'-'+label
   assert run(['bash','bin/fm-brief.sh',id,'proj','--mode','local-only']).returncode==0
   brief=l/'data'/id/'brief.md';brief.write_text(brief.read_text().replace('{TASK}','Verify isolated local-only admission.').replace('{FIRSTMATE_SPEC}','Do not write source or contact external services.'))
   data=(e/('filled-'+fmt+'-prep.md')).read_text();data=re.sub(r'^- Delivery depth:.*$',replacement,data,flags=re.M)
   prep=l/'data'/id/'prep.md';prep.write_text(data)
   p=run(['bash','bin/fm-spawn.sh',id,str(proj),'codex','--mode','local-only','--yolo','off'])
   assert p.returncode!=0 and 'Delivery depth' in p.stdout,p.stdout
   assert not (l/'data'/id/'launch-brief.md').exists() and not (l/'state'/(id+'.meta')).exists() and not list((l/'state').rglob('*lock*'))
   log.write('POSTCONDITION: local-only cannot bypass depth syntax or create a third choice; no launch brief, task metadata or task lock.\n')
   results.append(dict(name=id,result='pass',live=True))
 print('Local-only depth boundary passed in both formats.')
finally:
 shutil.rmtree(l);log.write('CLEANUP: disposable marked home removed.\n');log.close();(e/'live-local-only-results.json').write_text(json.dumps(results,indent=2)+'\n')
