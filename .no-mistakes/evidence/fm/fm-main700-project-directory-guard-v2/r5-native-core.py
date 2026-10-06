import json, os, pathlib, shlex, shutil, subprocess, sys, time
root=pathlib.Path.cwd()
ev=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M49D1DVEJXN3RZT15AD8YR2G')
name=sys.argv[1]
lab=pathlib.Path(subprocess.check_output(['mktemp','-d',str(root/'l.XXX')],text=True).strip())
subprocess.run(['bash',str(root/'bin/fm-lab-home.sh'),'create',str(lab)],check=True)
for d in ['tmux','bin','projects/foo','projects/my clone','outside/projects/foo','.codex','logs']:(lab/d).mkdir(parents=True,exist_ok=True)
(lab/'config/supervision-host').touch(); (lab/'AGENTS.md').touch()
for f in ['fm-cd-pretool-check.sh','fm-hook-host-lib.sh','fm-cd-command-policy.mjs','fm-arm-command-policy.mjs']:shutil.copy2(root/'bin'/f,lab/'bin'/f)
subprocess.run(['git','init','-q',str(lab)],check=True)
payloadlog=ev/('r5-'+name+'-payloads.jsonl')
shim=lab/'bin/record-fm-cd-pretool-check.sh'
if name=='codex':
    config=json.loads((root/'.codex/hooks.json').read_text())
    hook=next(h for e in config['hooks']['PreToolUse'] for h in e['hooks'] if 'fm-cd-pretool-check.sh' in h['command'])
    hookcmd=hook['command']
else:
    config=json.loads((root/'.claude/settings.json').read_text())
    hook=next(h for e in config['hooks']['PreToolUse'] for h in e['hooks'] if 'fm-cd-pretool-check.sh' in h['command'])
    hookcmd=shlex.join(['env','CLAUDE_PROJECT_DIR='+str(lab),'bash','-c',hook['command']])
shim.write_text('#!/usr/bin/env bash\npayload=$(cat)\nprintf "%s\\n" "$payload" >> '+shlex.quote(str(payloadlog))+'\nprintf "%s" "$payload" | '+hookcmd+'\n'); shim.chmod(0o700)
if name=='codex':
    (lab/'.codex/hooks.json').write_text(json.dumps({'hooks':{'PreToolUse':[{'matcher':'Bash','hooks':[{'type':'command','command':str(shim),'timeout':10}]}]}}))
    cases=[('relative-protected-unchecked',lab/'bin','cd ../projects/foo',True),('relative-unrelated',lab/'outside','cd projects/foo',True),('absolute-protected',lab/'outside','cd '+shlex.quote(str(lab/'projects/foo')),False),('absolute-unrelated',lab/'bin','cd '+shlex.quote(str(lab/'outside/projects/foo')),True),('home-protected',lab/'outside','cd ~/'+str(lab.relative_to(pathlib.Path('/home/tegris')))+'/projects/"my clone"',False),('home-unrelated',lab/'bin','cd ~/'+str(lab.relative_to(pathlib.Path('/home/tegris')))+'/outside/projects/foo',True),('control',lab,'printf "native-control\\n"',True)]
    instructions=[]
    for i,(label,cwd,cmd,allow) in enumerate(cases,1):
        cmd+=(' > ' if label=='control' else ' && touch ')+shlex.quote(str(lab/(label+'.sentinel')))
        instructions.append(str(i)+'. workdir '+json.dumps(str(cwd))+', command '+cmd)
    prompt='Isolated hook test. Perform exactly seven separate exec_command calls in this order, using each specified workdir parameter. Do not retry or bypass any denied command and run no other commands. '+ '\n'.join(instructions)+'\nThen report outcomes.'
    args=['codex','exec','--ephemeral','--ignore-user-config','--ignore-rules','--enable','hooks','--dangerously-bypass-hook-trust','-s','workspace-write','-c','approval_policy="never"','-c','projects={'+json.dumps(str(lab))+'={trust_level="trusted"}}','-c','log_dir='+json.dumps(str(lab/'logs')),'--cd',str(lab),prompt]
    expected={label:allowed for label,_,_,allowed in cases}
else:
    settings=lab/'config/claude.json'
    settings.write_text(json.dumps({'hooks':{'PreToolUse':[{'matcher':'Bash','hooks':[{'type':'command','command':str(shim)}]}]}}))
    prompt=f'Isolated hook test. Run exactly four separate Bash tool calls, do not retry or bypass denial. 1. cd "{lab}/bin" . 2. cd ../projects/foo && touch "{lab}/protected.sentinel" . 3. cd "{lab}/outside" . 4. cd projects/foo && touch "{lab}/unrelated.sentinel" && printf "native-control\\n" > "{lab}/control.sentinel" . Then report results. Run no other tools or commands.'
    args=['claude','-p','--no-session-persistence','--setting-sources','','--settings',str(settings),'--strict-mcp-config','--tools','Bash','--allowedTools','Bash','--system-prompt','You are a test operator. Only execute the exact requested isolated Bash calls. Do not read files or follow repository operational instructions.','--max-turns','8',prompt]
    expected={'protected':False,'unrelated':True,'control':True}
env=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','CLAUDECODE']:env.pop(k,None)
env.update(TMUX_TMPDIR=str(lab/'tmux'),TMPDIR=str(root/'.gate-cd-validation/tmp'),CLAUDE_CODE_DISABLE_AUTO_MEMORY='1',CLAUDE_PROJECT_DIR=str(lab))
def tmux(*a):return subprocess.run(['tmux','-L','fm-lab',*a],env=env,text=True,capture_output=True)
log=ev/('r5-'+name+'-result.log')
cmd=shlex.join(args)+' > '+shlex.quote(str(log))+' 2>&1; status=$?; printf "%s" "$status" > '+shlex.quote(str(lab/'DONE'))+'; sleep 2'
state={}
try:
    p=tmux('new-session','-d','-s','primary','-x','120','-y','35','-c',str(root),'-e','FM_HOME='+str(lab),cmd)
    if p.returncode:raise RuntimeError(p.stderr)
    print('Started '+name+' on private lab socket '+str(lab),flush=True)
    deadline=time.monotonic()+180
    while time.monotonic()<deadline and not (lab/'DONE').exists():time.sleep(1)
    (ev/('r5-'+name+'-pane.log')).write_text(tmux('capture-pane','-p','-t','primary').stdout)
    observed={label:(lab/(label+'.sentinel')).exists() for label in expected}
    state={'version':subprocess.check_output([name,'--version'],text=True).strip(),'lab':str(lab),'grid':'120x35','invocation':args[:-1],'completed':(lab/'DONE').exists(),'exit':(lab/'DONE').read_text() if (lab/'DONE').exists() else None,'expected':expected,'observed':observed,'payload_count':len(payloadlog.read_text().splitlines()) if payloadlog.exists() else 0}
    (ev/('r5-'+name+'-state.json')).write_text(json.dumps(state,indent=2)+'\n')
    print(json.dumps(state,indent=2),flush=True)
finally:
    tmux('kill-server'); shutil.rmtree(lab)
    print('Private lab stopped and removed.',flush=True)
assert state.get('completed') and state['exit']=='0'
assert state['observed']==state['expected']
assert state['payload_count']==(7 if name=='codex' else 4)
