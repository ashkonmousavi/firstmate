import pathlib,subprocess,os
p=pathlib.Path.cwd();w=p/'.test-live-backlog';h=w/'retire-lab';target=w/'retire-target';target.mkdir()
env=dict(os.environ)
for k in list(env):
 if k.startswith(('FM_','TASKS_AXI_')): env.pop(k)
env['TMPDIR']=str(w/'tmp')
subprocess.run([str(p/'bin/fm-lab-home.sh'),'create',str(h)],env=env,check=True,stdout=subprocess.PIPE)
(h/'data/secondmates.md').write_text(f'- mate - work (host: 127.0.0.1; root: {w}/product; home: {target}; scope: work; projects: alpha; added 2026-10-21)\n')
(h/'state/mate.meta').write_text(f'window=fm-lab-retire:w1:p1\nendpoint_task_id=mate\nharness=claude\nkind=secondmate\nmode=secondmate\nremote_host=127.0.0.1\nremote_root={w}/product\nremote_backend=herdr\nremote_herdr_session=fm-lab-retire\nremote_target=fm-lab-retire:w1:p1\nhome={target}\n')
(h/'data/handoff').mkdir(); payload='## Queued\n- [ ] legacy-retire - only copy\n\n## Done\n'
(h/'data/handoff/mate.outbox.md').write_text(payload)
env.update(FM_HOME=str(h),FM_SSH_BIN=str(w/'ssh/ssh'))
e=pathlib.Path('~/.no-mistakes/evidence/01M5HC5M6NQ7YQRQ363RXP9QHE')
with (e/'retirement-guard-live.log').open('w') as f:
 cmd=[str(p/'bin/fm-teardown.sh'),'mate'];print('$ FM_HOME='+str(h)+' '+' '.join(cmd),file=f)
 r=subprocess.run(cmd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
 print(r.stdout,file=f);print('exit='+str(r.returncode),file=f)
 assert r.returncode!=0 and 'pending backlog outbox' in r.stdout
 batches=list((h/'data/handoff').glob('*.outbox.md'));assert len(batches)==1 and batches[0].read_text()==payload
 assert target.is_dir() and 'mate - work' in (h/'data/secondmates.md').read_text()
 print('Retained payload after refusal:\n'+batches[0].read_text(),file=f)
 print('PASS retirement refuses the pre-upgrade sole-copy batch and migrates it without loss',file=f)
