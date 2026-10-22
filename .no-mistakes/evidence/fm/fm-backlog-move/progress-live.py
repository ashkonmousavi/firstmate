import pathlib,os,subprocess
p=pathlib.Path.cwd()/'.test-live-backlog';root=p/'product';e=pathlib.Path('~/.no-mistakes/evidence/01M5HC5M6NQ7YQRQ363RXP9QHE');h=p/'progress-live-source';t=p/'progress-live-target'
for x in (h,t):
 for d in ('bin','state','data'): (x/d).mkdir(parents=True)
 (x/'AGENTS.md').write_bytes((root/'AGENTS.md').read_bytes())
payload='## In flight\n\n## Queued\n- [ ] p1 - first parent\n- [ ] p2 - second parent\n- [ ] c1 - child blocked-by: p1 - first reason (since 2026-10-21) blocked-by: p2 - second reason (done 2026-10-21)\n  prep: data/c1/prep.md\n\n## Done\n'
(h/'data/backlog.md').write_text(payload);(t/'data/backlog.md').write_text(payload)
env=dict(os.environ)
for k in list(env):
 if k.startswith(('FM_','TASKS_AXI_')): env.pop(k)
env.update(FM_HOME=str(h),TMPDIR=str(p/'tmp'))
with (e/'progress-live.log').open('w',buffering=1) as f:
 def call(args,ok=True):
  print('$ '+' '.join(map(str,args)),file=f)
  r=subprocess.run(list(map(str,args)),env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30)
  print(r.stdout,file=f);print('exit='+str(r.returncode),file=f)
  assert (r.returncode==0)==ok
 for key in ('p1','p2','c1'): call(['tasks-axi','done',key,'--file',t/'data/backlog.md','--backend','markdown'])
 # Move trailing progress metadata without changing either dependency reason.
 expected=(t/'data/backlog.md').read_text().replace('first reason (since 2026-10-21)','first reason (reported 2026-10-22)').replace('second reason (done 2026-10-21)','second reason (merged 2026-10-22)')
 (t/'data/backlog.md').write_text(expected.replace('first reason','wrong reason'))
 move=[root/'bin/fm-backlog-handoff.sh','--to',t,'p1','p2','c1']
 call(move,False);assert (h/'data/backlog.md').read_text()==payload
 print('SOURCE AFTER REASON MISMATCH\n'+(h/'data/backlog.md').read_text(),file=f)
 (t/'data/backlog.md').write_text(expected)
 call(move);assert (t/'data/backlog.md').read_text()==expected
 source=(h/'data/backlog.md').read_text();assert '- [ ] c1 -' not in source and 'moved to progress-live-target (' in source
 print('CONFIRMED TARGET WITH PROGRESS\n'+expected,file=f)
 print('SOURCE AFTER MATCHING RECEIPT\n'+source,file=f)
 print('PASS all edge reasons are checked and lifecycle progress alone does not reject matching payloads',file=f)
