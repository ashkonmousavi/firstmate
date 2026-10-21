import json, os, pathlib, subprocess, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M5FAS8QR5Y9J5SWZETGTK90B')
lab=root/'.capacity-validation/manual'
home=lab/'home'
for name in ('state','config','data'): (home/name).mkdir(parents=True, exist_ok=True)
cg=lab/'cgroup'; leaf=cg/'crew/lane'; leaf.mkdir(parents=True)
member=lab/'membership'; mem=lab/'meminfo'
(home/'config/lane-capacity').write_text('5 4\n')
member.write_text('0::/crew/lane\n'); mem.write_text('MemAvailable: 1 kB\n')
env=dict(os.environ)
for key in list(env):
    if key.startswith(('FM_', 'HERDR_')): env.pop(key)
env.update(FM_HOME=str(home), TMPDIR=str(lab), FM_TEST_SEAM='1', FM_CAPACITY_CGROUP_FILE=str(member), FM_CAPACITY_CGROUP_ROOT=str(cg), FM_CAPACITY_MEMINFO=str(mem))
log=open(evidence/'capacity-live-transcript.log','w',buffering=1)
def run(label, option='--json', expected=0, native=False):
    e=env.copy()
    if native: e.pop('FM_TEST_SEAM')
    p=subprocess.run(['bash',str(root/'bin/fm-capacity.sh'),option],env=e,text=True,capture_output=True,timeout=15)
    log.write(f'\n{label}\n$ bash bin/fm-capacity.sh {option}\nexit={p.returncode}\n{p.stdout}{p.stderr}')
    assert p.returncode==expected,(label,p.returncode,p.stderr)
    return json.loads(p.stdout) if option in ('--json','--publish') else p.stdout+p.stderr
# Native Linux readings: no fixture overrides are enabled. A generous reserve
# is deliberately absent here; this checks collection rather than scheduling.
(home/'config/lane-capacity').write_text('5 0\n')
f=run('Native host cgroup reporting', native=True)
assert f['readable'] and f['target']==5 and f['lanes']==0
run('Native host admission', '--admit', 0 if f['reason']=='ok' else 75, native=True)
(home/'config/lane-capacity').write_text('5 4\n')
(leaf/'memory.high').write_text('max\n')
(cg/'crew/memory.high').write_text('15000000000\n')
(cg/'crew/memory.stat').write_text('file 12000000000\nshmem 500000000\nanon 5000000000\n')
(cg/'crew/memory.current').write_text('17500000000\n')
f=run('Cache-heavy parent: 15 GB minus 5.5 GB working memory leaves 9.5 GB')
assert f['reason']=='ok' and f['mem_available_kb']==9277343 and f['headroom_kb']==5083039
run('Cache-heavy admission despite only 1 KiB host MemAvailable', '--admit')
# Changing only cache/current must not change the capacity contract.
(cg/'crew/memory.stat').write_text('anon 5000000000\nfile 1000000\nshmem 500000000\n')
(cg/'crew/memory.current').write_text('5501000000\n')
g=run('Reclaimed file cache leaves reported headroom unchanged')
assert g['headroom_kb']==f['headroom_kb']
(leaf/'memory.high').write_text('8589934592\n'); (leaf/'memory.stat').write_text('shmem 0\nanon 4294967296\n')
f=run('Closer 8 GiB limit: 4 GiB working set exactly meets 4 GiB reserve')
assert f['headroom_kb']==0 and f['reason']=='ok'
run('Exact reserve admission', '--admit')
(leaf/'memory.stat').write_text('anon 4294967297\nshmem 0\n')
f=run('One byte below reserve rounds down and refuses')
assert f['headroom_kb']==-1 and f['reason']=='memory' and f['free_lanes']==0
assert str(leaf) in run('One-byte shortfall admission', '--admit',75)
(home/'config/lane-capacity').write_text('5 0\n')
(leaf/'memory.high').write_text('0\n'); (leaf/'memory.stat').write_text('anon 1\nshmem 0\n')
f=run('Negative one-byte balance remains negative with zero reserve')
assert f['mem_available_kb']==-1 and f['reason']=='memory'
run('Negative balance admission', '--admit',75)
(home/'config/lane-capacity').write_text('5 4\n')
mem.write_text('MemAvailable: 8388608 kB\n')
for content in ('', 'anon nope\nshmem 0\n','anon 1\n','anon 1\nshmem -1\n','anon 1\nanon 2\nshmem 0\n'):
    (leaf/'memory.stat').write_text(content)
    f=run('Bad statistics refuse without host fallback: '+repr(content), expected=1)
    assert not f['readable'] and f['free_lanes']==0
    run('Bad statistics admission','--admit',75)
(leaf/'memory.stat').unlink()
run('Missing statistics admission','--admit',75)
(leaf/'memory.stat').write_text('anon 1\nshmem 0\n'); (leaf/'memory.stat').chmod(0)
try: run('Permission-denied statistics admission','--admit',75)
finally: (leaf/'memory.stat').chmod(0o600)
(leaf/'memory.high').write_text('broken\n'); run('Malformed limit admission','--admit',75)
for content in ('0::/crew/../lane\n','0::relative\n','0::/crew/lane\n0::/crew\n','0::/missing\n'):
    member.write_text(content); run('Invalid membership admission: '+repr(content),'--admit',75)
member.write_text('0::/crew/lane\n')
for path in (leaf/'memory.high',cg/'crew/memory.high'): path.write_text('max\n')
f=run('All ancestors unlimited uses 8 GiB host MemAvailable')
assert f['mem_available_kb']==8388608 and f['headroom_kb']==4194304
member.write_text('0::/\n'); f=run('Hierarchy root with no controller uses host memory')
assert f['mem_available_kb']==8388608
member.write_text('2:memory:/legacy\n'); f=run('No unified cgroup membership uses host memory')
assert f['mem_available_kb']==8388608
# Public persisted state is the contract consumed by placement.
member.write_text('0::/crew/lane\n'); (leaf/'memory.high').write_text('8589934592\n'); (leaf/'memory.stat').write_text('anon 4294967297\nshmem 0\n')
f=run('Publish memory refusal for downstream consumers','--publish')
assert json.loads((home/'state/lane-capacity.json').read_text())==f
assert f['reason']=='memory' and f['free_lanes']==0
(leaf/'memory.stat').unlink()
f=run('Publication replaces old facts when statistics become unreadable','--publish',1)
assert json.loads((home/'state/lane-capacity.json').read_text())==f and not f['readable']
log.write('\nAll observable assertions passed.\n')
log.close()
shutil.rmtree(lab)
