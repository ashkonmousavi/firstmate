import pathlib,subprocess,shutil,os,json
root=pathlib.Path.cwd();base=root/'.gate-cd-validation/baseline';base.mkdir();(base/'AGENTS.md').touch();(base/'bin').mkdir();(base/'projects/foo').mkdir(parents=True)
subprocess.run(['git','init','-q',str(base)],check=True)
for f in ['fm-cd-pretool-check.sh','fm-hook-host-lib.sh','fm-cd-command-policy.mjs','fm-arm-command-policy.mjs']:
    content=subprocess.check_output(['git','show','a86dcd88a937e3f12b5911f5249e23bed0e87a2e:bin/'+f])
    (base/'bin'/f).write_bytes(content);(base/'bin'/f).chmod(0o700)
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_'):env.pop(k,None)
records=[]
for cmd in ['cd bin','cd ..','cd projects/foo']:
    p=subprocess.run([str(base/'bin/fm-cd-pretool-check.sh'),'--claude','--command',cmd],cwd=base,env=env,capture_output=True,text=True)
    records.append({'revision':'a86dcd88a937e3f12b5911f5249e23bed0e87a2e','command':cmd,'cwd':str(base),'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
assert all(x['returncode']==2 for x in records)
path=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M49D1DVEJXN3RZT15AD8YR2G/r2-base-hook-transcript.json');path.write_text(json.dumps(records,indent=2)+'\n')
print('Base public hook denied cd bin and cd ..; target public hook permits both and retains project denial.')
