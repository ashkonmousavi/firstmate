import json, os, pathlib, shutil, subprocess, sys
repo=pathlib.Path.cwd();lab=repo/'.l';project=repo/'.validation-tmp/live-project'
assert not lab.exists() and not project.exists()
lab.mkdir(); project.mkdir()
env={k:os.environ[k] for k in ('PATH','USER','LOGNAME') if k in os.environ}
env.update(HOME=str(lab/'user-home'),FM_HOME=str(lab),TMPDIR=str(repo/'.validation-tmp/tmp'),TMUX=str(lab/('tmux-'+str(os.getuid()))/'fm-lab')+',1,0',NO_MISTAKES_GATE='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
try:
    subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],env=env,check=True,capture_output=True)
    (lab/'user-home').mkdir()
    (lab/'config/crew-harness').write_text('codex\n')
    (lab/'config/backend').write_text('tmux\n')
    account=lab/'account';(account/'rules').mkdir(parents=True)
    (account/'config.toml').write_text('cli_auth_credentials_store="file"\nmodel="gpt-6.1-sol"\n')
    (account/'AGENTS.md').write_text('Disposable validation only.\n')
    (account/'rules/default.rules').write_text('prefix_rule(pattern=["echo"],decision="allow")\n')
    subprocess.run(['git','init','-q','-b','main',str(project)],env=env,check=True)
    for ident,body,args,expected in [('empty','',[],'codex-accounts needs literal absolute folders'),('signed-out',str(account)+'\n',[],'no usable signed-in folder'),('raw',str(account)+'\n',['CODEX_HOME=/unwanted codex'],'canonical Codex launch')]:
        task='lab-'+ident
        brief=lab/'data'/task;brief.mkdir()
        (brief/'brief.md').write_text('# Task\n## Captain\x27s intent\nProve invalid account configuration cannot open a worker.\n\n## Firstmate spec\nRefuse before allocating resources.\n')
        (lab/'config/codex-accounts').write_text(body)
        command=['bash','bin/fm-spawn.sh',task,str(project),'--scout','--backend','tmux',*args]
        if not args:command+=['--harness','codex']
        result=subprocess.run(command,env=env,capture_output=True,text=True,timeout=45)
        print('$ '+' '.join(command));print('exit='+str(result.returncode));print(result.stdout+result.stderr,flush=True)
        assert result.returncode==1 and expected in result.stdout+result.stderr,result
        assert not (lab/'state'/f'{task}.meta').exists()
        assert not (lab/('tmux-'+str(os.getuid()))/'fm-lab').exists()
        print('Observed: no task metadata or private tmux endpoint was published.',flush=True)
finally:
    shutil.rmtree(lab);shutil.rmtree(project)
    print('Marked lab home and disposable project removed.',flush=True)
