import os, pathlib, subprocess, tempfile, json, time, shutil, hashlib
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M6QTD3J1C5T56947M5XWP13V')
lab=pathlib.Path(tempfile.mkdtemp(prefix='live-',dir=R/'.test-tmp'))
env=dict(os.environ)
for k in list(env):
    if k.startswith(('FM_', 'HERDR_', 'GIT_CONFIG_')) or k in ('TMUX','TMUX_PANE','NO_MISTAKES_GATE','CLAUDECODE','CODEX_HOME'): env.pop(k,None)
env.update(HOME=str(lab/'user'),CODEX_HOME=str(lab/'codex'),FM_HOME=str(lab),TREEHOUSE_ROOT=str(lab/'pool'),TMPDIR=str(R/'.test-tmp'),SHELL='/bin/bash',TERM='xterm-256color',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
def run(args,check=True,**kwargs):
    p=subprocess.run(list(map(str,args)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,**kwargs)
    print('$', ' '.join(map(str,args)), '\n'+p.stdout, 'exit='+str(p.returncode),flush=True)
    if check and p.returncode: raise RuntimeError(args)
    return p
sock=None
ids=[]
def remove_owned(path):
    if not path.exists(): return
    for base, dirs, files in os.walk(path):
        os.chmod(base,0o700)
    shutil.rmtree(path)
def codex_pids(target):
    shell=int(run(['tmux','-L','fm-lab','list-panes','-t',target,'-F','#{pane_pid}']).stdout.strip())
    table=subprocess.check_output(['ps','-eo','pid=,ppid=,comm='],env=env,text=True)
    rows=[line.split(None,2) for line in table.splitlines()]
    descendants={shell}
    for _ in range(20):
        descendants |= {int(pid) for pid,parent,comm in rows if int(parent) in descendants}
    return {int(pid) for pid,parent,comm in rows if int(pid) in descendants and comm=='codex'}
try:
    run(['bin/fm-lab-home.sh','create',lab])
    (lab/'user').mkdir(); (lab/'codex').mkdir()
    tool=lab/'user/.config/skills-master/.agents/skills/activity/activity.sh'; tool.parent.mkdir(parents=True); shutil.copyfile('/mnt/c/Users/Tegri/.codex/skills/activity/activity.sh',tool)
    env['FM_ROOT_OVERRIDE']=str(R)
    sock=run(['bin/fm-lab-home.sh','tmux-dir',lab]).stdout.strip(); env['TMUX_TMPDIR']=sock
    (lab/'config/backend').write_text('tmux\n'); (lab/'config/crew-harness').write_text('codex\n')
    (lab/'config/lane-capacity').write_text('100 0\n')
    (lab/'config/machine-admission.json').write_text(json.dumps({'schema':'fm-machine-admission.v1','memory_floor_gib':0,'memory_full_avg60_max':100,'disk_floor_gib':0,'disk_paths':[str(lab)]}))
    config='check_for_update_on_startup=false\napproval_policy="never"\nmodel="lab-model"\nmodel_provider="lab"\n[features]\nhooks=false\n[model_providers.lab]\nname="Isolated offline startup"\nbase_url="http://127.0.0.1:9/v1"\nwire_api="responses"\nrequires_openai_auth=false\n'
    (lab/'codex/config.toml').write_text(config)
    (lab/'primary-codex').mkdir(); (lab/'primary-codex/config.toml').write_text(config)
    # Use actual MCP peers; their handshake fixture logs exact child PID receipts.
    native=R/'tests/lane-profile-native.py'
    for name in ('gitnexus','claude-context','custom_index','retained'):
        with (lab/'codex/config.toml').open('a') as f:
            f.write('\n[mcp_servers."'+name+'"]\ncommand='+json.dumps(shutil.which('python3'))+'\nargs='+json.dumps([str(native),'mcp',name,str(lab/(name+'.pid'))])+'\n')
    (lab/'config/code-index-mcp-servers').write_text('custom_index\n')
    proj=lab/'project'; run(['git','init','-q','-b','main',proj]); (proj/'README.md').write_text('Disposable lane-profile validation\n')
    run(['git','-C',proj,'add','.']); run(['git','-C',proj,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','seed'])
    run(['git','clone','-q','--bare',proj,lab/'origin.git']); run(['git','-C',proj,'remote','add','origin',lab/'origin.git'])
    run(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','primary','-n','main','-x','140','-y','45','-c',R,'-e','FM_HOME='+str(lab),'env','CODEX_HOME='+str(lab/'primary-codex'),'codex'])
    env['TMUX']=run(['tmux','-L','fm-lab','display-message','-p','#{socket_path},#{pid},0']).stdout.strip()
    time.sleep(2)
    run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:main'])
    for selection in ('typo','bad-alias','ci-tooling','governance','product-code','ci-tooling-scout'):
        profile=selection.replace('t3-','').replace('-scout','')
        if profile=='bad-alias': profile='governance'; (lab/'config/code-index-mcp-servers').write_text('bad.id\n')
        id='live'+str(os.getpid())+selection.replace('-',''); ids.append(id)
        d=lab/'data'/id; d.mkdir(); (d/'brief.md').write_text('# Task\n## Captain\'s intent\nRemain idle; only startup is under test.\n\n## Firstmate spec\nDo not change files.\n')
        flags=['--scout'] if selection.endswith('-scout') else ['--mode','local-only','--yolo','off']
        if selection.startswith('t3-'): flags+=['--backend','t3code']
        p=run(['bin/fm-spawn.sh',id,proj,*flags,'--lane-profile',profile],check=False,timeout=150)
        (E/(selection+'-spawn.log')).write_text(p.stdout)
        if selection.startswith('t3-'):
            assert p.returncode!=0 and 'backend=t3code cannot apply --lane-profile' in p.stdout
            assert not (lab/'state'/f'{id}.meta').exists()
            print('LIVE T3 reduced profile refused before allocation: '+profile,flush=True); continue
        if selection=='bad-alias':
            assert p.returncode!=0 and 'requires one server ID per line' in p.stdout
            assert not (lab/'state'/f'{id}.meta').exists()
            (lab/'config/code-index-mcp-servers').write_text('custom_index\n')
            print('LIVE malformed alias refused without metadata',flush=True); continue
        if profile=='typo':
            assert p.returncode!=0 and 'unknown --lane-profile' in p.stdout
            assert not (lab/'state'/f'{id}.meta').exists()
            print('LIVE refusal: unknown profile; no task metadata',flush=True); continue
        meta=lab/'state'/f'{id}.meta'
        if meta.exists():
            (E/(profile+'-meta.txt')).write_text(meta.read_text())
            vals=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
            target=vals['window']; capture=run(['tmux','-L','fm-lab','capture-pane','-p','-t',target],check=False)
            (E/(profile+'-pane.txt')).write_text(capture.stdout)
        if p.returncode: raise RuntimeError('live spawn failed for '+profile)
        observed=set()
        for name in ('gitnexus','claude-context','custom_index','retained'):
            marker=lab/(name+'.pid')
            if marker.exists():
                for pid in marker.read_text().splitlines():
                    state=run(['ps','-p',pid,'-o','pid=,ppid=,args='],check=False)
                    if state.returncode==0 and str(lab/(name+'.pid')) in state.stdout: observed.add(name)
                marker.unlink()
        expected={'retained'} if profile!='product-code' else {'retained','gitnexus','claude-context','custom_index'}
        assert observed==expected,(profile,observed,expected)
        print('LIVE startup '+profile+': '+','.join(sorted(observed)),flush=True)
        # Unsupported replacement must leave exact PID and metadata intact.
        if profile=='governance':
            prior=meta.read_bytes(); before=codex_pids(target); assert before
            print('BEFORE refusal native Codex PIDs='+str(sorted(before)),flush=True)
            q=run(['bin/fm-control.sh',id,'relaunch','--harness','claude','--note','Unsupported replacement preflight'],check=False,timeout=90)
            assert q.returncode and 'requires a canonical Codex ship/scout launch' in q.stdout
            assert meta.read_bytes()==prior
            assert codex_pids(target)==before
            print('AFTER refusal same native Codex PIDs='+str(sorted(before)),flush=True)
            print('LIVE replacement refusal preserves task record and running endpoint',flush=True)
            q=run(['bin/fm-control.sh',id,'relaunch','--note','Continue with reduced MCP startup'],check=False,timeout=150)
            assert q.returncode==0
            assert 'lane_profile=governance' in meta.read_text()
            replacement=codex_pids(target); assert replacement and replacement.isdisjoint(before)
            print('LIVE successful relaunch preserves governance; replacement native Codex PIDs='+str(sorted(replacement)),flush=True)
            new_marker=lab/'retained.pid'; assert new_marker.exists()
            for pid in new_marker.read_text().splitlines():
                state=run(['ps','-p',pid,'-o','pid=,ppid=,args='],check=False)
                assert state.returncode==0
            for name in ('gitnexus','claude-context','custom_index'): assert not (lab/(name+'.pid')).exists()
            new_marker.unlink()
            print('LIVE relaunched governance: retained only',flush=True)
        q=run(['bin/fm-control.sh',id,'exit'],check=False,timeout=90)
        if q.returncode: raise RuntimeError('exit failed')
        # Ensure next profile does not count previous peers.
        time.sleep(1)
    print('LIVE all requested tmux scenarios passed',flush=True)
finally:
    if sock:
        run(['tmux','-L','fm-lab','kill-server'],check=False)
        run(['bin/fm-lab-home.sh','teardown',lab],check=False)
    token=hashlib.sha256(str(lab).encode()).hexdigest()
    for id in ids:
        for path in (pathlib.Path('/tmp')/('fm-'+id),pathlib.Path('/tmp')/('fm-'+id+'+'+token)):
            remove_owned(path)
    remove_owned(lab)
    print('CLEANUP complete: lab server stopped; owned home and runtime temp paths removed',flush=True)
