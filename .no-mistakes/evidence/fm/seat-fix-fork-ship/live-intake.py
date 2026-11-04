import copy, importlib.util, json, os, pathlib, shutil, subprocess, tempfile
root=pathlib.Path.cwd(); ev=pathlib.Path('~/.no-mistakes/evidence/01M6HVSX6XW3XZP10BEN54C09Z'); home=root/'.test-phase-tmp/intake'
home.mkdir();(home/'data').mkdir();(home/'state').mkdir();(home/'bin').symlink_to(root/'bin',target_is_directory=True)
(home/'.tasks.toml').write_text('backend = "markdown"\n');(home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE'))};env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(root),TASKS_AXI_BACKEND='markdown',PYTHONDONTWRITEBYTECODE='1')
log=[]
def call(args,expected=0):
    p=subprocess.run(args,cwd=home,env=env,text=True,capture_output=True,timeout=30)
    log.append({'command':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    assert p.returncode==expected,(args,p.returncode,p.stderr)
    return p
wrapper=['bash',str(root/'bin/fm-tasks-axi.sh')]
try:
    before=(home/'data/backlog.md').read_bytes()
    for args in [('add','explicit','Owner asked for the counter'),('create','alias','Captain requested this'),('add','body','Ordinary title','--body','The owner said fix the counter.'),('add','Owner request','--mint')]:
        call(wrapper+list(args),2)
        assert (home/'data/backlog.md').read_bytes()==before
    body=home/'body.md';body.write_text('As requested by the owner, fix the reader.')
    call(wrapper+['add','bodyfile','Normal title','--body-file',str(body)],2)
    assert (home/'data/backlog.md').read_bytes()==before
    call(wrapper+['add','ordinary','Fix queue rendering'])
    spec=importlib.util.spec_from_file_location('requests',root/'tests/test_request_acceptance.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    model=module.RequestTests() if hasattr(module,'RequestTests') else None
    if model is None:
        import unittest
        cls=next(v for v in vars(module).values() if isinstance(v,type) and issubclass(v,unittest.TestCase) and hasattr(v,'packet'))
        model=cls()
    model.home=home
    packet=model.packet(task='owner-asks')
    source=copy.deepcopy(packet['sources'][0]);requirement=copy.deepcopy(packet['requirements'][0])
    packet['sources']=[];packet['requirements']=[]
    for i in range(17):
        row=copy.deepcopy(source);row['message_uuid']='source-'+str(i);packet['sources'].append(row)
    for i in range(35):
        row=copy.deepcopy(requirement);row.update(id='requirement-'+str(i),source_message_uuid='source-'+str(i%17));packet['requirements'].append(row)
    packet_file=home/'request.json';packet_file.write_text(json.dumps(packet));packet_file.chmod(0o600)
    call(wrapper+['add','owner-asks','Owner asks for the explanation','--owner-request-file',str(packet_file)])
    call(wrapper+['show','owner-asks','--full'])
    summary=call(['python3','-B',str(root/'bin/fm-request-acceptance.py'),'open-summary','--home',str(home)])
    facts=json.loads(summary.stdout)
    assert (facts['open_requirements'],facts['sources'],facts['tasks'])==(35,17,1),facts
    # A home without its native task reader must fail, never return healthy zero.
    missing=home/'unknown';missing.mkdir()
    failure=call(['python3','-B',str(root/'bin/fm-request-acceptance.py'),'open-summary','--home',str(missing)],2)
    assert not failure.stdout.strip(),failure
    log.append({'result':'PASS: unauthorized owner intake refuses without mutation across add/create, minted IDs and literal/file bodies; ordinary and complete packet intake succeed; native summary reports 35 requirements, 17 sources and one task; unavailable native reader refuses'})
finally:
    (ev/'live-intake.json').write_text(json.dumps(log,indent=2));shutil.rmtree(home)
print(log[-1])
