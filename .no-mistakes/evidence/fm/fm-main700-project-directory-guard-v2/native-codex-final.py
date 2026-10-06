import os, pathlib, subprocess, json, shutil, shlex, time
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M49D1DVEJXN3RZT15AD8YR2G')
# A short workspace-contained lab keeps the private Unix socket below 108 bytes.
lab=pathlib.Path(subprocess.check_output(['mktemp','-d',str(root/'l.XXX')],text=True).strip())
subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(lab)],check=True)
(lab/'tmux').mkdir()
(lab/'config/supervision-host').touch()
(lab/'AGENTS.md').touch()
for d in ['bin','projects/foo','outside/projects/foo']:(lab/d).mkdir(parents=True,exist_ok=True)
for name in ['fm-cd-pretool-check.sh','fm-hook-host-lib.sh','fm-cd-command-policy.mjs','fm-arm-command-policy.mjs']:
    shutil.copy2(root/'bin'/name,lab/'bin'/name)
subprocess.run(['git','init','-q',str(lab)],check=True)
payloadlog=evidence/'codex-final-payloads.jsonl'
shim=lab/'bin/record-hook.sh'
shim.write_text('#!/usr/bin/env bash\npayload=$(cat)\nprintf "%s\\n" "$payload" >> '+shlex.quote(str(payloadlog))+'\nprintf "%s" "$payload" | '+shlex.quote(str(lab/'bin/fm-cd-pretool-check.sh'))+'\n')
shim.chmod(0o700)
(lab/'.codex').mkdir()
settings=lab/'.codex/hooks.json'
settings.write_text(json.dumps({'hooks':{'PreToolUse':[{'matcher':'Bash','hooks':[{'type':'command','command':str(shim)}]}]}}))
prompt=f'This is an isolated hook test. Perform exactly three separate exec_command tool calls, using the specified workdir parameter. Do not retry or bypass a denied call. 1. workdir "{lab}/bin", command cd ../projects/foo && touch "{lab}/DENIED_SENTINEL" . 2. workdir "{lab}/outside", command cd projects/foo && touch "{lab}/ALLOWED_SENTINEL" . 3. workdir "{lab}", command printf "native-control\\n" > "{lab}/CONTROL_SENTINEL" . Then report the results. Run no other commands.' 
args=['codex','exec','--ephemeral','--ignore-user-config','--ignore-rules','--enable','hooks','--dangerously-bypass-hook-trust','-s','workspace-write','-c','approval_policy="never"','-c','projects={'+json.dumps(str(lab))+'={trust_level="trusted"}}','--cd',str(lab),prompt]
command=shlex.join(args)+' > '+shlex.quote(str(evidence/'codex-final-result.log'))+' 2>&1; printf done > '+shlex.quote(str(lab/'DONE'))+'; sleep 1'
env=os.environ.copy()
for name in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:env.pop(name,None)
env.update(TMUX_TMPDIR=str(lab/'tmux'),CLAUDE_CODE_DISABLE_AUTO_MEMORY='1')
def tmux(*a):return subprocess.run(['tmux','-L','fm-lab',*a],env=env,text=True,capture_output=True)
try:
    p=tmux('new-session','-d','-s','primary','-x','120','-y','35','-c',str(root),'-e','FM_HOME='+str(lab),command)
    if p.returncode: raise RuntimeError(p.stderr)
    print('Started Codex on private lab socket; lab='+str(lab),flush=True)
    end=time.monotonic()+150
    while time.monotonic()<end and not (lab/'DONE').exists():time.sleep(1)
    (evidence/'codex-final-pane.log').write_text(tmux('capture-pane','-p','-t','primary').stdout)
    result={'lab':str(lab),'socket':str(lab/'tmux'),'grid':'120x35','completed':(lab/'DONE').exists(),'denied_sentinel':(lab/'DENIED_SENTINEL').exists(),'allowed_sentinel':(lab/'ALLOWED_SENTINEL').exists(),'control_sentinel':(lab/'CONTROL_SENTINEL').exists()}
    (evidence/'codex-final-state.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2),flush=True)
finally:
    tmux('kill-server')
    shutil.rmtree(lab)
    print('Private lab server stopped and lab removed.',flush=True)
