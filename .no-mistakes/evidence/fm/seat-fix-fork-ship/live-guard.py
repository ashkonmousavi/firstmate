import json, os, pathlib, shlex, shutil, subprocess, time
root=pathlib.Path.cwd(); evidence=pathlib.Path('~/.no-mistakes/evidence/01M6HVSX6XW3XZP10BEN54C09Z'); lab=root/'c'
version=subprocess.check_output(['claude','--version'],text=True).strip()
results=[]
recorder=root/'.test-phase-tmp/record-stop.py'
recorder.write_text('''import json,os,pathlib,subprocess,sys
payload=sys.stdin.read(); home=pathlib.Path(os.environ['FM_HOME']); data=json.loads(payload)
p=subprocess.run(['bash',os.environ['LAB_GUARD'],'--claude','--state-claims'],input=payload,text=True,capture_output=True)
with (home/'events.jsonl').open('a') as f:f.write(json.dumps({'payload':data,'rc':p.returncode,'stdout':p.stdout,'stderr':p.stderr})+'\\n')
path=pathlib.Path(data['transcript_path'])
if path.is_file():(home/('transcript-'+str(len((home/'events.jsonl').read_text().splitlines()))+'.jsonl')).write_bytes(path.read_bytes())
sys.stdout.write(p.stdout);sys.stderr.write(p.stderr);sys.exit(p.returncode)
''')
activity=pathlib.Path.home()/'.config/skills-master/.agents/skills/activity/activity.sh'
for name in ['incident-no-read','check-wake-only','successful-read','failed-read','formatted-question']:
    subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
    (lab/'tmux').mkdir();(lab/'bin').symlink_to(root/'bin',target_is_directory=True);(lab/'AGENTS.md').touch()
    subprocess.run(['git','-c','init.defaultBranch=main','init','-q',str(lab)],check=True,env={**os.environ,'GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_NOSYSTEM':'1'})
    (lab/'config/lane-capacity').write_text('10 0\n')
    settings=lab/'settings.json'
    settings.write_text(json.dumps({'hooks':{'Stop':[{'hooks':[{'type':'command','command':'python3 '+shlex.quote(str(recorder))}]}]}}))
    prompt='This is an isolated Stop-hook regression. Do not call tools. Reply exactly: Laptop 8 live of 8, admission no. If a Stop hook blocks this reply, reply exactly: Recorded.'
    if name=='check-wake-only':prompt='check-wake activity.sh: Laptop 8 live of 8, admission no.\n'+prompt
    if name in ('successful-read','failed-read'):
        command='bash '+shlex.quote(str(activity))+' --machine-json '+shlex.quote(str(lab if name=='successful-read' else lab/'missing'))
        claim='PC: 0 working, 10 available.' if name=='successful-read' else 'Laptop 8 live of 8, admission no.'
        prompt=f'This is an isolated Stop-hook regression. First use Bash to run exactly: {command}\nThen reply exactly: {claim} If a Stop hook blocks the reply, reply exactly: Recorded. Never retry a tool after a hook block.'
    if name=='formatted-question':prompt='This is an isolated Stop-hook regression. Do not call tools. Reply exactly: 👉 How many lanes are free?'
    args=['claude','-p',prompt,'--dangerously-skip-permissions','--model','haiku','--effort','low','--setting-sources','','--settings',str(settings),'--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--system-prompt','Follow the isolated regression prompt exactly. Only the specified Bash read is authorized. Do not perform other work.','--tools','Bash' if name in ('successful-read','failed-read') else '', '--output-format','stream-json','--verbose','--max-turns','6']
    private={k:v for k,v in os.environ.items() if k not in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','CLAUDECODE']}
    private['TMUX_TMPDIR']=str(lab/'tmux')
    assignments=['FM_HOME='+str(lab),'FM_ROOT_OVERRIDE='+str(lab),'LAB_GUARD='+str(root/'bin/fm-turnend-guard.sh'),'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false','CLAUDE_CODE_SEND_FEEDBACK=0']
    command=shlex.join(['env',*assignments,*args])+' > '+shlex.quote(str(lab/'stream.jsonl'))+' 2> '+shlex.quote(str(lab/'stderr.log'))+'; result=$?; printf "%s\\n" "$result" > '+shlex.quote(str(lab/'exit'))+'; exit "$result"'
    try:
        subprocess.run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e','FM_HOME='+str(lab),command],env=private,check=True,capture_output=True)
        deadline=time.monotonic()+160
        while not (lab/'exit').exists() and time.monotonic()<deadline:time.sleep(.2)
        assert (lab/'exit').exists(),name+' timed out'
        rc=int((lab/'exit').read_text())
        stream=(lab/'stream.jsonl').read_text();stderr=(lab/'stderr.log').read_text()
        events=[json.loads(line) for line in (lab/'events.jsonl').read_text().splitlines()] if (lab/'events.jsonl').exists() else []
        result={'case':name,'version':version,'command':args,'exit':rc,'events':events,'stderr':stderr}
        results.append(result)
        for f in lab.glob('transcript-*.jsonl'):shutil.copyfile(f,evidence/(name+'-'+f.name))
        (evidence/(name+'-claude.jsonl')).write_text(stream)
        assert rc==0,(name,rc,stderr,stream[-2000:])
        assert any(json.loads(line).get('type')=='result' and not json.loads(line).get('is_error') for line in stream.splitlines() if line.startswith('{')),(name,stream[-2000:])
        expected=[2,0] if name in ('incident-no-read','check-wake-only','failed-read') else [0]
        assert [e['rc'] for e in events]==expected,(name,events)
        if expected[0]==2:assert '(capacity)' in events[0]['stderr'],events
        print(f'{version} {name}: real Stop exits '+','.join(str(e['rc']) for e in events),flush=True)
    finally:
        subprocess.run(['tmux','-L','fm-lab','kill-server'],env=private,capture_output=True)
        (evidence/'live-guard.json').write_text(json.dumps(results,indent=2))
        shutil.rmtree(lab)
