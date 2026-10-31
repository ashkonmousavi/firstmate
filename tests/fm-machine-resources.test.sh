#!/usr/bin/env bash
# Common hard-floor readings and distinct reserve arithmetic, without agents.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
tmp=$(fm_test_tmproot fm-machine-resources)
python3 -B - "$ROOT" "$tmp" <<'PY'
import importlib.util,json,os,subprocess,sys
from pathlib import Path
from types import SimpleNamespace
r,t=map(Path,sys.argv[1:]);g=1024**3
spec=importlib.util.spec_from_file_location('resources',r/'bin/fm-machine-resources.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
home=t/'home'
for name in ('config','state','data'):(home/name).mkdir(parents=True,exist_ok=True)
policy=home/'config/machine-admission.json'
data={'schema':'fm-machine-admission.v1','memory_floor_gib':3,'memory_full_avg60_max':5,'disk_floor_gib':0,'disk_paths':[str(t)]}
policy.write_text(json.dumps(data))
(home/'config/lane-capacity').write_text('5 4\n')
mem=t/'meminfo';mem.write_text(f'MemAvailable: {64*g//1024} kB\n')
psi=t/'pressure';quiet='some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n';psi.write_text(quiet)
membership=t/'membership';membership.write_text('0::/crew/lane\n')
cg=t/'cgroup';(cg/'crew/lane').mkdir(parents=True)
for path,high,maximum,current,inactive in [(cg/'crew',16*g,17*g,20*g,8*g),(cg/'crew/lane','max','max',4*g,0)]:
    for field,value in [('memory.high',high),('memory.max',maximum),('memory.current',current)]: (path/field).write_text(str(value)+'\n')
    (path/'memory.stat').write_text(f'anon {8*g}\nshmem {g}\ninactive_file {inactive}\n')
    (path/'memory.pressure').write_text(quiet)
options={'meminfo':mem,'pressure_file':psi,'cgroup_file':membership,'cgroup_root':cg,'disk_usage':lambda p:SimpleNamespace(free=100*g)}
rules=m.policy(policy);facts=m.measure(rules,**options)
assert facts['effective_available_bytes']==4*g and facts['admitted'],facts
print('ok - cache-heavy headroom uses current minus inactive_file and finite parent limit (synthetic)')
env={**os.environ,'FM_HOME':str(home),'FM_TEST_SEAM':'1','FM_CAPACITY_MEMINFO':str(mem),'FM_CAPACITY_PRESSURE_FILE':str(psi),'FM_CAPACITY_CGROUP_FILE':str(membership),'FM_CAPACITY_CGROUP_ROOT':str(cg),'FM_RESOURCE_CGROUP_FILE':str(membership),'FM_RESOURCE_CGROUP_ROOT':str(cg)}
def capacity():
    p=subprocess.run(['bash',str(r/'bin/fm-capacity.sh'),'--json'],env=env,capture_output=True,text=True)
    assert p.returncode==0,(p.stdout,p.stderr)
    return json.loads(p.stdout)
reading=capacity()
assert reading['effective_available_kb']==4*g//1024 and reading['mem_available_kb']==7*g//1024,reading
assert reading['headroom_kb']==3*g//1024 and reading['resource_policy_sha256']==facts['resource_policy_sha256'],reading
data['memory_floor_gib']=5;policy.write_text(json.dumps(data));reading=capacity()
assert reading['reason']=='memory' and reading['free_lanes']==0 and reading['headroom_kb']==3*g//1024,reading
print('ok - public consumer keeps hard floor and reserve separate on the same snapshot (synthetic)')
data['memory_floor_gib']=3;policy.write_text(json.dumps(data))
(cg/'crew/memory.pressure').write_text(quiet.replace('avg60=0.00','avg60=5.00'))
assert capacity()['reason']=='pressure'
print('ok - enclosing cgroup pressure refuses despite quiet host and child (synthetic)')
(cg/'crew/memory.pressure').write_text(quiet)
(cg/'crew/memory.max').write_text(str(14*g))
assert m.measure(m.policy(policy),**options)['effective_available_bytes']==2*g
assert capacity()['reason']=='memory'
print('ok - hard maximum can constrain floor while high reserve remains satisfied (synthetic)')
(cg/'crew/memory.current').unlink()
try:m.measure(m.policy(policy),**options)
except ValueError:pass
else:raise AssertionError('missing controller current was admitted')
print('ok - incomplete cgroup evidence refuses (synthetic)')
for broken in ['{}','{"schema":"fm-machine-admission.v1","schema":"fm-machine-admission.v1"}',json.dumps({**data,'memory_floor_gib':True}),json.dumps({**data,'memory_full_avg60_max':float('nan')})]:
    policy.write_text(broken)
    try:m.policy(policy)
    except ValueError:pass
    else:raise AssertionError('malformed policy accepted')
print('ok - missing, duplicate, boolean and nonfinite numeric fields refuse (synthetic)')
def psi_text(a10,a60,a300):
    return f'some avg10={a10:.2f} avg60={a60:.2f} avg300={a300:.2f} total=0\nfull avg10={a10:.2f} avg60={a60:.2f} avg300={a300:.2f} total=0\n'
burst,sustained=psi_text(30,12,2),psi_text(9,9,6)
legacy={**data,'memory_floor_gib':3}
windowed={**legacy,'memory_full_avg60_max':25,'memory_full_avg300_max':5}
def verdict(policy_data,host,meminfo_gib=64,ancestor=None):
    policy.write_text(json.dumps(policy_data));psi.write_text(host)
    mem.write_text(f'MemAvailable: {meminfo_gib*g//1024} kB\n')
    (cg/'crew/memory.max').write_text(str(17*g));(cg/'crew/memory.current').write_text(str(20*g))
    (cg/'crew/memory.pressure').write_text(ancestor or quiet)
    return m.measure(m.policy(policy),**options)
for host,expected in [(quiet,[]),(burst,['memory PSI full avg60 refuses']),(sustained,['memory PSI full avg60 refuses'])]:
    facts=verdict(legacy,host)
    assert facts['refusal_reasons']==expected,(host,facts['refusal_reasons'])
print('ok - a policy without memory_full_avg300_max keeps the avg60-only verdicts (synthetic)')
facts=verdict(windowed,burst)
assert facts['admitted'] and (facts['memory_full_avg10'],facts['memory_full_avg60'],facts['memory_full_avg300'])==(30,12,2),facts
assert facts['mem_available_bytes']==64*g,facts
print('ok - a short burst with ample memory admits under the five-minute window (synthetic)')
facts=verdict(windowed,sustained)
assert facts['refusal_reasons']==['memory PSI full avg300 refuses'],facts
policy.write_text(json.dumps(windowed));psi.write_text(sustained)
reading=capacity()
assert reading['reason']=='pressure' and reading['free_lanes']==0,reading
print('ok - sustained pressure refuses through the public consumer (synthetic)')
assert verdict(windowed,psi_text(60,30,3))['refusal_reasons']==['memory PSI full avg60 refuses']
print('ok - a burst above the avg60 ceiling still refuses (synthetic)')
assert verdict(windowed,quiet,ancestor=sustained)['refusal_reasons']==['memory PSI full avg300 refuses']
print('ok - enclosing cgroup avg300 refuses despite a quiet host (synthetic)')
facts=verdict(windowed,burst,meminfo_gib=2)
assert facts['refusal_reasons']==['Required cache-aware effective memory floor not met'],facts
print('ok - low MemAvailable refuses during a tolerated burst (synthetic)')
for broken in ['full avg10=1.00 avg60=1.00 total=0\n','some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n','full avg10=1.00 avg60=1.00 avg300=x total=0\n']:
    for rules in (legacy,windowed):
        policy.write_text(json.dumps(rules));psi.write_text(broken)
        p=subprocess.run([sys.executable,str(r/'bin/fm-machine-resources.py'),'--policy',str(policy)],env=env,capture_output=True,text=True)
        out=json.loads(p.stdout)
        assert p.returncode==75 and out['readable'] is False and not out['admitted'],(broken,p.stdout)
print('ok - unreadable or partial PSI is reported unknown, not healthy (synthetic)')
for bad in [0,101,True,'5',float('inf')]:
    policy.write_text(json.dumps({**windowed,'memory_full_avg300_max':bad}))
    try:m.policy(policy)
    except ValueError:pass
    else:raise AssertionError('invalid memory_full_avg300_max accepted: '+repr(bad))
print('ok - invalid memory_full_avg300_max refuses (synthetic)')
log=home/'state/machine-admission.log'
for path in (log,Path(str(log)+'.1')):
    path.unlink(missing_ok=True)
policy.write_text(json.dumps(windowed));mem.write_text(f'MemAvailable: {64*g//1024} kB\n')
psi.write_text(burst);capacity()
psi.write_text(sustained);capacity()
psi.write_text('full avg10=1.00 total=0\n');subprocess.run(['bash',str(r/'bin/fm-capacity.sh'),'--json'],env=env,capture_output=True,text=True)
rows=[line.split('\t') for line in log.read_text().splitlines()]
assert [len(row) for row in rows]==[9,9,9],rows
assert [row[1] for row in rows]==['yes','no','unknown'],rows
assert [float(v) for v in rows[0][2:5]]==[30,12,2] and rows[0][5]==str(64*g//1024) and rows[1][8]=='memory PSI full avg300 refuses',rows
assert rows[2][2:8]==['']*6 and 'avg60' in rows[2][8],rows
print('ok - every verdict is logged with its PSI windows and MemAvailable (synthetic)')
psi.write_text(burst)
small={**env,'FM_ADMISSION_LOG_MAX_BYTES':'1'}
subprocess.run(['bash',str(r/'bin/fm-capacity.sh'),'--json'],env=small,capture_output=True,text=True,check=True)
assert not log.exists() and len(Path(str(log)+'.1').read_text().splitlines())==4
print('ok - the sample log rotates once it exceeds its byte cap (synthetic)')
log.mkdir()
assert capacity()['reason']=='ok'
log.rmdir()
print('ok - an unwritable sample log never changes the verdict (synthetic)')
failed_reader = '''
python3() { printf '%s' "$FM_FAILED_READER_OUTPUT"; return "$FM_FAILED_READER_STATUS"; }
export -f python3
exec bash "$@"
'''
for output,status in [('',137),('',0),(' \n\t',137),('{',1)]:
    failed_env={**env,'FM_FAILED_READER_OUTPUT':output,'FM_FAILED_READER_STATUS':str(status)}
    for mode,expected in [('--json',1),('--publish',1),('--admit',75),('',1)]:
        log.unlink(missing_ok=True)
        args=['bash','-c',failed_reader,'failed-reader',str(r/'bin/fm-capacity.sh')]
        if mode:args.append(mode)
        result=subprocess.run(args,env=failed_env,capture_output=True,text=True)
        assert result.returncode==expected,(output,status,mode,result.stdout,result.stderr)
        rows=log.read_text().splitlines()
        assert len(rows)==1,(output,status,mode,rows)
        row=rows[0].split('\t')
        assert len(row)==9 and row[0].isdigit() and row[1]=='unknown',row
        assert row[2:8]==['']*6 and row[8]=='resource reader output unreadable',row
        if mode in ('--json','--publish'):
            reading=json.loads(result.stdout)
            assert reading['reason']=='unreadable' and reading['free_lanes']==0,reading
print('ok - empty, whitespace and truncated reader output log one unknown TSV verdict across report modes (synthetic)')
PY
