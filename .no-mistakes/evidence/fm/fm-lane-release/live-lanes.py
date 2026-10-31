import os, pathlib, subprocess as sp, json, time, shlex, shutil, sys
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M67W332R62ZJZSW3A4W2RCSJ'); LAB=E/'lab'; W=ROOT/'.lane-live'; S=LAB/'state'; D=LAB/'data'; C=LAB/'config'
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
 env.pop(k,None)
env.update(FM_HOME=str(LAB),TMUX_TMPDIR=str(LAB/'tmux'),CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false',CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF='1',CLAUDE_CODE_DISABLE_AGENT_VIEW='1')
log=open(E/'live-lanes.log','w',buffering=1)
def run(args,check=True,extra=None):
 e=env.copy();e.update(extra or {})
 p=sp.run([str(a) for a in args],env=e,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=90)
 log.write('$ '+shlex.join([str(a) for a in args])+'\n'+p.stdout+f'[exit={p.returncode}]\n')
 if check and p.returncode: raise RuntimeError(f'{args}: exit {p.returncode}: {p.stdout}')
 return p

def tm(*args):return run(['tmux','-L','fm-lab',*args])
if not LAB.exists():
 run([ROOT/'bin/fm-lab-home.sh','create',LAB]);(LAB/'tmux').mkdir()
 tm('new-session','-d','-s','primary','-x','120','-y','40','-c',str(ROOT),'bash')
env['TMUX']=tm('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
def lr(*args,check=True,now=None):return run([ROOT/'bin/fm-lane-release.sh',*args],check,{'FM_LANE_RELEASE_NOW':str(now)} if now else None)
def snap(label,target='primary:fm-sc'):
 p=tm('capture-pane','-p','-t',target);(E/(label+'.txt')).write_text(p.stdout);return p.stdout

def wait(fn,seconds=45):
 until=time.monotonic()+seconds
 while time.monotonic()<until:
  if fn():return
  time.sleep(.4)
 raise RuntimeError('timeout waiting for live product')
def assert_(ok,what):
 if not ok:raise AssertionError(what)
 log.write('OBSERVED: '+what+'\n')
def sweep(n):return lr('sweep',now=n)
def audit(n):return lr('--audit',check=False,now=n)
def counters():return (S/'lane-release.counters').read_text() if (S/'lane-release.counters').exists() else ''
def alive(id='sc'):return lr('read-evidence','agent',S/(id+'.meta'),id).stdout.strip()=='alive'
now=int(time.time()); anchor=now+3; gen=f's{now-10}.1.1'; bg=None
try:
 W.mkdir(exist_ok=True); wt=W/'wt';wt.mkdir(exist_ok=True)
 (wt/'keep.txt').write_text('unique uncommitted fixture content\n')
 (D/'sc').mkdir(exist_ok=True);(D/'sc/report.md').write_text('# Completed disposable scout\nNo pending decisions.\n')
 (S/'sc.meta').write_text(f'window=primary:fm-sc\nendpoint_task_id=sc\nworktree={wt}\nproject={wt}\nharness=claude\nkind=scout\nspawn_gen={gen}\nbackend=tmux\n')
 (S/'sc.status').write_text('')
 run([ROOT/'bin/fm-tasks-axi.sh','add','sc','Disposable scout'])
 run([ROOT/'bin/fm-captain-hold.sh','complete','sc','--none'])
 busygen=run([ROOT/'bin/fm-busy-event.sh','arm',S,'sc']).stdout.strip()
 hooks={}
 for event,state,ev in [('UserPromptSubmit','busy','user-prompt-submit'),('Stop','idle','stop'),('SessionEnd','idle','session-end')]:
  cmd=shlex.join([str(ROOT/'bin/fm-busy-event.sh'),'apply',str(S),'sc',state,'--gen',busygen,'--source','claude-hook','--event',ev])
  if event=='UserPromptSubmit':cmd+=' --prompt-stdin'
  hooks[event]=[{'hooks':[{'type':'command','command':cmd}]}]
 settings=W/'settings.json';settings.write_text(json.dumps({'hooks':hooks,'feedbackDrafts':'off'}))
 launch=['claude','--permission-mode','auto','--model','haiku','--setting-sources','','--settings',str(settings),'--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--tools','','--system-prompt','Reply with the exact requested word. Do not read or change files.']
 tm('new-window','-d','-t','primary:','-n','fm-sc','-c',str(wt),'bash')
 tm('send-keys','-t','primary:fm-sc','-l',shlex.join(launch));tm('send-keys','-t','primary:fm-sc','Enter')
 wait(lambda:'❯' in tm('capture-pane','-p','-t','primary:fm-sc').stdout)
 snap('scout-startup')
 tm('send-keys','-t','primary:fm-sc','-l','Reply only READY');tm('send-keys','-t','primary:fm-sc','Enter')
 wait(lambda:(S/'sc.busy-state').exists() and 'event=stop ' in (S/'sc.busy-state').read_text(),60)
 snap('scout-completed-turn');assert_(alive(),'real Claude is alive after its hooked turn')
 anchor=int(time.time())+1
 (S/'sc.status').write_text(f'done [at={anchor}]: scout report complete\n')
 (E/'busy-after-turn.txt').write_text((S/'sc.busy-state').read_text())
 # Default off and invalid settings must never release an eligible live worker.
 sweep(anchor+400);sweep(anchor+800);assert_(not (S/'sc.released').exists() and alive(),'absent setting leaves live scout holding its seat')
 for name,value in [('empty',''),('split','o\nn\n')]:
  (C/'lane-release').write_text(value);p=sweep(anchor+400);q=sweep(anchor+800)
  assert_(len(p.stdout.splitlines())==1 and not q.stdout and alive(),name+' invalid configuration reports one line exactly once and keeps worker alive')
 (C/'lane-release').write_text('on\n')
 # Safety decisions and evidence uncertainty, all through real sweep and audit.
 (S/'sc.status').write_text(f'needs-decision [at={anchor-1}] [key=choice]: pending choice\ndone [at={anchor}]: report complete\n')
 sweep(anchor+400);sweep(anchor+800);assert_(not (S/'sc.released').exists() and alive(),'later done does not erase the unresolved question')
 (S/'sc.status').write_text(f'done [at={anchor}]: report complete\n')
 reg=S/'procevent';reg.mkdir();reg.chmod(0)
 try:
  sweep(anchor+400);p=audit(anchor+2200)
  assert_(p.returncode==2 and 'board-unreadable' in p.stdout and alive(),'unreadable board directory is unknown and retains the live worker')
 finally:reg.chmod(0o755)
 src=reg/'board.source';src.write_text('owner_task=sc\n');src.chmod(0)
 try:
  sweep(anchor+400);p=audit(anchor+2200)
  assert_(p.returncode==2 and 'board-unreadable' in p.stdout and alive(),'unreadable board source is unknown and retains the live worker')
 finally:src.chmod(0o644)
 sweep(anchor+400);assert_(not (S/'sc.release-candidate').exists() and alive(),'registered pending board prevents scout release');src.unlink();reg.rmdir()
 (D/'sc/ship-instructions.md').write_text('promotion pending\n');sweep(anchor+400)
 assert_(not (S/'sc.release-candidate').exists() and alive(),'in-place promotion prevents scout release');(D/'sc/ship-instructions.md').unlink()
 # Real composer text is preserved; no lifecycle submission may happen.
 tm('send-keys','-t','primary:fm-sc','-l','UNSENT important continuation')
 wait(lambda:lr('read-evidence','composer',S/'sc.meta','sc').stdout.strip()=='pending')
 sweep(anchor+400);sweep(anchor+800);snap('draft-retained')
 assert_(not (S/'sc.released').exists() and 'UNSENT important continuation' in snap('draft-still-retained') and alive(),'unsent composer text survives both release sweeps')
 tm('send-keys','-t','primary:fm-sc','C-u')
 wait(lambda:lr('read-evidence','composer',S/'sc.meta','sc').stdout.strip()=='empty')
 # Audit mode observes twice and logs once while the actual interface stays alive.
 (C/'lane-release').write_text('audit\n');sweep(anchor+400);sweep(anchor+800);sweep(anchor+900)
 assert_(alive() and not (S/'sc.released').exists() and (D/'lane-release.ledger').read_text().count('WOULD_RELEASE')==1,'audit mode logs one would-release event and never stops the live scout')
 p=audit(anchor+2200);assert_(p.returncode==1 and 'holder sc' in p.stdout,'read-only audit detects a finished live holder older than thirty minutes')
 # Deliberately leave a real process in the disposable task copy.
 bg=sp.Popen(['sleep','600'],cwd=wt,env=env)
 (C/'lane-release').write_text('on\n');lr('arm')
 # Fresh debounce because audit's candidate is already mature: remove fixture observation only.
 (S/'sc.release-candidate').unlink(missing_ok=True)
 sweep(anchor+1000);sweep(anchor+1299)
 assert_(not (S/'sc.released').exists() and alive(),'a second sighting before 300 seconds does not release')
 run([S/'lane-release.check.sh'],extra={'FM_LANE_RELEASE_NOW':str(anchor+1300)})
 wait(lambda:(S/'sc.release.log').exists(),75)
 (E/'scout-release-control.txt').write_text((S/'sc.release.log').read_text())
 assert_('rc=0' in (S/'sc.release.log').read_text() and not alive(),'registered check stops the real idle scout through fm-control exit')
 sweep(anchor+1310);p=sweep(anchor+1320);q=sweep(anchor+1330)
 assert_('RELEASE_INCOMPLETE' in p.stdout and not q.stdout and 'result=release-incomplete' in (S/'sc.released').read_text(),'residual real process retains the seat and emits only one incomplete wake')
 bg.terminate();bg.wait();bg=None
 sweep(anchor+1400)
 assert_('result=released' in (S/'sc.released').read_text(),'seat becomes released after the last real task process stops')
 assert_((wt/'keep.txt').read_text()=='unique uncommitted fixture content\n','release preserves the task copy and uncommitted content')
 for f in ['sc.released','sc.release.log','lane-release.counters']:
  (E/f).write_text((S/f).read_text())
 (E/'lane-release.ledger').write_text((D/'lane-release.ledger').read_text())
 # Public fleet listing must identify deliberate release.
 p=run([ROOT/'bin/fm-fleet-snapshot.sh','--json']);(E/'fleet-snapshot.json').write_text(p.stdout)
 obj=json.loads(p.stdout);row=next(x for x in obj['tasks'] if x['id']=='sc')
 assert_(row['lane_release']['result']=='released','fleet snapshot distinguishes intentional release from a dead worker')
 log.write('ALL LIVE SCENARIOS PASSED\n')
except Exception as exc:
 log.write('FAILED: '+repr(exc)+'\n')
 try:snap('failure')
 except Exception:pass
 raise
finally:
 if bg is not None:bg.terminate();bg.wait()
 tm('kill-server')
 shutil.rmtree(W,ignore_errors=True);shutil.rmtree(LAB,ignore_errors=True)
 log.write('CLEANUP: private tmux server stopped and disposable home/copy removed\n');log.close()
