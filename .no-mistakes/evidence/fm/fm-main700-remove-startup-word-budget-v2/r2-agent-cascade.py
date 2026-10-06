from pathlib import Path
import os,subprocess,shutil,shlex,time
R=Path.cwd();E=Path('/home/tegris/.no-mistakes/evidence/01M49EBAM259QST2W72QEEJVGG');p=E/'.ap';s=E/'.as';ev=os.environ.copy();tm=None
for k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TASK_ID','TMUX','TMUX_PANE','HERDR_ENV','HERDR_PANE_ID','CLAUDECODE'):ev.pop(k,None)
try:
 for h in (p,s):
  assert not h.exists();subprocess.run(['bin/fm-lab-home.sh','create',str(h)],env=ev,check=True,capture_output=True)
 (p/'tmux').mkdir();(s/'bin').mkdir();shutil.copyfile(R/'AGENTS.md',s/'AGENTS.md');(s/'.fm-secondmate-home').write_text('agent\n');(s/'config/supervision-host-off').touch();(s/'config/startup-memory-budget').write_text('invalid\n')
 (p/'data/secondmates.md').write_text('- agent - lab (home: '+str(s)+'; scope: testing; projects: alpha; added 2026-10-06)\n')
 (p/'state/agent.meta').write_text('kind=secondmate\nhome='+str(s)+'\nbackend=tmux\nbackend_target=primary:fm-agent\nwindow=primary:fm-agent\nharness=claude\n')
 tm=dict(ev,FM_HOME=str(s),TMUX_TMPDIR=str(p/'tmux'),CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false')
 args=['claude','-p','--permission-mode','auto','--no-session-persistence','--setting-sources','project','--strict-mcp-config','--disallowedTools','Agent,Task,TaskCreate,TaskUpdate,TaskList,TaskGet','--verbose','--output-format','stream-json','This is a disposable lab secondmate. Reply READY only. No tools, no fleet operations, no writes.']
 cli=shlex.join(args)+' > '+shlex.quote(str(E/'r2-agent-native.jsonl'))+' 2> '+shlex.quote(str(E/'r2-agent-native.stderr'))
 subprocess.run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-n','fm-agent','-x','120','-y','40','-c',str(R),'-e','FM_HOME='+str(s),cli],env=tm,check=True)
 sock=subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path}'],env=tm,text=True).strip()
 primaryenv=dict(tm,FM_HOME=str(p),TMUX=sock+',0,0')
 out=''
 for attempt in range(30):
  r=subprocess.run(['bin/fm-stow-cascade.sh'],env=primaryenv,text=True,capture_output=True,timeout=30)
  out=r.stdout+r.stderr
  if 'transport=agent' in out:break
  time.sleep(0.3)
 (E/'r2-agent-cascade.txt').write_text('$ FM_HOME=<lab-primary> bin/fm-stow-cascade.sh\n'+out+'\nexit='+str(r.returncode)+'\n')
 assert r.returncode==0 and 'transport=agent' in out and 'budget_report=' not in out,out
 assert (s/'config/startup-memory-budget').read_text()=='invalid\n'
 comm=subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','-t','primary:fm-agent','#{pane_current_command}'],env=tm,text=True)
 (E/'r2-agent-runtime.txt').write_text('Private 120x40 tmux endpoint foreground command: '+comm)
 deadline=time.monotonic()+180
 while time.monotonic()<deadline:
  if subprocess.run(['tmux','-L','fm-lab','has-session','-t','primary'],env=tm,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode:break
  time.sleep(2)
 else:raise AssertionError('Agent harness did not exit within 180s')
 print('Live Claude secondmate cascade: agent transport, no budget report, legacy file preserved')
finally:
 if tm:subprocess.run(['tmux','-L','fm-lab','kill-server'],env=tm,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 for h in (p,s):
  if h.exists():shutil.rmtree(h)
