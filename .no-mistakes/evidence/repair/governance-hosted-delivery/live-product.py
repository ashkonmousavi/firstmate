import os, pathlib, subprocess, tempfile, json, hashlib, shutil, time
root=pathlib.Path.cwd()
base=root/'.test-phase-tmp'
env={k:v for k,v in os.environ.items() if k not in {'FM_HOME','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_INHERITABLE_CONFIG'}}
env.update(TMPDIR=str(base),PYTHONDONTWRITEBYTECODE='1')

def run(args, home, expected=0, stdin=None, extra=None):
    e={**env,'FM_HOME':str(home),**(extra or {})}
    p=subprocess.run([str(a) for a in args], cwd=root, env=e, text=True,input=stdin,capture_output=True,timeout=60)
    print('$ '+' '.join(str(a).replace(str(root),'$WORKTREE') for a in args),flush=True)
    print(p.stdout+p.stderr,end='',flush=True)
    print(f'[exit {p.returncode}]',flush=True)
    assert p.returncode==expected,(args,p.returncode,expected)
    return p

with tempfile.TemporaryDirectory(prefix='live-',dir=base) as d:
    home=pathlib.Path(d)/'home'
    run([root/'bin/fm-lab-home.sh','create',home],home)
    (home/'.tasks.toml').write_text('backend = "markdown"\n')
    (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    wrapper=root/'bin/fm-tasks-axi.sh'
    # Owner request metadata is an intentional public packet and persisted body contract.
    text='Explain the verified outcome'
    packet={'version':1,'origin_home':str(home),'origin_task_id':'owner-1','expected_body_sha256':None,'interpretation_owner':'intake','interpretation_complete':True,'sources':[{'session_id':'live-session','message_uuid':'source-1','file_ref':'retired-transcript.json','source_custody':'complete','full_text':text,'full_text_sha256':hashlib.sha256(text.encode()).hexdigest()}],'requirements':[{'id':'r1','kind':'explanation','source_message_uuid':'source-1','text_ref':text,'safe_text':None,'source_binding':'verified_complete','disposition':'pending','proof_refs':[],'superseded_by':[],'proof_kind':'reply','acceptance_level':'source'}],'corrections':[]}
    path=home/'request.json';path.write_text(json.dumps(packet));path.chmod(0o600)
    run([wrapper,'add','owner-1','Owner explanation','--owner-request-file',path],home)
    before=(home/'data/backlog.md').read_bytes()
    run([wrapper,'update','owner-1','--body','erase custody'],home,2)
    assert (home/'data/backlog.md').read_bytes()==before
    run([wrapper,'show','owner-1','--full'],home)
    for command,title in [('add','Summary'),('create','A summary')]:
        run([wrapper,command,title,'--mint','--body','context'],home)
    run([wrapper,'list'],home)
    print('SCENARIO native custody: ordinary edits cannot erase request custody; native mint creates unique tasks successfully',flush=True)

    # Already released, stopped worker is a supported lifecycle state; no worker CLI or fake backend is needed.
    run([wrapper,'add','cleanup-1','Pending delivery'],home)
    run([wrapper,'start','cleanup-1'],home)
    meta=home/'state/cleanup-1.meta'
    meta.write_text(f'window=\nbackend=tmux\nkind=ship\nmode=local-only\nworktree={home}/state/cleanup-1.released-copy\nproject={home}/projects/unused\n')
    e={'TMUX':str(home/'private-missing-socket')+',0,0'}
    run([root/'bin/fm-teardown.sh','cleanup-1'],home,1,extra=e)
    assert meta.exists()
    run([wrapper,'hold','cleanup-1','--kind','external','--reason','awaiting journey proof','--until','2000-01-01'],home)
    run([root/'bin/fm-teardown.sh','cleanup-1'],home,1,extra=e)
    assert meta.exists()
    run([wrapper,'unhold','cleanup-1'],home)
    run([wrapper,'done','cleanup-1','--note','accepted: journey evidence recorded'],home)
    run([root/'bin/fm-teardown.sh','cleanup-1'],home,extra=e)
    assert not meta.exists()
    run([wrapper,'show','cleanup-1'],home)
    print('SCENARIO native cleanup: pending and expired proof waits refuse cleanup; explicit native acceptance permits cleanup',flush=True)

    # Real /proc, cgroup and disk readings, with a local numeric policy only.
    policy=home/'config/machine-admission.json'
    rules={'schema':'fm-machine-admission.v1','memory_floor_gib':0,'memory_full_avg60_max':100,'disk_floor_gib':0,'disk_paths':[str(home)]}
    policy.write_text(json.dumps(rules))
    (home/'config/lane-capacity').write_text('4 0\n')
    facts=run(['python3',root/'bin/fm-machine-resources.py','--policy',policy],home)
    assert json.loads(facts.stdout)['admitted']
    rules['memory_floor_gib']=999999;policy.write_text(json.dumps(rules))
    facts=run(['python3',root/'bin/fm-machine-resources.py','--policy',policy],home,75)
    assert 'memory floor' in json.loads(facts.stdout)['refusal_reasons'][0]
    policy.write_text('{}')
    run(['python3',root/'bin/fm-machine-resources.py','--policy',policy],home,75)
    print('SCENARIO real host admission: readable low-floor policy admits; impossible floor and malformed policy refuse',flush=True)

    # Real watcher quiet path; stdout itself is the user-facing evidence.
    t=time.monotonic()
    run([root/'bin/fm-watch-checkpoint.sh','--seconds','1'],home,124,extra={'FM_POLL':'1','FM_SIGNAL_GRACE':'1','FM_CHECK_INTERVAL':'999999'})
    assert not (home/'state/.watch.lock/pid').exists()
    print(f'SCENARIO quiet checkpoint: bounded return after {time.monotonic()-t:.2f}s, exit 124, no live lock',flush=True)
print('Disposable home removed',flush=True)
