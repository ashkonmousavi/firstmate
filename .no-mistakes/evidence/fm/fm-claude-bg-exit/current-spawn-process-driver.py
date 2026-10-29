import os, subprocess, pathlib, time, json, shutil
root=pathlib.Path.cwd(); lab=root/'.validation/spawn-lab'; product=root/'.validation/product'
evidence=pathlib.Path('~/.no-mistakes/evidence/01M644V5T0RZ7AA08H11AYG9KM'); socket='fm-lab-spawn-validate'
base=os.environ.copy()
for key in list(base):
    if key.startswith('FM_') or key in ('TMUX','CLAUDECODE','CLAUDE_CODE_SESSION_ID','CLAUDE_CONFIG_DIR'): base.pop(key,None)
base.update(TMPDIR=str(root/'.validation'),DISABLE_AUTOUPDATER='1')
def run(args,env=None,check=True):
    p=subprocess.run(args,env=env or base,capture_output=True,text=True)
    if check and p.returncode: raise RuntimeError(f'{args}: {p.returncode} {p.stdout} {p.stderr}')
    return p
lab.mkdir(exist_ok=True)
home=lab/'parent'; run(['bash','bin/fm-lab-home.sh','create',str(home)])
(home/'config/supervision-host').touch(); (home/'config/crew-harness').write_text('claude\n'); (home/'config/launch-env-allowlist').write_text('')
user=lab/'user'; user.mkdir(); account=lab/'account with spaces'; account.mkdir()
base.update(HOME=str(user),CLAUDE_CONFIG_DIR=str(account),FM_HOME=str(home))
run(['tmux','-L',socket,'new-session','-d','-s','primary','-x','160','-y','44','-c',str(root),'bash --noprofile --norc'])
base['TMUX']=run(['tmux','-L',socket,'display-message','-p','#{socket_path},#{pid},0']).stdout.strip()
rows=[]
try:
    for name,raw in [('canonical',None),('fallback','claude --invalid-fm-lab-option || claude --model haiku'),('changed-directory',f"cd '{root}' && claude --model haiku"),('quoted-account',f"CLAUDE_CONFIG_DIR='{account}' claude --invalid-fm-lab-option || claude --model haiku")]:
        mate=lab/name
        run(['bash','bin/fm-lab-home.sh','create',str(mate)])
        (mate/'.fm-secondmate-home').write_text(name+'\n'); (mate/'bin').mkdir(); shutil.copyfile(root/'AGENTS.md',mate/'AGENTS.md')
        (mate/'data/charter.md').write_text('Disposable launch verification. Do not execute tools or change files.\n')
        env=base.copy(); env['FM_SKIP_SECONDMATE_SYNC']='1'; env['FM_SKIP_SECONDMATE_INHERIT']='1'
        args=['bash',str(product/'bin/fm-spawn.sh'),name,str(mate),'--secondmate','--harness',raw or 'claude']
        if raw is None: args+=['--model','haiku']
        p=run(args,env,False)
        print(name,p.returncode,p.stdout,p.stderr,flush=True)
        if p.returncode: raise RuntimeError('spawn failed '+name)
        meta=dict(line.split('=',1) for line in (home/f'state/{name}.meta').read_text().splitlines() if '=' in line)
        target=meta['window']; pid=int(run(['tmux','-L',socket,'display-message','-p','-t',target,'#{pane_pid}']).stdout)
        found=[]
        for _ in range(120):
            tree={}
            for line in run(['ps','-axo','pid=,ppid=,comm=']).stdout.splitlines():
                vals=line.split(None,2)
                if len(vals)==3: tree[int(vals[0])]=(int(vals[1]),vals[2])
            descendants={pid}
            while True:
                added={p for p,(parent,_) in tree.items() if parent in descendants}-descendants
                if not added: break
                descendants|=added
            found=[p for p in descendants if tree.get(p,(0,''))[1].split('/')[-1].startswith('claude')]
            if found:
                current=pathlib.Path(f'/proc/{found[-1]}/cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
                if name not in ('fallback','quoted-account') or '--model haiku' in current:
                    break
                found=[]
            time.sleep(.25)
        if not found: raise RuntimeError('no final real Claude process '+name)
        process=found[-1]
        penv=dict(x.decode(errors='replace').split('=',1) for x in pathlib.Path(f'/proc/{process}/environ').read_bytes().split(b'\0') if b'=' in x)
        actual={k:penv.get(k) for k in ('CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF','CLAUDE_CODE_DISABLE_AGENT_VIEW','CLAUDE_CONFIG_DIR')}
        assert actual=={'CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF':'1','CLAUDE_CODE_DISABLE_AGENT_VIEW':'1','CLAUDE_CONFIG_DIR':str(account)},actual
        assert meta.get('claude_config_dir')==str(account),meta
        cmd=pathlib.Path(f'/proc/{process}/cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
        time.sleep(1)
        screen=run(['tmux','-L',socket,'capture-pane','-p','-t',target]).stdout
        (evidence/f'spawn-{name}-terminal.txt').write_text(screen)
        rows.append(dict(scenario=name,pid=process,environment=actual,recorded_account=meta['claude_config_dir'],command=cmd,spawn_output=p.stdout))
        print(json.dumps(rows[-1]),flush=True)
    (evidence/'spawn-live.json').write_text(json.dumps(rows,indent=2))
finally:
    run(['tmux','-L',socket,'kill-server'],check=False)
    for path in lab.rglob("*"):
        if path.is_dir(): path.chmod(path.stat().st_mode | 0o700)
    shutil.rmtree(lab)
