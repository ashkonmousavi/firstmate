"""Drive real Firstmate CLI commands against a marked disposable .q/h home.
Oracle: accepted quota contract (exhausted or <=3h refuses, configured highest
eligible spendPriority wins, explicit override persists its reason). No CLI,
terminal, treehouse, or Firstmate implementation is replaced by this driver.
Run from the gate worktree after minting .q/h with bin/fm-lab-home.sh.
"""
import os,subprocess,json,pathlib,datetime,copy,hashlib
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.q'; H=LAB/'h'; EV=pathlib.Path(__file__).parent
E=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_CONTROL_PARENT','FM_TASK_ID','FM_TEST_SEAM']:
 E.pop(k,None)
E.update(FM_HOME=str(H),HOME=str(LAB/'u'),TMPDIR=str(LAB/'tmp'),GROK_HOME=str(LAB/'u/.grok'),TMUX_TMPDIR=str(LAB/'t'),TREEHOUSE_ROOT=str(LAB/'pool'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',FM_QUOTA_SNAPSHOT_FILE=str(LAB/'exhausted.json'))
def tm(*a):
 return subprocess.check_output(['tmux','-L','fm-lab',*a],env=E,text=True)
E['TMUX']=tm('display-message','-p','-t','launcher','#{socket_path}')+',0,0'
E['TMUX']=E['TMUX'].replace('\n','')
log=open(EV/'live-quota-transcript.log','w',buffering=1)
def run(label,args,rc=0,contains=(),env=None):
 log.write('\n### '+label+'\n$ '+' '.join(args)+'\n')
 r=subprocess.run(args,env=env or E,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=120)
 log.write(r.stdout+'exit='+str(r.returncode)+'\n')
 assert r.returncode==rc,(label,r.returncode,r.stdout)
 for s in contains: assert s in r.stdout,(label,'missing',s,r.stdout)
 return r.stdout

def brief(id):
 p=H/'data'/id;p.mkdir(parents=True,exist_ok=True)
 (p/'brief.md').write_text("# Task\n## Captain's intent\nDisposable quota gate validation.\n## Firstmate spec\nDo not edit files or invoke tools. If authenticated, answer QUOTA_LAB_READY then wait.\n")
def rules(profiles):
 (H/'config/crew-dispatch.json').write_text(json.dumps({'default':profiles}))
def snapshot(name,mode='exhausted',seconds=0):
 p=json.load(open(ROOT/'tests/fixtures/quota-axi-healthy.json'))
 now=datetime.datetime.now(datetime.timezone.utc); p['generatedAt']=now.isoformat().replace('+00:00','Z')
 for x in p['providers']:
  for row in x['quotaSemantics']['effectiveAvailability']:
   row['selection']={'status':'known','spendPriority':9 if x['provider']=='codex' else 1}
   if x['provider']=='grok':
    row.update(effectivePercentRemaining=0 if mode=='exhausted' else 4)
    row['runway']=({'status':'exhausted_now','usableRunwaySeconds':0} if mode=='exhausted' else {'status':'projected_exhaustion','usableRunwaySeconds':seconds,'projectedExhaustedAt':(now+datetime.timedelta(seconds=seconds)).isoformat().replace('+00:00','Z'),'projectionConfidence':'early'})
 path=LAB/(name+'.json');path.write_text(json.dumps(p));E['FM_QUOTA_SNAPSHOT_FILE']=str(path)
 return p

profiles=[{'harness':'grok','model':'grok-4.7'},{'harness':'codex','model':'gpt-6.1-sol'},{'harness':'claude','model':'sonnet'}]
rules(profiles)
for mode,secs in [('exhausted',0),('short',10700),('short',600)]:
 snapshot(mode+str(secs),mode,secs)
 id='live-deny-'+mode+str(secs);brief(id)
 run('explicit spawn refuses '+mode+str(secs),['bin/fm-spawn.sh',id,str(LAB/'project'),'--scout','--harness','grok','--model','grok-4.7'],1,['refuses explicit harness grok','Best alternative: provider codex (spendPriority 9)'])
 assert not (H/'state'/(id+'.meta')).exists()
run('legacy positional refuses', ['bin/fm-spawn.sh','deny',str(LAB/'project'),'grok','--scout'],1,['refuses explicit harness grok'])
# The existing real Grok pane is still alive at its sign-in screen; refusal
# must leave both its process identity and durable record untouched.
snapshot('exhausted')
meta=H/'state/override.meta'; before=meta.read_bytes()
process_before=tm('list-panes','-t','launcher:fm-override','-F','#{pane_pid} #{pane_current_command}')
run('control refuses before stopping actual Grok',['bin/fm-control.sh','override','relaunch','--harness','grok','--model','grok-4.7','--note','must not stop'],1,['fm-control refuses explicit harness grok','Best alternative: provider codex (spendPriority 9)'])
assert before==meta.read_bytes()
assert process_before==tm('list-panes','-t','launcher:fm-override','-F','#{pane_pid} #{pane_current_command}')
log.write('Prior metadata byte-identical; actual Grok process identity unchanged: '+process_before)
# Every catalog adapter is evaluated using its declared family. This does not
# require invoking any adapter, and deliberately proves no native probing.
models={'claude':'sonnet','codex':'gpt-6.1-sol','opencode':'anthropic/claude-sonnet-4-5','pi':'zai/glm-5.3','pi-signed':'codex-native/gpt-6-astra','grok':'grok-4.7','kimi':'kimi-code/k3','cursor':'cursor-grok-4.5-high','omp':'openai-codex/gpt-6.1-sol','agy':'gemini-3.8-flash-low','gemini':'gemini-3.1-pro','muse':'muse-spark-1.2','rovo':'auto','devin':'fusion-claude-fable-5-1-high-sidekick-swe-2-medium','commandcode':'deepseek/deepseek-v4.1-flash','polytoken':'zai/glm-5.3-flash'}
p=snapshot('catalog');p['providers'].append({'provider':'blocked','quotaSemantics':{'status':'known','effectiveAvailability':[{'scope':'all_models','status':'known','effectivePercentRemaining':0,'runway':{'status':'exhausted_now'},'selection':{'status':'known','spendPriority':-10}}]}})
(LAB/'catalog.json').write_text(json.dumps(p))
for harness,model in models.items():
 alt='claude' if harness=='codex' else 'codex'
 rules([{'harness':harness,'model':model,'provider':'blocked'},{'harness':alt,'model':'healthy-alternative'}])
 for axis in ['caller','configured']:
  if harness=='polytoken' and axis=='configured':continue
  id='live-'+harness+'-'+axis;brief(id)
  flags=['--harness',harness]+(['--model',model] if axis=='caller' else [])
  run('catalog '+harness+'/'+axis+' spawn',['bin/fm-spawn.sh',id,str(LAB/'project'),'--scout',*flags],1,['provider blocked runway exhausted_now','--harness '+alt+' --model healthy-alternative'])
  # Polytoken's native effort validation precedes quota at control; its normal
  # catalog CLI is absent here, so other live adapters exercise this boundary.
  if harness!='polytoken':
   run('catalog '+harness+'/'+axis+' control',['bin/fm-control.sh','override','relaunch',*flags,'--note','catalog quota refusal'],1,['provider blocked runway exhausted_now','--harness '+alt+' --model healthy-alternative'])
   assert before==meta.read_bytes()
# Recommendations must discard a candidate excluded from the worker route.
rules([{'harness':'grok','model':'grok-4.7'},{'harness':'codex','model':'gpt-6.1-sol'},{'harness':'pi-signed','model':'codex-native/gpt-6-astra','provider':'codex'}])
(H/'config/crew-exclude-tools').write_text('hidden_tool\n');snapshot('exhausted')
run('unsupported best-ranked worker excluded',['bin/fm-spawn.sh','deny',str(LAB/'project'),'--scout','--harness','grok'],1,['--harness pi-signed --model codex-native/gpt-6-astra'])
(H/'config/crew-exclude-tools').unlink(); rules(profiles)
# An override is explicit-only, even when the home config chooses Grok.
(H/'config/crew-dispatch.json').unlink()
run('implicit launch rejects override',['bin/fm-spawn.sh','deny',str(LAB/'project'),'--scout','--quota-override','not explicit'],1,['applies only to an explicitly named adapter'])
rules(profiles)
# Adversarial batch: every child must independently refuse and report why.
for id in ['batch-deny-a','batch-deny-b']: brief(id)
out=run('batch refusal survives child delegation',['bin/fm-spawn.sh','batch-deny-a='+str(LAB/'project'),'batch-deny-b='+str(LAB/'project'),'--scout','--harness','grok'],1,['refuses explicit harness grok'])
assert out.count('refuses explicit harness grok')==2
log.write('\nLive refusal matrix complete; no implementation replacements or gate bypass used.\n')
log.close()
