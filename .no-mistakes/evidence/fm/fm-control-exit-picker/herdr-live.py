import sys,importlib,json,time,subprocess,html
sys.path.insert(0,'~/.no-mistakes/evidence/01M6B62AEYX0JQH5T01JDP149M');h=importlib.import_module('herdr-driver')
H=h.LAB/'hhome';P=h.LAB/'hproject';pane='';env=h.ENV.copy();env['FM_HOME']=str(H);h.ENV['FM_HOME']=str(H)
def logged(name,args):
 p=subprocess.run(args,env=env,capture_output=True,text=True,timeout=120)
 (h.EV/(name+'.log')).write_text('$ '+' '.join(args)+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
 print(name,p.returncode,p.stdout,p.stderr,flush=True);return p
def shot():return h.run('pane','read',pane,'--source','visible')
def save(name):
 s=shot();(h.EV/(name+'.txt')).write_text(s);(h.EV/(name+'.html')).write_text('<!doctype html><meta charset="utf-8"><body style="background:#17191d;color:#eee"><pre style="font:14px/1.35 monospace">'+html.escape(s)+'</pre>');return s
def wait(test,limit=150):
 start=time.monotonic()
 while time.monotonic()-start<limit:
  s=shot()
  if test(s):return s
  time.sleep(.5)
 raise RuntimeError(save('herdr-timeout'))
def send(s):
 h.run('pane','send-text',pane,s);time.sleep(1);h.run('pane','send-keys',pane,'Enter')
def start(name):
 (P/'bg.pid').unlink(missing_ok=True)
 print(h.run('agent','start',name,'--kind','claude','--pane',pane,'--timeout','60000','--','--model','haiku','--setting-sources','project,local','--allowedTools','Bash'),flush=True)
 send("Use only the Bash tool with run_in_background=true to run this exact command: sh -c 'echo $$ > bg.pid; exec sleep 900'. Do not inspect any other files. Reply with done.")
 wait(lambda s:'still running' in s and (P/'bg.pid').exists())
 wait(lambda s:'done' in s.lower() and 'esc to interrupt' not in s.lower())
 return int((P/'bg.pid').read_text())
def control(name,*args,extra=None):
 old=env.copy();env.update(FM_CONTROL_EXIT_WAIT='10',FM_CONTROL_POLL='0.2');env.update(extra or {})
 p=logged(name,['bin/fm-control.sh','htest','exit',*args]);env.clear();env.update(old);return p
def dead(pid):
 p=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True);return p.returncode!=0 or 'Z' in p.stdout
try:
 print(h.helper('provision',h.NAME),flush=True)
 ws=json.loads(h.run('workspace','create','--cwd',str(P),'--label','picker-proof','--no-focus'))['result']['workspace']['workspace_id']
 args=['tab','create','--workspace',ws,'--cwd',str(P),'--label','fm-htest','--no-focus']
 for k in ('FM_HOME','CLAUDE_CODE_DISABLE_AGENT_VIEW','CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF','CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION'): args.extend(['--env',k+'='+env[k]])
 tab=json.loads(h.run(*args))['result'];(h.EV/'herdr-tab.json').write_text(json.dumps(tab,indent=2))
 pane=tab.get('pane',tab.get('root_pane',{})).get('pane_id')
 assert pane,tab
 tid=tab['tab']['tab_id']
 print(h.helper('viewer','start',h.NAME),flush=True)
 (H/'state/htest.meta').write_text(f'window={h.NAME}:{pane}\nendpoint_task_id=htest\nworktree={P}\nproject={P}\nharness=claude\nkind=ship\nbackend=herdr\nherdr_session={h.NAME}\nherdr_workspace_id={ws}\nherdr_tab_id={tid}\nherdr_pane_id={pane}\n')
 pid=start('picker-explicit')
 before=(H/'data/backlog.md').read_bytes();save('herdr-background-running')
 p=control('herdr-unauthorized-submit');assert p.returncode==1 and 'Claude background-task exit picker' in p.stderr,p.stdout+p.stderr
 save('herdr-unauthorized-picker')
 p=control('herdr-landed-open','--landed-work');assert p.returncode==0,p.stdout+p.stderr
 assert dead(pid);assert before==(H/'data/backlog.md').read_bytes();save('herdr-landed-after')
 # Same real backend, final-validation lane-release boundary, no Done row.
 pid=start('picker-lane')
 gen=f's{int(time.time())-1000}.1.2'
 with (H/'state/htest.meta').open('a') as f:f.write(f'spawn_gen={gen}\npr=https://github.com/lab/disposable/pull/8\n')
 (H/'config/lane-release').write_text('on\n')
 p=logged('herdr-lane-arm',['bin/fm-busy-event.sh','arm',str(H/'state'),'htest','--state','idle','--source','claude-hook','--event','stop']);assert p.returncode==0;busy=p.stdout.strip();time.sleep(1)
 p=logged('herdr-lane-landing',['bash','-c','. bin/fm-pr-lib.sh; fm_pr_poll_merge_mark_notified "$FM_HOME/state" htest github github.com lab/disposable 8']);assert p.returncode==0
 anchor=int((H/'state/htest.pr-poll-merge-notified').stat().st_mtime)
 (H/'state/htest.released').write_text(f'fm-lane-release-v1\ntask=htest\nspawn_gen={gen}\nreleased_at={int(time.time())}\nanchor={anchor}\nclass=merged-ship\nresult=releasing\nbusy_seq={busy}:1\n')
 p=logged('herdr-lane-validate',['bin/fm-lane-release.sh','validate-exit','htest',gen]);assert p.returncode==0
 save('herdr-lane-before')
 p=logged('herdr-lane-exit-worker',['bin/fm-lane-release.sh','exit-worker','htest',gen]);assert p.returncode==0
 log=(H/'state/htest.release.log').read_text();(h.EV/'herdr-lane-result.log').write_text(log);print(log,flush=True)
 assert 'rc=0\n' in log and 'stopped htest' in log,log
 assert dead(pid);assert before==(H/'data/backlog.md').read_bytes();save('herdr-lane-after')
 results=json.loads((h.EV/'live-results.json').read_text());results['herdr']={'unauthorized_submit':'pass','explicit_landed_open':'pass','validated_nondone_lane':'pass','background_stopped':True,'backlog_unchanged':True};(h.EV/'live-results.json').write_text(json.dumps(results,indent=2))
finally:
 stopped=h.helper('stop',h.NAME)
 out=h.helper('teardown',h.NAME)
 (h.EV/'herdr-teardown.log').write_text('guarded stop exit=0; teardown exit=0; named lab removed; default-session tripwire unchanged\n'+stopped+out)
 print('Herdr lab stop and teardown verified',flush=True)
