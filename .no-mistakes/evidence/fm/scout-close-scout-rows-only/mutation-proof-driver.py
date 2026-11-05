import os,pathlib,subprocess,json,shutil
root=pathlib.Path.cwd(); scratch=root/'.gate-test-tmp/mutation'; scratch.mkdir()
ev=pathlib.Path('~/.no-mistakes/evidence/01M6PMP5XS3RS0RTB7NANXCK57')
log=(ev/'red-green-mutants.log').open('w',buffering=1)
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','HERDR_'))}
env['HOME']=str(scratch/'user'); pathlib.Path(env['HOME']).mkdir()
def run(args,allow=False,e=None):
 p=subprocess.run([str(x) for x in args],cwd=root,env=e or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 log.write('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+f'[exit {p.returncode}]\n')
 if p.returncode and not allow: raise RuntimeError(p.stdout)
 return p
current=(root/'bin/fm-backlog-transition-lib.sh').read_text()
base=subprocess.check_output(['git','show','472bf088d2f2ed6f5ecb1cbf83540b2fcef0f355:bin/fm-backlog-transition-lib.sh'],text=True)
variants={'base-ship-owner-only':base,'target':current,'mutant-close-on-missing-kind':current.replace('exit 2 unless defined $kind && $kind =~ /\\S/;', 'exit 1 unless defined $kind && $kind =~ /\\S/;')}
results=[]
for name,src in variants.items():
 code=scratch/name;code.mkdir()
 for f in (root/'bin').iterdir():
  if f.name!='fm-backlog-transition-lib.sh': (code/f.name).symlink_to(f)
 (code/'fm-backlog-transition-lib.sh').write_text(src)
 for fault in ([False,True] if name=='target' else [name=='mutant-close-on-missing-kind']):
  label=name+('-unreadable' if fault else '-legacy')
  home=scratch/label; run(['bash',root/'bin/fm-lab-home.sh','create',home])
  (home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
  (home/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n- [ ] build-row - legacy BUILD data/build-row/report.md blocked-by: test-row blocked-by: refresh-row\n\n## Done\n')
  (home/'data/build-row').mkdir();(home/'data/build-row/report.md').write_text('prep complete\n')
  (home/'state/build-row.meta').write_text('kind=scout\nspawn_gen=proof\n')
  e=env|{'FM_HOME':str(home),'FM_STATE_OVERRIDE':str(home/'state')}
  if fault:
   fake=home/'fault';fake.mkdir();real=shutil.which('tasks-axi')
   (fake/'tasks-axi').write_text('#!/usr/bin/env bash\nif [ "${1:-}" = show ]; then "'+real+'" "$@" | sed \'/^  kind:/d\'; exit "${PIPESTATUS[0]}"; fi\nexec "'+real+'" "$@"\n')
   (fake/'tasks-axi').chmod(0o755);e['PATH']=str(fake)+':'+e['PATH']
  p=run(['bash','-c','. "$1/bin/fm-tasks-axi-lib.sh"; . "$2/fm-backlog-transition-lib.sh"; fm_backlog_done "$3/data" build-row --report data/build-row/report.md','_',root,code,home],allow=True,e=e)
  out=run(['tasks-axi','show','build-row','--full','--file',home/'data/backlog.md']).stdout
  state=next(x.split(': ',1)[1] for x in out.splitlines() if x.startswith('  state: '))
  if name=='target': assert state=='queued' and (p.returncode!=0 if fault else p.returncode==0)
  else: assert state=='done' and p.returncode==0
  results.append({'variant':name,'show_kind_removed':fault,'state':state,'completion_exit':p.returncode,'oracle':'Only a readable standalone kind-scout row may close (Cut 16)'} )
log.write(json.dumps(results,indent=2)+'\n');log.close()
(ev/'red-green-mutants.json').write_text(json.dumps(results,indent=2)+'\n')
shutil.rmtree(scratch)
