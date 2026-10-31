#!/usr/bin/env python3
"""Drive the production admission CLIs using real kernel facts and a disposable home.
Oracle: documented policy limits, CLI exit statuses, and nine-column TSV contract.
Only policy limits change; no resource readings, readers, or backend commands are faked.
"""
import hashlib,json,os,subprocess,tempfile,time
from pathlib import Path

r=Path.cwd()
e=Path('~/.no-mistakes/evidence/01M6A2KGQ90D23E4727C31QS5S')
transcript=[]
results=[]
def log(s):
    print(s,flush=True);transcript.append(s)
def invoke(args,env,expected=None):
    p=subprocess.run(args,cwd=r,env=env,capture_output=True,text=True,timeout=30)
    log('$ '+' '.join(args));log(p.stdout.rstrip());
    if p.stderr:log('stderr: '+p.stderr.rstrip())
    log('exit_status='+str(p.returncode))
    if expected is not None:assert p.returncode==expected,(args,p.returncode,expected)
    return p

def passed(name):
    results.append({'name':name,'result':'pass','live':True})
    log('OBSERVED: '+name)

try:
 with tempfile.TemporaryDirectory(prefix='.live-admission-',dir=r) as t:
    home=Path(t)/'home'
    env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
    env['FM_HOME']=str(home)
    env['PYTHONDONTWRITEBYTECODE']='1'
    invoke(['bash','bin/fm-lab-home.sh','create',str(home)],env,0)
    policy=home/'config/machine-admission.json'
    lane=home/'config/lane-capacity';lane.write_text('5 0\n')
    base={'schema':'fm-machine-admission.v1','memory_floor_gib':3,'memory_full_avg60_max':25,'memory_full_avg300_max':5,'disk_floor_gib':0,'disk_paths':[str(home)]}
    def setpolicy(p):
        policy.write_text(json.dumps(p,sort_keys=True)+'\n')
        log('POLICY: '+json.dumps(p,sort_keys=True))
    def read(expected=0):
        return json.loads(invoke(['python3','-B','bin/fm-machine-resources.py','--policy',str(policy)],env,expected).stdout)
    def cap(mode,expected=0):
        return invoke(['bash','bin/fm-capacity.sh',mode],env,expected)
    def record():
        line=(home/'state/machine-admission.log').read_text().splitlines()[-1]
        log('ACTUAL machine-admission.log: '+line)
        fields=line.split('\t');assert len(fields)==9
        return fields
    setpolicy(base)
    facts=read()
    assert facts['admitted'] and facts['effective_available_bytes']>3*1024**3
    j=json.loads(cap('--json').stdout);assert j['reason']=='ok' and j['free_lanes']==5
    cap('--admit')
    published=json.loads(cap('--publish').stdout)
    assert published==json.loads((home/'state/lane-capacity.json').read_text())
    row=record();assert row[1]=='yes' and row[7]==hashlib.sha256(policy.read_text().rstrip('\n').encode()).hexdigest()
    passed('Configured 5/25 policy admits real available capacity, reports five open lanes, publishes identical JSON, and records the policy hash')

    # A policy can scale its thresholds to current load without replacing kernel inputs.
    # The independent oracle is a gap in measured avg60 and avg300, not a copied implementation rule.
    facts=read()
    a60,a300=facts['memory_full_avg60'],facts['memory_full_avg300']
    if a60>a300 and a60>0:
        limit=round((a60+a300)/2,6)
        log(f'LIVE WINDOW PROOF: avg60={a60}, avg300={a300}, chosen midpoint={limit}; thresholds scaled to current pressure, not deployment 5/25')
        legacy={k:v for k,v in base.items() if k!='memory_full_avg300_max'}
        legacy['memory_full_avg60_max']=limit
        setpolicy(legacy);old=read(75);assert old['refusal_reasons']==['memory PSI full avg60 refuses']
        cap('--admit',75);assert record()[1]=='no'
        windowed={**base,'memory_full_avg300_max':limit}
        setpolicy(windowed);new=read(0);assert new['admitted']
        cap('--admit',0);assert record()[1]=='yes'
        passed('Opting into avg300 accepts an actual short-window pressure burst that legacy avg60 refuses (thresholds scaled to live load)')
    else:
        results.append({'name':'Opting into avg300 accepts an actual short-window pressure burst that legacy avg60 refuses (thresholds scaled to live load)','result':'untested','live':False,'reason':f'Current real readings have avg60={a60} and avg300={a300}; no burst gap exists. Synthetic regression covers the transition, but inducing host pressure would modify shared host state.'})

    # Tighten one policy axis at a time while reading the actual host.
    setpolicy({**base,'memory_full_avg300_max':0.000001})
    pressured=read(75);assert pressured['refusal_reasons']==['memory PSI full avg300 refuses']
    cap('--admit',75);assert record()[1]=='no'
    passed('A five-minute PSI ceiling below actual measured pressure still refuses admission and records the refusal')

    setpolicy({**base,'memory_full_avg60_max':0.000001})
    pressured=read(75);assert pressured['refusal_reasons']==['memory PSI full avg60 refuses']
    cap('--admit',75);assert record()[1]=='no'
    passed('The one-minute emergency ceiling still refuses actual pressure even with the new window enabled')

    setpolicy({**base,'memory_floor_gib':999999})
    low=read(75);assert low['refusal_reasons']==['Required cache-aware effective memory floor not met']
    cap('--admit',75);assert record()[1]=='no'
    passed('The independent memory floor still refuses when real available memory is below the configured floor')

    setpolicy({**base,'memory_full_avg300_max':True})
    bad=read(75);assert bad['readable'] is False and bad['admitted'] is False
    j=json.loads(cap('--json',1).stdout);assert j['reason']=='unreadable' and j['free_lanes']==0
    row=record();assert row[1]=='unknown' and row[2:8]==['']*6
    passed('An invalid opt-in policy fails closed and records one unknown verdict without fabricated measurements')

    setpolicy(base)
    logfile=home/'state/machine-admission.log'
    logfile.unlink()
    rot={**env,'FM_ADMISSION_LOG_MAX_BYTES':'1'}
    invoke(['bash','bin/fm-capacity.sh','--admit'],rot,0)
    assert not logfile.exists() and logfile.with_name(logfile.name+'.1').is_file()
    log('ROTATED LOG: '+logfile.with_name(logfile.name+'.1').read_text().rstrip())
    logfile.mkdir()
    cap('--admit',0)
    logfile.rmdir()
    passed('Admission logging rotates at its configured cap and a failed log write leaves real admission successful')

    lane.write_text('0 0\n')
    cap('--admit',75)
    passed('Tolerating PSI bursts does not bypass the machine lane ceiling')
 log('CLEANUP: disposable home removed; no runtime backend or worker was launched')
except Exception as exc:
 log('FAILED: '+repr(exc))
 results.append({'name':'Live admission driver completed','result':'fail','live':True,'reason':repr(exc)})
 raise
finally:
 (e/'live-admission.log').write_text('\n'.join(transcript)+'\n')
 (e/'live-admission-results.json').write_text(json.dumps(results,indent=2)+'\n')
