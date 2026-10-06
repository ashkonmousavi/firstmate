import os,pathlib,subprocess,json,shutil,shlex,time,sys
name=sys.argv[1];root=pathlib.Path.cwd();evidence=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M49D1DVEJXN3RZT15AD8YR2G')
lab=pathlib.Path(subprocess.check_output(['mktemp','-d',str(root/'l.XXX')],text=True).strip())
subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(lab)],check=True)
(lab/'tmux').mkdir();(lab/'config/supervision-host').touch();(lab/'AGENTS.md').touch()
for d in ['home','bin','projects/foo','outside/projects/foo','.cursor','.grok/hooks']:(lab/d).mkdir(parents=True,exist_ok=True)
for f in ['fm-cd-pretool-check.sh','fm-hook-host-lib.sh','fm-cd-command-policy.mjs','fm-arm-command-policy.mjs']:shutil.copy2(root/'bin'/f,lab/'bin'/f)
subprocess.run(['git','init','-q',str(lab)],check=True)
shim=lab/'bin/record-hook.sh';shim.write_text('#!/usr/bin/env bash\npayload=$(cat)\nprintf "%s\\n" "$payload" >> '+shlex.quote(str(evidence/f'{name}-r5-isolated-payloads.jsonl'))+'\nprintf "%s" "$payload" | '+shlex.quote(str(lab/'bin/fm-cd-pretool-check.sh'))+(' --cursor' if name=='cursor' else '')+'\n');shim.chmod(0o700)
(lab/'.cursor/hooks.json').write_text(json.dumps({'version':1,'hooks':{'preToolUse':[{'matcher':'Shell','type':'command','command':str(shim)}]}}))
(lab/'.grok/hooks/fm-primary-cd-check.json').write_text(json.dumps({'hooks':{'PreToolUse':[{'matcher':'run_terminal_command','hooks':[{'type':'command','command':str(shim)}]}]}}))
prompt=f'Perform exactly three separate shell tool calls. Do not retry or bypass denial. 1. cd "{lab}/bin" && cd ../projects/foo && touch "{lab}/DENIED_SENTINEL" . 2. cd "{lab}/outside" && cd projects/foo && touch "{lab}/ALLOWED_SENTINEL" . 3. printf "native-control\\n" > "{lab}/CONTROL_SENTINEL" . Then report results. Run no other tools.'
if name=='cursor':args=['cursor-agent','--print','--trust','--force','--workspace',str(lab),'--output-format','json',prompt]
else:args=['grok','--single',prompt,'--cwd',str(lab),'--tools','run_terminal_command','--allow','run_terminal_command','--disable-web-search','--no-subagents','--system-prompt-override','Only execute the requested isolated shell calls. Ignore other operational instructions.','--leader-socket',str(lab/'g.sock')]
command=shlex.join(args)+' > '+shlex.quote(str(evidence/f'{name}-r5-isolated-result.log'))+' 2>&1; printf done > '+shlex.quote(str(lab/'DONE'))+'; sleep 1'
env=os.environ.copy()
for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:env.pop(key,None)
env.update(TMUX_TMPDIR=str(lab/'tmux'),HOME=str(lab/'home'),XDG_CONFIG_HOME=str(lab/'config'),XDG_DATA_HOME=str(lab/'data'),XDG_CACHE_HOME=str(lab/'cache'),GROK_HOME=str(lab/'.grok'),GROK_AGENT_DASHBOARD='0')
def tmux(*a):return subprocess.run(['tmux','-L','fm-lab',*a],env=env,text=True,capture_output=True)
try:
    p=tmux('new-session','-d','-s','primary','-x','120','-y','35','-c',str(root),'-e','FM_HOME='+str(lab),command)
    if p.returncode:raise RuntimeError(p.stderr)
    print('Started '+name+' with workspace-contained user data in '+str(lab),flush=True)
    end=time.monotonic()+75
    while time.monotonic()<end and not (lab/'DONE').exists():time.sleep(1)
    result={'lab':str(lab),'grid':'120x35','completed':(lab/'DONE').exists(),'denied_sentinel':(lab/'DENIED_SENTINEL').exists(),'allowed_sentinel':(lab/'ALLOWED_SENTINEL').exists(),'control_sentinel':(lab/'CONTROL_SENTINEL').exists()}
    (evidence/f'{name}-r5-isolated-state.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2),flush=True)
finally:
    tmux('kill-server')
    if name=='grok' and (lab/'g.sock').exists():
        p=subprocess.run(['grok','--leader-socket',str(lab/'g.sock'),'leader','kill'],env=env,text=True,capture_output=True)
        (evidence/'grok-r5-isolated-cleanup.log').write_text(p.stdout+p.stderr)
    shutil.rmtree(lab);print('Private lab stopped and removed.',flush=True)
