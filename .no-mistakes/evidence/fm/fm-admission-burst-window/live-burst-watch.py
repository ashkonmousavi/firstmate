#!/usr/bin/env python3
"""Wait only for naturally occurring pressure; never create shared-host load."""
import json,os,subprocess,tempfile,time
from pathlib import Path
r=Path.cwd();e=Path('~/.no-mistakes/evidence/01M6A2KGQ90D23E4727C31QS5S')
lines=[]
def log(s):print(s,flush=True);lines.append(s)
result={'name':'Opting into avg300 accepts an actual short-window pressure burst that legacy avg60 refuses (thresholds scaled to live load)','result':'untested','live':False}
try:
 with tempfile.TemporaryDirectory(prefix='.live-burst-',dir=r) as t:
  home=Path(t)/'home';env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND')};env['FM_HOME']=str(home);env['PYTHONDONTWRITEBYTECODE']='1'
  subprocess.run(['bash','bin/fm-lab-home.sh','create',str(home)],env=env,check=True,capture_output=True)
  (home/'config/lane-capacity').write_text('5 0\n')
  p=home/'config/machine-admission.json'
  policy={'schema':'fm-machine-admission.v1','memory_floor_gib':3,'memory_full_avg60_max':25,'memory_full_avg300_max':5,'disk_floor_gib':0,'disk_paths':[str(home)]}
  p.write_text(json.dumps(policy))
  def cli(args):
   proc=subprocess.run(args,env=env,capture_output=True,text=True,timeout=15)
   return proc
  for n in range(37):
   x=cli(['python3','-B','bin/fm-machine-resources.py','--policy',str(p)])
   facts=json.loads(x.stdout)
   a60,a300=facts['memory_full_avg60'],facts['memory_full_avg300']
   log(f"{time.time():.3f} sample={n} full60={a60} full300={a300} MemAvailable_GiB={facts['mem_available_bytes']/1024**3:.3f}")
   if a60>a300 and facts['admitted']:
    threshold=round((a60+a300)/2,6)
    old={k:v for k,v in policy.items() if k!='memory_full_avg300_max'};old['memory_full_avg60_max']=threshold
    new={**policy,'memory_full_avg300_max':threshold}
    for label,rules,status in [('legacy',old,75),('windowed',new,0)]:
     p.write_text(json.dumps(rules));log(label+' policy='+json.dumps(rules))
     reading=cli(['python3','-B','bin/fm-machine-resources.py','--policy',str(p)]);log(reading.stdout.rstrip());log('reader_exit='+str(reading.returncode));assert reading.returncode==status
     actual=cli(['bash','bin/fm-capacity.sh','--admit']);log(actual.stdout.rstrip());log(actual.stderr.rstrip());log('capacity_exit='+str(actual.returncode));assert actual.returncode==status
    log('ACTUAL machine-admission.log:\n'+(home/'state/machine-admission.log').read_text().rstrip())
    result.update(result='pass',live=True,reason='');break
   if n<36:time.sleep(5)
  else:
   result['reason']='The live resource CLI was polled every five seconds for three minutes after an initial probe; no naturally occurring avg60 > avg300 burst remained during the executable comparison. The configured 5/25 healthy path and both independent PSI refusals were driven live; synthetic regressions cover burst acceptance. Historical three-host raw readings are not supplied. Manufacturing host pressure or changing cgroup controls would affect the shared machine outside the workspace boundary. A disposable Linux VM/host with controlled workload, or permission to create a delegated test cgroup, would allow the missing live burst proof.'
 log('CLEANUP: disposable lab home removed')
finally:
 (e/'live-burst-watch.log').write_text('\n'.join(lines)+'\n')
 (e/'live-burst-watch-results.json').write_text(json.dumps(result,indent=2)+'\n')
