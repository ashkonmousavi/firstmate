import os, pathlib, subprocess, json, shutil
root = pathlib.Path.cwd()
evidence = pathlib.Path('/home/tegris/.no-mistakes/evidence/01M49D1DVEJXN3RZT15AD8YR2G')
home = root / '.gate-cd-validation/product'
home.mkdir(parents=True)
for p in ['bin','projects/foo','projects/my clone','projects/clone/data','outside/projects/foo','projectsfoo','data']:
    (home/p).mkdir(parents=True, exist_ok=True)
(home/'AGENTS.md').touch()
for name in ['fm-cd-pretool-check.sh','fm-hook-host-lib.sh','fm-cd-command-policy.mjs','fm-arm-command-policy.mjs']:
    shutil.copy2(root/'bin'/name, home/'bin'/name)
subprocess.run(['git','init','-q',str(home)],check=True)
env = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','GROK_AGENT','GROK_HOOK_EVENT','CURSOR_AGENT','CLAUDECODE']}
env.update(FM_HOME=str(home),HOME=str(home.parent),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',CDPATH='')
check = str(home/'bin/fm-cd-pretool-check.sh')
records=[]
def probe(name, command, cwd, deny, mode='claude', transport='stdin', override=None, execute=False):
    args=[check]
    if mode in ['claude','cursor']: args+=['--'+mode]
    payload={'tool_name':'Shell' if mode=='cursor' else 'Bash','tool_input':{'command':command}, 'cwd':str(cwd)}
    if mode=='cursor': payload['cursor_version']='native-shape-probe'
    if mode=='grok': payload={'toolName':'run_terminal_command','toolInput':{'command':command},'cwd':str(cwd)}
    if override: payload['tool_input']['workdir']=override
    if transport=='cli': args+=['--command',command,'--cwd',str(cwd)]
    p=subprocess.run(args,input=json.dumps(payload) if transport=='stdin' else '',text=True,capture_output=True,env=env,cwd=cwd)
    observed = json.loads(p.stdout).get('permission')=='deny' if mode=='cursor' and p.stdout else p.returncode==2
    if deny: assert observed, (name,p.returncode,p.stdout,p.stderr)
    else: assert p.returncode==0 and not p.stdout and not p.stderr, (name,p.returncode,p.stdout,p.stderr)
    record=dict(name=name,command=command,cwd=str(cwd),mode=mode,transport=transport,payload=payload if transport=='stdin' else None,returncode=p.returncode,stdout=p.stdout,stderr=p.stderr,expected='deny' if deny else 'allow')
    if execute and not deny:
        x=subprocess.run(['bash','--noprofile','--norc','-c',command+'; pwd -P'],cwd=cwd,env=env,text=True,capture_output=True)
        record['shell']={'returncode':x.returncode,'stdout':x.stdout,'stderr':x.stderr}
        assert x.returncode==0
    records.append(record)
for cmd in ['cd projects/foo','cd ./projects/foo','pushd projects/foo',f'cd "{home}/projects/foo"','cd bin && cd ../projects/foo && touch data/SHOULD_NOT_EXIST','cd bin || true; cd ../projects/foo','pushd bin || true; pushd ../projects/foo','cd missing && true; cd projects/foo']:
    probe('protected literal move',cmd,home,True)
for cmd in ['cd ..','cd','cd -','cd /tmp','cd bin','popd','cd projectsfoo']:
    probe('nonproject move remains permitted',cmd,home,False)
probe('same relative operand outside protected root','cd projects/foo',home/'outside',False,execute=True)
probe('preceding cd changes resolution base',f'cd "{home}/outside" || true; cd projects/foo',home,False,execute=True)
for cmd in ['(cd projects/foo && pwd)','cd projects/foo | cat','cd projects/foo &','env cd projects/foo','echo "cd projects/foo"']:
    probe('existing child-process or data carve-out',cmd,home,False)
for cmd,deny in [('cd ~/product/projects/"my clone"',True),('cd \\~/product/projects/foo',False),('cd "~"/product/projects/foo',False),('cd \'~/product/projects/foo\'',False)]:
    probe('initial tilde interpretation',cmd,home,deny)
for mode in ['claude','codex','grok','cursor']:
    probe('harness deny shape', 'cd projects/foo',home,True,mode=mode)
    probe('harness actual base cwd', 'cd projects/foo',home/'outside',False,mode=mode)
for override,deny in [('bin',True),(str(home/'outside'),False)]:
    probe('tool workdir overrides payload cwd','cd ../projects/foo' if deny else 'cd projects/foo',home,deny,mode='codex',override=override)
# Reproduce and then prevent the actual persisted backlog leak.
(home/'data/backlog.md').write_text('home backlog\n')
subprocess.run(['bash','--noprofile','--norc','-c','cd bin && cd ../projects/clone && printf "unguarded leak\\n" >> data/backlog.md'],cwd=home,env=env,check=True)
assert (home/'projects/clone/data/backlog.md').read_text()=='unguarded leak\n'
assert (home/'data/backlog.md').read_text()=='home backlog\n'
(home/'projects/clone/data/backlog.md').unlink()
probe('backlog leak prevented before shell runs','cd bin && cd ../projects/clone && printf "guarded leak\\n" >> data/backlog.md',home,True,transport='cli')
assert not (home/'projects/clone/data/backlog.md').exists()
subprocess.run(['bash','--noprofile','--norc','-c','printf "safe home update\\n" >> data/backlog.md'],cwd=home,env=env,check=True)
records.append({'name':'persisted backlog proof','home_backlog':(home/'data/backlog.md').read_text(),'clone_backlog_exists':False})
# Unknown-cwd behavior is retained by the explicit declined decision.
p=subprocess.run([check,'--cursor'],input=json.dumps({'tool_name':'Shell','tool_input':{'command':'cd projects/foo'},'cursor_version':'native-shape-probe'}),text=True,capture_output=True,cwd=home,env=env)
assert p.returncode==0 and not p.stdout and not p.stderr
records.append({'name':'accepted missing-cwd fail-open','returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
(evidence/'r3-public-hook-transcript.json').write_text(json.dumps(records,indent=2)+'\n')
print(json.dumps({'interface':check,'operations':len(records),'home_backlog':(home/'data/backlog.md').read_text(),'clone_backlog_exists':False},indent=2))
