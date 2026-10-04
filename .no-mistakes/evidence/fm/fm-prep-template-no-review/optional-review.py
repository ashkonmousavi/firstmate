import os,subprocess,shutil,json
from pathlib import Path
root=Path.cwd();home=root/'.test-phase/optional-review-home';home.mkdir()
evidence=Path('/home/tegris/.no-mistakes/evidence/01M43C5X37ANEHYTB6YAW1JDX1')
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND'):env.pop(k)
env.update(FM_HOME=str(home),TMPDIR=str(root/'.test-phase/tmp'))
log=[]
try:
 for args,want in [(['reviewer','repo','--scout','--prep-review','task-a','--prep-review','task-b'],0),(['bad-reviewer','repo','--mode','direct-PR','--prep-review','task-a'],1),(['reviewer','repo','--scout','--prep-review','../bad'],1)]:
  p=subprocess.run(['bash','bin/fm-brief.sh',*args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
  log.extend(['$ bash bin/fm-brief.sh '+' '.join(args),p.stdout,'raw exit: '+str(p.returncode)])
  assert p.returncode==want,p.stdout
  if want==0:
   s=(home/'data/reviewer/brief.md').read_text()
   for id in ('task-a','task-b'):
    assert str(home/'data'/id/'prep.md') in s
    assert str(home/'data/reviewer/reviewed-prep'/(id+'.md')) in s
   shutil.copyfile(home/'data/reviewer/brief.md',evidence/'optional-review-brief.md')
 (evidence/'optional-review-transcript.txt').write_text('\n'.join(log)+'\n')
finally:shutil.rmtree(home)
