import json, os, pathlib, subprocess, sys, time, shutil
root=pathlib.Path.cwd(); evidence=pathlib.Path('~/.no-mistakes/evidence/01M6HVSX6XW3XZP10BEN54C09Z')
lab=root/'l'
subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
log=[]; children=[]
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE'))}
env.update(FM_HOME=str(lab),FM_ROOT_OVERRIDE=str(root),PYTHONDONTWRITEBYTECODE='1')
env.pop('FM_TEST_SEAM',None); env.pop('CLAUDECODE',None)
activity=pathlib.Path.home()/'.config/skills-master/.agents/skills/activity/activity.sh'
def call(args, expected=0, extra=None):
    p=subprocess.run(args,env={**env,**(extra or {})},text=True,capture_output=True,timeout=60)
    log.append({'command':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    assert p.returncode==expected,(args,p.returncode,p.stdout,p.stderr)
    return p
try:
    (lab/'config/lane-capacity').write_text('10 0\n')
    policy={'schema':'fm-machine-admission.v1','memory_floor_gib':0,'memory_full_avg60_max':100,'disk_floor_gib':0,'disk_paths':[str(lab)]}
    (lab/'config/machine-admission.json').write_text(json.dumps(policy))
    for i in range(8):
        wt=lab/f'worker-{i}';wt.mkdir()
        (lab/f'state/worker-{i}.meta').write_text(f'kind=ship\nworktree={wt}\nharness=claude\n')
        if i<3:
            # Genuine noninteractive Claude runtimes waiting for stream input;
            # no substituted process names, process inventory or activity JSON.
            output=(lab/f'worker-{i}.log').open('w')
            child=subprocess.Popen(['claude','-p','--input-format','stream-json','--output-format','stream-json','--verbose','--setting-sources','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}'],cwd=wt,env=env,stdin=subprocess.PIPE,stdout=output,stderr=output,text=True)
            children.append((child,output))
    for i in range(30):
        time.sleep(.5)
        facts=json.loads(call(['bash',str(activity),'--machine-json',str(lab)]).stdout)
        if facts['lanes']==3:break
    assert facts['lanes']==3,facts
    for child,_ in children:
        assert child.poll() is None
        log.append({'live_pid':child.pid,'comm':pathlib.Path(f'/proc/{child.pid}/comm').read_text(),'cwd':os.readlink(f'/proc/{child.pid}/cwd')})
    for script,args in [('fm-capacity.sh',['--json']),('fm-fleet-ledger.sh',['capacity','--json'])]:
        facts=json.loads(call(['bash',str(root/'bin'/script),*args]).stdout)
        assert (facts['lanes'],facts['target'],facts['free_lanes'])==(3,10,7),facts
    call(['bash',str(root/'bin/fm-capacity.sh'),'--admit'])
    call(['bash',str(root/'bin/fm-fleet-view.sh'),'--capacity'])
    call(['bash',str(root/'bin/fm-capacity.sh'),'--publish'])
    published=json.loads((lab/'state/lane-capacity.json').read_text())
    assert (published['lanes'],published['free_lanes'])==(3,7)
    log.append({'published_capacity':published})
    # Replacement API: only worker-0 is exempted from the actual activity reader.
    command='for f in fm-wake-lib.sh fm-backend.sh fm-secondmate-registry-lib.sh fm-project-capacity-lib.sh fm-capacity-lib.sh; do source "$1/bin/$f"; done; fm_capacity_read "$FM_HOME" "$FM_HOME/config" "$FM_HOME/state" worker-0; fm_capacity_json'
    result=json.loads(call(['bash','-c',command,'replace',str(root)]).stdout)
    assert (result['lanes'],result['free_lanes'])==(2,8),result
    policy['memory_floor_gib']=999999
    (lab/'config/machine-admission.json').write_text(json.dumps(policy))
    refusal=call(['bash',str(root/'bin/fm-capacity.sh'),'--admit'],75)
    assert all(s in refusal.stderr for s in ['available_kb=','pressure_full_avg60=','floor_kb=1048574951424','reserve_kb=0','pressure_limit=100']),refusal.stderr
    denied=json.loads(call(['bash',str(root/'bin/fm-capacity.sh'),'--json']).stdout)
    assert denied['admitted'] is False and denied['free_lanes']==7 and denied['reason']=='memory',denied
    policy['memory_floor_gib']=0
    (lab/'config/machine-admission.json').write_text(json.dumps(policy))
    (lab/'config/lane-capacity').write_text('bad\n')
    refusal=call(['bash',str(root/'bin/fm-capacity.sh'),'--admit'],75)
    assert 'available_kb=unknown' in refusal.stderr
    (lab/'config/lane-capacity').write_text('10 0\n')
    # Opaque/unavailable activity source must never turn into healthy zero.
    (lab/'empty-user').mkdir()
    unavailable=call(['bash',str(root/'bin/fm-capacity.sh'),'--admit'],75,{'HOME':str(lab/'empty-user')})
    assert 'activity live-process lane reader unavailable' in unavailable.stderr
    log.append({'result':'PASS: eight records, three genuine Claude processes, 3/10 occupied and 7 free across public consumers; replacement=2/10; measured memory refusal preserves seven physical seats; broken config and unavailable reader fail closed'})
finally:
    for child,output in children:
        if child.poll() is None:child.terminate()
        try:child.wait(timeout=10)
        except subprocess.TimeoutExpired:child.kill();child.wait()
        child.stdin.close();output.close()
    (evidence/'live-capacity.json').write_text(json.dumps(log,indent=2))
    shutil.rmtree(lab)
print(log[-1])
