import os,pathlib,tempfile,subprocess,re,shutil,json,hashlib
r=pathlib.Path.cwd(); e=pathlib.Path('/home/zcrew/.no-mistakes/evidence/01M45JNGXNRJ522PPBNYHJF1VA'); l=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=r/'.test-phase'))
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('TASKS_AXI') or k.startswith('TMUX'))};env.update(FM_HOME=str(l),FM_BACKEND='tmux',TMUX='.test-phase/absent-private-socket,0,0',TMPDIR=str(r/'.test-phase/tmp'))
log=(e/'live-immutability-transcript.log').open('w'); results=[]
def run(args):
 p=subprocess.run(args,cwd=r,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40);log.write('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+'\nraw exit: '+str(p.returncode)+'\n');log.flush();return p
try:
 assert run(['bash','bin/fm-lab-home.sh','create',str(l)]).returncode==0
 for fmt in ['full','surgical']:
  for declared,selected in [('direct-PR','no-mistakes'),('no-mistakes','direct-PR')]:
   id='immutable-'+fmt+'-'+declared
   assert run(['bash','bin/fm-brief.sh',id,'proj','--mode',selected]).returncode==0
   brief=l/'data'/id/'brief.md';brief.write_text(brief.read_text().replace('{TASK}','Verify the explicit isolated delivery decision.').replace('{FIRSTMATE_SPEC}','Do not write source or contact external services.'))
   data=(e/('filled-'+fmt+'-prep.md')).read_text(); choice='checks-only (direct-PR)' if declared=='direct-PR' else 'checks + AI review (no-mistakes)'
   data=re.sub(r'^- Delivery depth:.*$','- Delivery depth: '+choice+', verify immutability of the authored decision.',data,flags=re.M)
   prep=l/'data'/id/'prep.md';prep.write_text(data)
   before={str(f):f.read_bytes() for f in [prep,brief]}
   p=run(['bash','bin/fm-spawn.sh',id,'proj','codex','--mode',selected,'--yolo','off'])
   assert p.returncode!=0 and '--mode '+selected in p.stdout and choice in p.stdout,p.stdout
   assert all(f.read_bytes()==before[str(f)] for f in [prep,brief])
   log.write('POSTCONDITION: prep and source brief retain identical SHA-256: '+', '.join(hashlib.sha256(before[str(f)]).hexdigest() for f in [prep,brief])+'\n')
   results.append(dict(name=id,result='pass',live=True))
   prep.write_text(re.sub(r'^- Delivery depth:.*$','',data,flags=re.M))
   p=run(['bash','-c','. bin/fm-dod-lib.sh; fm_prep_accepted_spec "$1"','_',str(prep)])
   assert p.returncode==0 and not p.stdout,p.stdout
   log.write('POSTCONDITION: historical prep lacking depth contributes no accepted specification.\n')
 print('Live immutability and historical-spec checks passed.')
finally:
 shutil.rmtree(l);log.write('CLEANUP: disposable marked home removed.\n');log.close();(e/'live-immutability-results.json').write_text(json.dumps(results,indent=2)+'\n')
