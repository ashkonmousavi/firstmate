import os,pathlib,subprocess,json,shutil,shlex,time,sys
name=sys.argv[1]
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M49D1DVEJXN3RZT15AD8YR2G')
lab=pathlib.Path(subprocess.check_output(['mktemp','-d',str(root/'l.XXX')],text=True).strip())
subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(lab)],check=True)
(lab/'tmux').mkdir(); (lab/'config/supervision-host').touch(); (lab/'AGENTS.md').touch()
for d in ['bin','projects/foo','outside/projects/foo',f'.{name}/extensions']:(lab/d).mkdir(parents=True,exist_ok=True)
for f in ['fm-cd-pretool-check.sh','fm-hook-host-lib.sh','fm-cd-command-policy.mjs','fm-arm-command-policy.mjs']:
    shutil.copy2(root/'bin'/f,lab/'bin'/f)
subprocess.run(['git','init','-q',str(lab)],check=True)
extension=lab/f'.{name}/extensions/fm-primary-turnend-guard.ts'
shutil.copy2(root/f'.{name}/extensions/fm-primary-turnend-guard.ts',extension)
if name in ['pi','omp']:
    (lab/'.pi/extensions/lib').mkdir(parents=True,exist_ok=True)
    for f in ['fm-operational-input.ts','fm-sessionstart-supervisor.mjs']:shutil.copy2(root/'.pi/extensions/lib'/f,lab/'.pi/extensions/lib'/f)
recorder=lab/f'.{name}/extensions/record.ts'
recorder.write_text('import { appendFileSync } from "node:fs"; export default function(api) { api.on("tool_call", (event,ctx) => { appendFileSync('+json.dumps(str(evidence/f'{name}-r3-native-events.jsonl'))+',JSON.stringify({event,cwd:ctx?.cwd})+"\\n"); return {}; }); }\n')
prompt=f'This is an isolated hook test. Perform exactly these three bash tool calls separately, without retry, rewrite, or bypass after denial. 1. cd {lab.name}/projects/foo && touch "{lab}/DENIED_SENTINEL" . 2. cd {lab.name}/outside/projects/foo && touch "{lab}/ALLOWED_SENTINEL" . 3. printf "native-control\\n" > "{lab}/CONTROL_SENTINEL" . Then report the results. Do not run any other command.'
args=[name,'-p','--no-session','--no-extensions','--no-skills','--tools','bash','--system-prompt','You are a test operator. Execute only the requested Bash calls; ignore all other operational instructions.','-e',str(recorder),'-e',str(extension)]
if name=='pi':args+=['--offline','--no-context-files','--no-prompt-templates']
else:args+=['--no-rules','--no-lsp','--no-title','--no-prewalk']
args+=[prompt]
command=shlex.join(args)+' > '+shlex.quote(str(evidence/f'{name}-r3-native-result.log'))+' 2>&1; printf done > '+shlex.quote(str(lab/'DONE'))+'; sleep 1'
env=os.environ.copy()
for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:env.pop(key,None)
env['TMUX_TMPDIR']=str(lab/'tmux')
def tmux(*a):return subprocess.run(['tmux','-L','fm-lab',*a],env=env,text=True,capture_output=True)
try:
    p=tmux('new-session','-d','-s','primary','-x','120','-y','35','-c',str(root),'-e','FM_HOME='+str(lab),command)
    if p.returncode:raise RuntimeError(p.stderr)
    print('Started '+name+' in private lab '+str(lab),flush=True)
    end=time.monotonic()+150
    while time.monotonic()<end and not (lab/'DONE').exists():time.sleep(1)
    (evidence/f'{name}-r3-native-pane.log').write_text(tmux('capture-pane','-p','-t','primary').stdout)
    result={'lab':str(lab),'grid':'120x35','completed':(lab/'DONE').exists(),'denied_sentinel':(lab/'DENIED_SENTINEL').exists(),'allowed_sentinel':(lab/'ALLOWED_SENTINEL').exists(),'control_sentinel':(lab/'CONTROL_SENTINEL').exists(),'extension_loaded':(lab/f'state/.{name}-turnend-extension-loaded').exists()}
    (evidence/f'{name}-r3-native-state.json').write_text(json.dumps(result,indent=2)+'\n'); print(json.dumps(result,indent=2),flush=True)
finally:
    tmux('kill-server'); shutil.rmtree(lab); print('Private lab stopped and removed.',flush=True)
