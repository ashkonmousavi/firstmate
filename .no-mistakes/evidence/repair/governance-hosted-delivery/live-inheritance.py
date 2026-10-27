import os,pathlib,subprocess,tempfile,hashlib,json
root=pathlib.Path.cwd()
env={k:v for k,v in os.environ.items() if k not in {'FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_INHERITABLE_CONFIG','FM_TEST_SEAM'}}
env['TMPDIR']=str(root/'.test-phase-tmp')
with tempfile.TemporaryDirectory(prefix='inherit-live-',dir=env['TMPDIR']) as d:
    home=pathlib.Path(d)/'home';(home/'config').mkdir(parents=True);(home/'data').mkdir()
    receiver=root/'bin/fm-remote-inherit.sh'
    def put(text,generation,expected=0):
        args=[str(receiver),'put','config/worker-sheet.md',str(len(text.encode())),hashlib.sha256(text.encode()).hexdigest(),str(generation)]
        p=subprocess.run(args,input=text,text=True,capture_output=True,env={**env,'FM_HOME':str(home)},timeout=30)
        print(f'$ fm-remote-inherit.sh put config/worker-sheet.md <bytes> <sha256> {generation}\n{p.stdout}{p.stderr}[exit {p.returncode}]',flush=True)
        assert p.returncode==expected
        return p
    put('Worker policy v1\n',1)
    alias=home/'data/worker-sheet.md';canonical=home/'config/worker-sheet.md'
    assert alias.is_symlink() and alias.resolve()==canonical and alias.read_text()=='Worker policy v1\n'
    alias.unlink()
    put('Worker policy v1\n',2)
    assert alias.is_symlink() and alias.resolve()==canonical
    put('Worker policy v2\n',3)
    assert alias.read_text()=='Worker policy v2\n'
    print('Persisted policy via compatibility alias:',alias.read_text().strip(),flush=True)
    alias.unlink();alias.write_text('Latest owner edit\n')
    put('Worker policy v3\n',4,1)
    assert alias.read_text()=='Latest owner edit\n' and canonical.read_text()=='Worker policy v2\n'
    print('Preserved canonical:',canonical.read_text().strip(),'| Preserved owner edit:',alias.read_text().strip(),flush=True)
    canonical.unlink()
    put('Worker policy v3\n',4,1)
    assert alias.read_text()=='Latest owner edit\n' and not canonical.exists()
    print('SCENARIO native receiver: publish/update/alias repair work; replaced and orphaned owner edits refuse without losing bytes',flush=True)

    # Explicit active config and data paths are independently selectable local inputs.
    src=pathlib.Path(d)/'primary';dst=pathlib.Path(d)/'child'
    config=src/'active-config';data=src/'active-data'
    for path in [config,data,dst/'config',dst/'data',src/'config',src/'data']:path.mkdir(parents=True,exist_ok=True)
    (config/'worker-sheet.md').write_text('Active policy\n')
    (src/'config/worker-sheet.md').write_text('Inactive policy\n')
    cmd='source "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$2" "$3" "$4" "$5" "$6"'
    args=['bash','-c',cmd,'_',str(root),str(config),str(dst/'config'),str(src),str(data),str(dst/'data')]
    p=subprocess.run(args,env={**env,'FM_INHERITABLE_CONFIG':'worker-sheet.md','FM_HOME':str(src),'FM_ROOT':str(root),'FM_CONFIG_INHERIT_REPORT':str(pathlib.Path(d)/'report')},capture_output=True,text=True,timeout=30)
    print('$ propagate_inheritable_config <active-config> <child-config> <primary> <active-data> <child-data>\n'+p.stdout+p.stderr+f'[exit {p.returncode}]',flush=True)
    assert p.returncode==0 and (data/'worker-sheet.md').resolve()==config/'worker-sheet.md'
    assert (dst/'data/worker-sheet.md').read_text()=='Active policy\n'
    assert (src/'config/worker-sheet.md').read_text()=='Inactive policy\n'
    print('Persisted child alias:',(dst/'data/worker-sheet.md').read_text().strip(),flush=True)
    print('SCENARIO active-path inheritance: active config/data converge and inactive default policy stays unchanged',flush=True)
print('Disposable homes removed',flush=True)
