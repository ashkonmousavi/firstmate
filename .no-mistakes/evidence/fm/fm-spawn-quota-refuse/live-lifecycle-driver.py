"""Run from the same disposable .q/h lab as live-quota-driver.py.
This checks startup and quota metadata; it does not authenticate a Grok user
or claim model inference. Both terminal and harness are the real executables.
"""
import os,subprocess,json,pathlib,datetime,time,sys
ROOT=pathlib.Path.cwd();L=ROOT/'.q';H=L/'h';EV=pathlib.Path(__file__).parent
E=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TASK_ID','FM_TEST_SEAM']:E.pop(k,None)
E.update(FM_HOME=str(H),HOME=str(L/'u'),TMPDIR=str(L/'tmp'),GROK_HOME=str(L/'u/.grok'),TMUX_TMPDIR=str(L/'t'),TREEHOUSE_ROOT=str(L/'pool'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',FM_QUOTA_SNAPSHOT_FILE=str(L/'exhausted.json'))
def tm(*a):return subprocess.check_output(['tmux','-L','fm-lab',*a],env=E,text=True)
E['TMUX']=tm('display-message','-p','-t','launcher','#{socket_path}').strip()+',0,0'
log=open(EV/'live-lifecycle-transcript.log','a' if '--continue' in sys.argv else 'w',buffering=1)
def run(label,args,code=0,contains=()):
 log.write('\n### '+label+'\n$ '+' '.join(args)+'\n')
 p=subprocess.run(args,env=E,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=150)
 log.write(p.stdout+'exit='+str(p.returncode)+'\n');assert p.returncode==code,(label,p.stdout)
 for s in contains:assert s in p.stdout,(label,s,p.stdout)
 return p.stdout

def stop(id):
 target='launcher:fm-'+id
 for i in range(300):
  if 'ctrl+q' in tm('capture-pane','-p','-t',target):break
  time.sleep(.1)
 else:raise AssertionError('Grok quit footer never became ready')
 tm('send-keys','-t',target,'C-q')
 for i in range(50):
  if tm('display-message','-p','-t',target,'#{pane_current_command}').strip() in ['bash','zsh','sh']:return
  time.sleep(.1)
 raise AssertionError('Grok did not exit')
def brief(id):
 d=H/'data'/id;d.mkdir(parents=True,exist_ok=True)
 (d/'brief.md').write_text("# Task\n## Captain's intent\nDisposable quota startup probe.\n## Firstmate spec\nDo not run tools or change files. If authenticated, answer QUOTA_LAB_READY then wait.\n")
def metadata(id):return (H/'state'/(id+'.meta')).read_text()
def set_snapshot(mode):
 p=json.load(open(ROOT/'tests/fixtures/quota-axi-healthy.json'))
 now=datetime.datetime.now(datetime.timezone.utc);p['generatedAt']=now.isoformat().replace('+00:00','Z')
 if mode=='long':
  for x in p['providers']:
   if x['provider']=='grok':
    for r in x['quotaSemantics']['effectiveAvailability']:
     r['runway']={'status':'projected_exhaustion','usableRunwaySeconds':14500,'projectedExhaustedAt':(now+datetime.timedelta(seconds=14500)).isoformat().replace('+00:00','Z'),'projectionConfidence':'early'}
     r['effectivePercentRemaining']=4
 f=L/(mode+'.json');f.write_text(json.dumps(p));E['FM_QUOTA_SNAPSHOT_FILE']=str(f)
profiles={'default':[{'harness':'grok','model':'grok-4.7'},{'harness':'codex','model':'gpt-6.1-sol'},{'harness':'claude','model':'sonnet'}]}
(H/'config/crew-dispatch.json').write_text(json.dumps(profiles))
# Persisted public task metadata is the independent override-record oracle.
if '--continue' not in sys.argv:
 m=metadata('override');assert 'quota_override=live validation disposable launch\n' in m
 assert 'quota_override_evidence=refuse: provider grok' in m
 (EV/'live-override-meta.txt').write_text(m)
 log.write('Initial override metadata:\n'+m)
 stop('override');set_snapshot('healthy')
 run('healthy control relaunch clears previous override',['bin/fm-control.sh','override','relaunch','--harness','grok','--model','grok-4.7','--note','healthy relaunch without override'],contains=['relaunched override'])
 m=metadata('override');assert 'quota_override=' not in m and 'quota_override_evidence=' not in m
 log.write('Healthy relaunch metadata:\n'+m)
# Through reset, long runway, unavailable reading, and implicit exhausted
# recovery must reach a real worker process, rather than a mocked launch log.
stop('override');set_snapshot('long')
run('four hour runway direct relaunch allowed',['bin/fm-spawn.sh','override','--relaunch','--harness','grok','--model','grok-4.7'],contains=['spawned override harness=grok'])
stop('override');E['FM_QUOTA_SNAPSHOT_FILE']=str(L/'missing-snapshot.json')
out=run('missing snapshot reports one notice then launches',['bin/fm-control.sh','override','relaunch','--harness','grok','--note','unknown quota'],contains=['notice: fm-control launches grok without the quota check:','relaunched override'])
assert out.count('without the quota check:')==1
stop('override');E['FM_QUOTA_SNAPSHOT_FILE']=str(L/'exhausted.json')
run('implicit exhausted relaunch stays ungated',['bin/fm-control.sh','override','relaunch','--note','implicit recovery'],contains=['relaunched override'])
assert 'quota_override=' not in metadata('override')
stop('override')
# Quota override flags, reasons, evidence and diagnostics cross both children.
for id in ['batch-override-a','batch-override-b']:brief(id)
out=run('explicit batch override reaches both real launches',['bin/fm-spawn.sh','batch-override-a='+str(L/'project'),'batch-override-b='+str(L/'project'),'--scout','--harness','grok','--model','grok-4.7','--quota-override','batch live reason with spaces'],contains=['spawned batch-override-a','spawned batch-override-b'])
assert out.count('notice: fm-spawn quota check refuses grok')==2
for id in ['batch-override-a','batch-override-b']:
 m=metadata(id);assert 'quota_override=batch live reason with spaces\n' in m
 assert 'quota_override_evidence=refuse: provider grok' in m
 log.write(id+' metadata:\n'+m);stop(id)
log.write('\nAll live startup and metadata assertions passed. No sign-in approved and no inference claimed.\n');log.close()
