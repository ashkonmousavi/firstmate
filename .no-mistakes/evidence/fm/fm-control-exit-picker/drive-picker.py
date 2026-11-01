import os,subprocess,pathlib,time,json,sys,html
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.l'; EV=pathlib.Path('~/.no-mistakes/evidence/01M6B62AEYX0JQH5T01JDP149M')
ENV=os.environ.copy()
for k in list(ENV):
 if k.startswith(('FM_','CLAUDE_CODE_')) or k in ('CLAUDECODE','NO_MISTAKES_GATE','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_CONFIG'): ENV.pop(k)
ENV.update(TMUX_TMPDIR=str(LAB/'t'),FM_HOME=str(LAB),CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF='1',CLAUDE_CODE_DISABLE_AGENT_VIEW='1',CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false')
def tm(*args):
 return subprocess.run(['tmux','-L','fm-lab',*args],env=ENV,capture_output=True,text=True,check=True).stdout
def shot(): return tm('capture-pane','-p','-t','primary')
def save(name):
 s=shot();(EV/(name+'.txt')).write_text(s)
 (EV/(name+'.html')).write_text('<!doctype html><meta charset="utf-8"><title>'+html.escape(name)+'</title><body style="background:#17191d;color:#eee"><pre style="font:14px/1.35 monospace;white-space:pre">'+html.escape(s)+'</pre></body>')
 return s
def send(s): tm('send-keys','-t','primary','-l',s);time.sleep(1);tm('send-keys','-t','primary','Enter')
def wait(predicate,limit=100):
 start=time.monotonic()
 while time.monotonic()-start<limit:
  s=shot()
  if predicate(s):return s
  time.sleep(.5)
 raise RuntimeError('timed out: '+save('timeout'))
def control(name,*args,extra=None):
 env=ENV.copy();env.update(extra or {})
 env['TMUX']=tm('display-message','-p','#{socket_path},#{pid},0').strip()
 p=subprocess.run([str(ROOT/'bin/fm-control.sh'),'test','exit',*args],env=env,capture_output=True,text=True,timeout=100)
 (EV/(name+'.log')).write_text('$ FM_HOME=<lab> bin/fm-control.sh test exit '+' '.join(args)+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
 print(name,p.returncode,p.stdout,p.stderr,flush=True)
 return p
if __name__=='__main__':
 if sys.argv[1]=='background':
  send("Use only the Bash tool with run_in_background=true to run this exact command: sh -c 'echo $$ > bg.pid; exec sleep 900'. Do not inspect any other files. Reply with done.")
  wait(lambda s:'still running' in s and (LAB/'project/bg.pid').exists(),150)
  wait(lambda s:'done' in s.lower() and 'esc to interrupt' not in s.lower(),100)
  print(save('background-running'))
def restart():
 tm('kill-server')
 tm('new-session','-d','-s','primary','-n','fm-test','-x','160','-y','44','-c',str(LAB/'project'),"claude --model haiku --setting-sources project,local --allowedTools Bash; exec bash --noprofile --norc")
 tm('set-window-option','-t','primary:fm-test','automatic-rename','off')
 wait(lambda s:'❯' in s and 'Haiku' in s,30)
 time.sleep(2)
 (LAB/'project/bg.pid').unlink(missing_ok=True)
 send("Use only the Bash tool with run_in_background=true to run this exact command: sh -c 'echo $$ > bg.pid; exec sleep 900'. Do not inspect any other files. Reply with done.")
 wait(lambda s:'still running' in s and (LAB/'project/bg.pid').exists(),150)
 wait(lambda s:'done' in s.lower() and 'esc to interrupt' not in s.lower(),100)
 return int((LAB/'project/bg.pid').read_text())
def dead(pid):
 p=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
 return p.returncode!=0 or 'Z' in p.stdout
