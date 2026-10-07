import os, pathlib, subprocess, json, shlex, tempfile, time
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M49VVNMKYRSJTX7CEVNAZ8PP')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=root/'.test-phase'))
subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],check=True)
socket=subprocess.check_output(['bash','bin/fm-lab-home.sh','tmux-dir',str(lab)],text=True).strip()
env=os.environ.copy()
for key in list(env):
    if key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TMUX','TMUX_PANE','FM_HOME','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND','CLAUDECODE','CLAUDE_PID'] or key.startswith('CLAUDE_CODE_'):
        env.pop(key,None)
env['TMUX_TMPDIR']=socket
def write(rel,content):
    p=lab/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(content)
write('config/supervision-host-off','')
write('config/backlog-backend','manual\n')
write('data/captain.md','This is a disposable validation home. Only read records and recommend sequencing. No dispatch, shell execution, publication, or external operations.\n')
write('data/backlog.md','''# Backlog
## Queued
- LAB1: Release Q study feature. Priority 1. Blocked-by: LAB2.
- LAB2: Fix study save loss. Priority 3. Blocked-by: none.
- LAB3: Extend Q chart history. Priority 2. Blocked-by: none.
''')
write('data/secondmates.md',f'- navigation - Registered navigation-scoped planner (home: {lab}/planner; scope: roadmap planning; projects: Q).\n')
write('data/projects.md',f'- Q: {lab}/projects/Q - study and chart project; documentation starts at README.md.\n')
write('planner/data/README.md','Planner publication index. Current roadmap wave: waves/2026-10-06.md. Superseded roadmap wave: waves/2026-10-05.md.\n')
write('planner/data/waves/2026-10-05.md','Superseded wave: dispatch LAB3 first, then LAB1.\n')
write('planner/data/waves/2026-10-06.md','Current wave: fix LAB2 first to unlock LAB1. Then LAB1, then LAB3. LAB3 is behind the study save-loss repair despite its higher backlog priority.\n')
write('projects/Q/README.md','Q keeps its current bug list in data/bugs.md.\n')
write('projects/Q/data/bugs.md','Q-BUG-91: Study edits can be lost on save. Release blocker; tracked repair LAB2. LAB1 must wait for this fix. LAB3 chart expansion is deferred until this defect is fixed.\n')
(evidence/'lab-inputs.json').write_text(json.dumps({str(p.relative_to(lab)):p.read_text().replace(str(lab),'<LAB>') for p in lab.rglob('*.md')},indent=2))
branch=subprocess.check_output(['bash','bin/fm-branch-prompt.sh'],text=True)
(evidence/'generated-branch-prompt.txt').write_text(branch)
try:
    cases=[('push','/push'),('primary-heartbeat','heartbeat: review queued work'),('branch-heartbeat','heartbeat: review queued work'),('missing-bug-list','/push')]
    for name,event in cases:
        if name=='missing-bug-list': (lab/'projects/Q/data/bugs.md').unlink()
        output=evidence/(name+'.jsonl')
        prompt=f'''{event}
For this bounded read-only pass the only operational home is FM_HOME={lab}. The three queued tasks need a sequencing recommendation; do not execute scripts, dispatch, modify records, or access any operator home. Discover the relevant records from this home's data directory and Q project documentation. Return the next eligible task and ordering or the concrete missing input that prevents deciding. Stop after gathering and the recommendation. You can read the tracked instructions in the current worktree.'''
        args=['claude','-p','--restricted','--tools','Read,Glob,Grep','--allowedTools','Read','Glob','Grep','--permission-mode','dontAsk','--setting-sources','','--settings','{"disableAllHooks":true}','--strict-mcp-config','--output-format','stream-json','--verbose']
        if name=='branch-heartbeat': args+=['--append-system-prompt',branch]
        args += [prompt]
        command=shlex.join(args)+' > '+shlex.quote(str(output))+' 2>&1; printf "\\nEXIT=%s\\n" "$?"'
        launcher=lab/'launch.sh'
        launcher.write_text('#!/usr/bin/env bash\n'+command+'\n')
        subprocess.run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e','FM_HOME='+str(lab),'bash '+shlex.quote(str(launcher))],env=env,check=True)
        print('START',name,flush=True)
        for _ in range(180):
            time.sleep(1)
            done=subprocess.run(['tmux','-L','fm-lab','has-session','-t','primary'],env=env,capture_output=True).returncode!=0
            if done:break
        pane=subprocess.run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary'],env=env,capture_output=True,text=True)
        if pane.returncode==0:(evidence/(name+'-pane.txt')).write_text(pane.stdout)
        subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,capture_output=True)
        if output.exists():
            text=output.read_text()
            print(name,text[-2400:],flush=True)
            if 'EXIT=1' in text or not done: break
finally:
    subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,capture_output=True)
    subprocess.run(['bash','bin/fm-lab-home.sh','teardown',str(lab)],check=True)
    import shutil
    shutil.rmtree(lab)
    print('LAB REMOVED',flush=True)
