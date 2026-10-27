import os,pathlib,subprocess,tempfile,json,hashlib,copy
r=pathlib.Path.cwd()
env={k:v for k,v in os.environ.items() if k not in {'FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TASKS_AXI_FILE','TASKS_AXI_BACKEND'}}
env['TMPDIR']=str(r/'.test-phase-tmp')
with tempfile.TemporaryDirectory(prefix='correction-live-',dir=env['TMPDIR']) as d:
 h=pathlib.Path(d);(h/'data').mkdir();(h/'state').mkdir();(h/'.tasks.toml').write_text('backend = "markdown"\n');(h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 def cmd(args,expected=0):
  p=subprocess.run([str(r/'bin/fm-tasks-axi.sh'),*map(str,args)],env={**env,'FM_HOME':str(h)},text=True,capture_output=True,timeout=30)
  print('$ fm-tasks-axi.sh '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]',flush=True);assert p.returncode==expected;return p.stdout
 def packet(n,expected=None):
  text=f'Explanation revision {n}';return {'version':1,'origin_home':str(h),'origin_task_id':'request','expected_body_sha256':expected,'interpretation_owner':'intake','interpretation_complete':True,'sources':[{'session_id':'live-session','message_uuid':f'source-{n}','file_ref':'retired.json','source_custody':'complete','full_text':text,'full_text_sha256':hashlib.sha256(text.encode()).hexdigest()}],'requirements':[{'id':f'r{n}','kind':'explanation','source_message_uuid':f'source-{n}','text_ref':text,'safe_text':None,'source_binding':'verified_complete','disposition':'pending','proof_refs':[],'superseded_by':[],'proof_kind':'reply','acceptance_level':'source'}],'corrections':[]}
 def save(p):
  path=h/'packet.json';path.write_text(json.dumps(p));path.chmod(0o600);return path
 def body():
  shown=cmd(['show','request','--full']);p=subprocess.run([str(r/'bin/fm-request-acceptance.py'),'show-body','--task-id','request'],input=shown,capture_output=True,text=True);assert p.returncode==0;return p.stdout
 cmd(['add','request','Correctable explanation','--owner-request-file',save(packet(1))])
 before=body();raw=(h/'data/backlog.md').read_bytes();digest=hashlib.sha256(before.encode()).hexdigest()
 cycle=packet(2,digest);cycle['corrections']=[{'id':'r1','superseded_by':['r2']},{'id':'r2','superseded_by':['r1']}]
 cmd(['update','request','--owner-request-file',save(cycle)],2)
 assert (h/'data/backlog.md').read_bytes()==raw and not (h/'data/note-archive.md').exists()
 for n in (2,3):
  p=packet(n,hashlib.sha256(before.encode()).hexdigest());p['corrections']=[{'id':f'r{n-1}','superseded_by':[f'r{n}']}]
  path=save(p);cmd(['update','request','--owner-request-file',path]);before=body();raw=(h/'data/backlog.md').read_bytes()
  cmd(['update','request','--owner-request-file',path]);assert (h/'data/backlog.md').read_bytes()==raw
 stale=packet(4,'0'*64);cmd(['update','request','--owner-request-file',save(stale)],2);assert (h/'data/backlog.md').read_bytes()==raw
 for n in (1,2,3):assert f'Explanation revision {n}' in before
 assert (h/'data/note-archive.md').exists()
 print('SCENARIO native corrections: cycle and stale preimage refuse without writes; multistep correction preserves all source history; exact replay makes no second write',flush=True)
print('Disposable home removed',flush=True)
