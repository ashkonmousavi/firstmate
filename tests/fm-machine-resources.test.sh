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
print('ok - cache-heavy headroom uses current minus inactive_file and finite parent limit')
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
print('ok - public consumer keeps hard floor and reserve separate on the same snapshot')
data['memory_floor_gib']=3;policy.write_text(json.dumps(data))
(cg/'crew/memory.pressure').write_text(quiet.replace('avg60=0.00','avg60=5.00'))
assert capacity()['reason']=='pressure'
print('ok - enclosing cgroup pressure refuses despite quiet host and child')
(cg/'crew/memory.pressure').write_text(quiet)
(cg/'crew/memory.max').write_text(str(14*g))
assert m.measure(m.policy(policy),**options)['effective_available_bytes']==2*g
assert capacity()['reason']=='memory'
print('ok - hard maximum can constrain floor while high reserve remains satisfied')
(cg/'crew/memory.current').unlink()
try:m.measure(m.policy(policy),**options)
except ValueError:pass
else:raise AssertionError('missing controller current was admitted')
print('ok - incomplete cgroup evidence refuses')
for broken in ['{}','{"schema":"fm-machine-admission.v1","schema":"fm-machine-admission.v1"}',json.dumps({**data,'memory_floor_gib':True}),json.dumps({**data,'memory_full_avg60_max':float('nan')})]:
    policy.write_text(broken)
    try:m.policy(policy)
    except ValueError:pass
    else:raise AssertionError('malformed policy accepted')
print('ok - missing, duplicate, boolean and nonfinite numeric fields refuse')
PY
