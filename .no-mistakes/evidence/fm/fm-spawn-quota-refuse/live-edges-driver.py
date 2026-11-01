"""Additional public-CLI quota boundaries in a disposable marked home.
Quota rows and retained-task records are input fixtures, never product doubles.
"""
import os,pathlib,subprocess,json,datetime
R=pathlib.Path.cwd();L=R/'.q';H=L/'h';EV=pathlib.Path(__file__).parent
E=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TASK_ID','FM_TEST_SEAM']:E.pop(k,None)
E.update(FM_HOME=str(H),HOME=str(L/'u'),TMPDIR=str(L/'tmp'),GROK_HOME=str(L/'u/.grok'),TMUX_TMPDIR=str(L/'t'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
E['TMUX']=subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','-t','launcher','#{socket_path}'],env=E,text=True).strip()+',0,0'
log=open(EV/'live-edges-transcript.log','w',buffering=1)
def run(label,args,contains=(),code=1):
 log.write('\n### '+label+'\n$ '+' '.join(args)+'\n')
 p=subprocess.run(args,env=E,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=60)
 log.write(p.stdout+'exit='+str(p.returncode)+'\n');assert p.returncode==code,(label,p.stdout)
 for s in contains:assert s in p.stdout,(label,s,p.stdout)
 return p.stdout
rulesfile=H/'config/crew-dispatch.json';prior=rulesfile.read_bytes()
p=json.load(open(L/'exhausted.json'))
p['schemaVersion']=6
for x in p['providers']:x['accountKey']='default'
row={'provider':'codex','accountKey':'openai-codex-work','quotaSemantics':{'status':'known','effectiveAvailability':[{'scope':'all_models','status':'known','effectivePercentRemaining':0,'runway':{'status':'exhausted_now'},'selection':{'spendPriority':-1}}]}}
p['providers'].append(row)
f=L/'account.json';f.write_text(json.dumps(p));E['FM_QUOTA_SNAPSHOT_FILE']=str(f)
rulesfile.write_text(json.dumps({'default':[{'harness':'pi','model':'openai-codex-work/gpt-6-astra','provider':'codex'},{'harness':'claude','model':'sonnet'}]}))
run('named exhausted account cannot borrow healthy default quota',['bin/fm-spawn.sh','deny',str(L/'project'),'--scout','--harness','pi','--model','openai-codex-work/gpt-6-astra'],['provider codex runway exhausted_now','--harness claude --model sonnet'])
# A literal model scope must beat a healthy harness-wide reading.
p=json.load(open(L/'healthy.json'))
for x in p['providers']:
 if x['provider']=='codex':x['quotaSemantics']['effectiveAvailability'].append({'scope':'model:configured-model','status':'known','effectivePercentRemaining':0,'runway':{'status':'exhausted_now'},'selection':{'spendPriority':-1}})
f=L/'model.json';f.write_text(json.dumps(p));E['FM_QUOTA_SNAPSHOT_FILE']=str(f)
rulesfile.write_text(json.dumps({'default':[{'harness':'codex','model':'configured-model'},{'harness':'claude','model':'sonnet'}]}))
run('sole configured model supplies quota scope without caller model',['bin/fm-spawn.sh','deny',str(L/'project'),'--scout','--harness','codex'],['exhausted_now at model:configured-model','--harness claude --model sonnet'])
# Rank tied healthy profiles equally, never invent an unconfigured runtime.
p=json.load(open(L/'exhausted.json'))
for x in p['providers']:
 if x['provider'] in ['claude','codex']:
  for row in x['quotaSemantics']['effectiveAvailability']:row['selection']['spendPriority']=9
f=L/'tie.json';f.write_text(json.dumps(p));E['FM_QUOTA_SNAPSHOT_FILE']=str(f);rulesfile.write_bytes(prior)
run('highest spendPriority ties are both disclosed',['bin/fm-spawn.sh','deny',str(L/'project'),'--scout','--harness','grok'],['--harness codex --model gpt-6.1-sol','--harness claude --model sonnet'])
# Released-copy is the serialized public retention contract. Supply the proof
# fields but no worktree; exhausted quota must refuse before recreation.
id='released-live';d=H/'data'/id;d.mkdir(exist_ok=True)
(d/'brief.md').write_text("# Task\n## Captain's intent\nQuota retained-copy proof.\n## Firstmate spec\nNo work authorized.\n")
head=subprocess.check_output(['git','-C',str(L/'project'),'rev-parse','HEAD'],env=E,text=True).strip()
meta=H/'state'/(id+'.meta')
fields={'window':'launcher:fm-'+id,'endpoint_task_id':id,'worktree':str(H/'state'/(id+'.released-copy')),'released_head':head,'released_branch':'fm/'+id,'released_pr':'https://github.com/example/repo/pull/7','project':str(L/'project'),'harness':'grok','kind':'ship','mode':'no-mistakes','yolo':'off','branch':'fm/'+id,'tasktmp':'/tmp/fm-'+id,'model':'grok-4.7','effort':'default','spawn_gen':'s1.1.1','pr':'https://github.com/example/repo/pull/7'}
meta.write_text(''.join(k+'='+v+'\n' for k,v in fields.items()));before=meta.read_bytes()
E['FM_QUOTA_SNAPSHOT_FILE']=str(L/'exhausted.json')
run('released copy refuses before recreating local branch',['bin/fm-control.sh',id,'relaunch','--harness','grok','--model','grok-4.7','--note','must not recreate'],['fm-control refuses explicit harness grok','Best alternative: provider codex'])
assert meta.read_bytes()==before
assert not pathlib.Path(fields['worktree']).exists()
log.write('Released metadata byte-identical; released sentinel remains absent.\n')
# Try the real remote host entrypoint in a separately marked disposable home.
# Its stock remapping to code-root/parent-route is refused by the gate guard.
remote=L/'r';subprocess.run(['bin/fm-lab-home.sh','create',str(remote)],check=True,env=E,stdout=log,stderr=log)
(remote/'bin').mkdir();(remote/'AGENTS.md').write_text('# Disposable seeded home\n');(remote/'.fm-secondmate-home').write_text('remote-live\n')
E['FM_HOME']=str(remote)
run('remote live attempt stopped by stock gate containment',['bin/fm-remote-secondmate-control.sh','launch','remote-live','grok','grok-4.7','-','herdr'],['refusing fleet lifecycle from inside a no-mistakes gate worktree','remote host-local secondmate launch failed'])
log.write('Remote launch was NOT exercised past containment. It requires a gate-supported remote lab state mapping and named fm-lab-* session selection; no bypass or fm-remote session was used.\n')
log.close()
