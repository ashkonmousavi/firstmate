# Reuse the already established live SSH transport, without rerunning scenarios.
import pathlib,subprocess,os
p=pathlib.Path.cwd()/'.test-live-backlog';root=p/'product';s=p/'ssh';ev=pathlib.Path('~/.no-mistakes/evidence/01M5HC5M6NQ7YQRQ363RXP9QHE')
h=p/'legacy-source';target=p/'legacy-target'
for x in (h,target):
 for d in ('data','state','bin'): (x/d).mkdir(parents=True,exist_ok=True)
 (x/'AGENTS.md').write_bytes((root/'AGENTS.md').read_bytes())
(h/'data/handoff').mkdir(exist_ok=True)
(h/'data/backlog.md').write_text('## Queued\n- [ ] unrelated - stays here\n\n## Done\n')
(h/'data/secondmates.md').write_text(f'- mate - work (host: 127.0.0.1; root: {root}; home: {target}; scope: work; projects: alpha; added 2026-10-21)\n')
(target/'.fm-secondmate-home').write_text('mate\n')
(h/'data/handoff/mate.outbox.md').write_text('## Queued\n- [ ] legacy-only - only remaining copy\n  full body\n  prep: data/legacy-only/prep.md\n\n## Done\n')
env=dict(os.environ)
for k in list(env):
 if k.startswith(('FM_','TASKS_AXI_')): env.pop(k)
env.update(FM_HOME=str(h),FM_SSH_BIN=str(s/'ssh'),TMPDIR=str(p/'tmp'))
with open(ev/'legacy-live.log','w',buffering=1) as f:
 cmd=[str(root/'bin/fm-backlog-handoff.sh'),'--resume-pending']
 print('$ '+' '.join(cmd),file=f)
 r=subprocess.run(cmd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
 print(r.stdout,file=f);print('exit='+str(r.returncode),file=f);assert r.returncode==0
 t=(target/'data/backlog.md').read_text();print('TARGET\n'+t,file=f)
 assert '- [ ] legacy-only - only remaining copy' in t and 'prep: data/legacy-only/prep.md' in t
 assert not list((h/'data/handoff').glob('*.outbox.md'))
 t=(h/'data/backlog.md').read_text();print('SOURCE\n'+t,file=f)
 assert '- [ ] unrelated -' in t and 'legacy-only' not in t
 print('PASS legacy sole-copy outbox migrates via registry and arrives through real SSH',file=f)
