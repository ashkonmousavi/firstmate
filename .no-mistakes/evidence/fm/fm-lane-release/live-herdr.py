import os,pathlib,subprocess as sp,json,time,shlex,shutil
ROOT=pathlib.Path.cwd();E=pathlib.Path('~/.no-mistakes/evidence/01M67W332R62ZJZSW3A4W2RCSJ');LAB=E/'herdr-home';W=ROOT/'.herdr-live';SESSION='fm-lab-lane-proof-01M67'
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_ENV','HERDR_PANE_ID','HERDR_TAB_ID','HERDR_WORKSPACE_ID','HERDR_SOCKET_PATH','TMUX']:
 env.pop(k,None)
env.update(FM_HOME=str(LAB),HERDR_SESSION=SESSION,FM_HERDR_LAB_STATE_DIR=str(E/'herdr-lab-state'),CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false',CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF='1',CLAUDE_CODE_DISABLE_AGENT_VIEW='1')
log=open(E/'live-herdr.log','w',buffering=1)
def run(args,check=True,extra=None):
 e=env.copy();e.update(extra or {});p=sp.run([str(a) for a in args],env=e,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=90)
 log.write('$ '+shlex.join([str(a) for a in args])+'\n'+p.stdout+f'\n[exit={p.returncode}]\n')
 if check and p.returncode:raise RuntimeError(p.stdout)
 return p
helper=ROOT/'bin/fm-herdr-lab.sh'
def hc(*args):return run([helper,'run',SESSION,*args])
def lr(*args,now=None,check=True):return run([ROOT/'bin/fm-lane-release.sh',*args],check,{'FM_LANE_RELEASE_NOW':str(now)} if now else None)
def wait(fn,limit=60):
 end=time.monotonic()+limit
 while time.monotonic()<end:
  if fn():return
  time.sleep(.5)
 raise RuntimeError('live Herdr timeout')
def good(cond,what):
 if not cond:raise AssertionError(what)
 log.write('OBSERVED: '+what+'\n')
def find(obj,key):
 if isinstance(obj,dict):
  if key in obj:return obj[key]
  for v in obj.values():
   r=find(v,key)
   if r:return r
 if isinstance(obj,list):
  for v in obj:
   r=find(v,key)
   if r:return r
 return None
pane=None
try:
 run([ROOT/'bin/fm-lab-home.sh','create',LAB]);S=LAB/'state';D=LAB/'data';C=LAB/'config';W.mkdir();wt=W/'wt';wt.mkdir()
 (wt/'keep.txt').write_text('herdr uncommitted fixture\n');(D/'hs').mkdir();(D/'hs/report.md').write_text('# Complete disposable scout\n')
 run([helper,'provision',SESSION]);p=hc('status','--json');good(json.loads(p.stdout)['server']['running'],'isolated named Herdr server is running')
 p=hc('workspace','create','--cwd',str(wt),'--label','Lane release lab','--env',f'FM_HOME={LAB}');obj=json.loads(p.stdout);(E/'herdr-workspace.json').write_text(p.stdout)
 pane=find(obj,'pane_id');good(bool(pane),'Herdr created an owned real terminal pane')
 now=int(time.time());gen=f's{now-10}.1.1';meta=S/'hs.meta'
 meta.write_text(f'window={SESSION}:{pane}\nendpoint_task_id=hs\nworktree={wt}\nproject={wt}\nharness=claude\nkind=scout\nspawn_gen={gen}\nbackend=herdr\nherdr_session={SESSION}\nherdr_pane_id={pane}\nherdr_workspace_id={find(obj,"workspace_id")}\nherdr_tab_id={find(obj,"tab_id")}\n')
 run([ROOT/'bin/fm-tasks-axi.sh','add','hs','Disposable Herdr scout']);run([ROOT/'bin/fm-captain-hold.sh','complete','hs','--none'])
 busygen=run([ROOT/'bin/fm-busy-event.sh','arm',S,'hs']).stdout.strip();hooks={}
 for event,state,ev in [('UserPromptSubmit','busy','user-prompt-submit'),('Stop','idle','stop'),('SessionEnd','idle','session-end')]:
  cmd=shlex.join([str(ROOT/'bin/fm-busy-event.sh'),'apply',str(S),'hs',state,'--gen',busygen,'--source','claude-hook','--event',ev])
  if event=='UserPromptSubmit':cmd+=' --prompt-stdin'
  hooks[event]=[{'hooks':[{'type':'command','command':cmd}]}]
 settings=W/'settings.json';settings.write_text(json.dumps({'hooks':hooks,'feedbackDrafts':'off'}))
 launch=['env','CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false','CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF=1','CLAUDE_CODE_DISABLE_AGENT_VIEW=1',f'FM_HOME={LAB}','claude','--permission-mode','auto','--model','haiku','--setting-sources','','--settings',str(settings),'--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--tools','','--system-prompt','Reply only with the requested word. Do not read or change files.']
 hc('pane','run',pane,shlex.join(launch))
 wait(lambda:'❯' in hc('pane','read',pane,'--source','visible','--format','text').stdout)
 hc('pane','run',pane,'Reply only READY')
 wait(lambda:'event=stop ' in (S/'hs.busy-state').read_text())
 hc('pane','report-agent',pane,'--source','firstmate-lab','--agent','claude','--state','idle')
 p=hc('pane','read',pane,'--source','visible','--format','text');(E/'herdr-claude-ready.txt').write_text(p.stdout)
 good(lr('read-evidence','agent',meta,'hs').stdout.strip()=='alive','Herdr backend attributes the real Claude process as alive')
 good(lr('read-evidence','composer',meta,'hs').stdout.strip()=='empty','Herdr reads the real idle Claude composer as empty')
 anchor=int(time.time())+1;(S/'hs.status').write_text(f'done [at={anchor}]: report complete\n');(C/'lane-release').write_text('on\n')
 lr('sweep',now=anchor+400);good((S/'hs.release-candidate').exists(),'Herdr worker enters release debounce')
 hc('pane','send-text',pane,'UNSENT Herdr continuation');lr('sweep',now=anchor+800)
 good(not (S/'hs.released').exists() and lr('read-evidence','agent',meta,'hs').stdout.strip()=='alive','pending text prevents automatic release on real Herdr')
 hc('pane','send-keys',pane,'ctrl+u');wait(lambda:lr('read-evidence','composer',meta,'hs').stdout.strip()=='empty')
 lr('sweep',now=anchor+900);lr('sweep',now=anchor+1200)
 wait(lambda:(S/'hs.release.log').exists(),75);(E/'herdr-release-control.txt').write_text((S/'hs.release.log').read_text())
 good('rc=0' in (S/'hs.release.log').read_text(),'guarded Herdr transport exits real idle Claude successfully')
 lr('sweep',now=anchor+1210);good('result=released' in (S/'hs.released').read_text(),'Herdr release verifies the real seat is free')
 good((wt/'keep.txt').read_text()=='herdr uncommitted fixture\n','Herdr release preserves uncommitted copy contents')
 (E/'herdr-release.ledger').write_text((D/'lane-release.ledger').read_text());log.write('ALL LIVE HERDR SCENARIOS PASSED\n')
except Exception as exc:
 log.write('FAILED: '+repr(exc)+'\n')
 if pane:
  try:(E/'herdr-failure.txt').write_text(hc('pane','read',pane,'--source','visible','--format','text').stdout)
  except Exception:pass
 raise
finally:
 p=run([helper,'teardown',SESSION],False);good(p.returncode==0,'Herdr lab teardown completed with unchanged default-session tripwire')
 shutil.rmtree(W,ignore_errors=True);shutil.rmtree(LAB,ignore_errors=True);log.write('CLEANUP: isolated Herdr session, home and task copy removed\n');log.close()
