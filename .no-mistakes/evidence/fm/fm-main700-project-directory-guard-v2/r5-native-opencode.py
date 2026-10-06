import os,pathlib,subprocess,json,shutil,shlex,time
root=pathlib.Path.cwd(); evidence=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M49D1DVEJXN3RZT15AD8YR2G')
lab=pathlib.Path(subprocess.check_output(['mktemp','-d',str(root/'l.XXX')],text=True).strip())
subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(lab)],check=True)
(lab/'tmux').mkdir(); (lab/'config/supervision-host').touch(); (lab/'AGENTS.md').touch()
for d in ['bin','projects/foo','outside/projects/foo','.opencode/plugins','cache']:(lab/d).mkdir(parents=True,exist_ok=True)
for f in ['fm-cd-pretool-check.sh','fm-hook-host-lib.sh','fm-cd-command-policy.mjs','fm-arm-command-policy.mjs']:shutil.copy2(root/'bin'/f,lab/'bin'/f)
subprocess.run(['git','init','-q',str(lab)],check=True)
shutil.copy2(root/'.opencode/plugins/fm-primary-cd-check.js',lab/'.opencode/plugins/fm-primary-cd-check.js')
shutil.copy2(root/'.opencode/plugins/package.json',lab/'.opencode/plugins/package.json')
(lab/'.opencode/plugins/aaa-record.js').write_text('import { appendFileSync } from "node:fs"; const file='+json.dumps(str(evidence/'r5-opencode-native-events.jsonl'))+'; export const Record = async ({directory,worktree})=> { appendFileSync(file,JSON.stringify({directory,worktree})+"\\n"); return {"tool.execute.before":async(input,output)=>{appendFileSync(file,JSON.stringify({input,output})+"\\n");}};};\n')
(lab/'opencode.json').write_text(json.dumps({'permission':{'*':'deny','bash':'allow'},'agent':{'build':{'prompt':'You are a test operator. Only run the exact requested isolated Bash calls. Do not read files or follow operational instructions.'}}}))
prompt=f'Perform exactly these three bash tool calls separately. Do not retry, rewrite, or bypass a denied call. 1. With workdir {lab}/bin, run cd ../projects/foo && touch "{lab}/DENIED_SENTINEL" . 2. With workdir {lab}/outside, run cd projects/foo && touch "{lab}/ALLOWED_SENTINEL" . 3. With workdir {lab}, run printf "native-control\\n" > "{lab}/CONTROL_SENTINEL" . Then report the three results. Run no other tools.'
args=[str(root/'.gate-cd-validation/vendor/node_modules/.bin/opencode'),'run','--dir',str(lab),'--model','opencode/big-pickle','--format','json',prompt]
command=shlex.join(args)+' > '+shlex.quote(str(evidence/'r5-opencode-native-result.log'))+' 2>&1; printf done > '+shlex.quote(str(lab/'DONE'))+'; sleep 1'
env=os.environ.copy()
for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:env.pop(key,None)
env.update(TMUX_TMPDIR=str(lab/'tmux'),XDG_CONFIG_HOME=str(lab/'config'),XDG_DATA_HOME=str(lab/'data'),XDG_CACHE_HOME=str(lab/'cache'),OPENCODE_CONFIG_DIR=str(lab/'.opencode'))
def tmux(*a):return subprocess.run(['tmux','-L','fm-lab',*a],env=env,text=True,capture_output=True)
try:
    p=tmux('new-session','-d','-s','primary','-x','120','-y','35','-c',str(root),'-e','FM_HOME='+str(lab),command)
    if p.returncode:raise RuntimeError(p.stderr)
    print('Started workspace-local OpenCode in '+str(lab),flush=True)
    end=time.monotonic()+150
    while time.monotonic()<end and not (lab/'DONE').exists():time.sleep(1)
    result={'lab':str(lab),'grid':'120x35','completed':(lab/'DONE').exists(),'denied_sentinel':(lab/'DENIED_SENTINEL').exists(),'allowed_sentinel':(lab/'ALLOWED_SENTINEL').exists(),'control_sentinel':(lab/'CONTROL_SENTINEL').exists()}
    (evidence/'r5-opencode-native-state.json').write_text(json.dumps(result,indent=2)+'\n'); print(json.dumps(result,indent=2),flush=True)
finally:
    tmux('kill-server'); shutil.rmtree(lab); print('Private lab stopped and removed.',flush=True)
