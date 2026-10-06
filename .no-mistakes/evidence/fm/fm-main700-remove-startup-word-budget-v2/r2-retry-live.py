from pathlib import Path
import os,subprocess,shutil,shlex,json,re
R=Path.cwd(); E=Path('/home/tegris/.no-mistakes/evidence/01M49EBAM259QST2W72QEEJVGG')
log=(E/'r2-retry-live.log').open('w',buffering=1)
ev=os.environ.copy()
for k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TASK_ID','TMUX','TMUX_PANE','HERDR_ENV','HERDR_PANE_ID'):
 ev.pop(k,None)
p=E/'.rp'; s=E/'.rs'; tm=None

def run(args,env,name,allowed=(0,)):
 r=subprocess.run(args,cwd=R,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 (E/(name+'.txt')).write_text(r.stdout)
 log.write('$ '+shlex.join(args)+'\n'+r.stdout+'\nexit='+str(r.returncode)+'\n')
 assert r.returncode in allowed,(name,r.returncode)
 return r.stdout
try:
 for h in (p,s):
  assert not h.exists();run(['bin/fm-lab-home.sh','create',str(h)],ev,'r2-retry-create-'+h.name)
 (p/'tmux').mkdir();(s/'bin').mkdir();shutil.copyfile(R/'AGENTS.md',s/'AGENTS.md');(s/'.fm-secondmate-home').write_text('retry\n')
 run(['git','init','-q',str(s)],ev,'r2-retry-git-init')
 (s/'.gitignore').write_text('config/\nstate/\ndata/\n.fm-*\n')
 (s/'config/crew-harness').write_text('old\n');(p/'config/crew-harness').write_text('codex\n')
 (p/'state/retry.meta').write_text('kind=secondmate\nhome='+str(s)+'\nbackend=tmux\nbackend_target=primary:fm-retry\nwindow=primary:fm-retry\n')
 tm=dict(ev,FM_HOME=str(p),TMUX_TMPDIR=str(p/'tmux'))
 # A real tmux endpoint is enough for the durable inbox transport; no model
 # interpretation is asserted in this CLI protocol scenario.
 run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-n','fm-retry','-x','120','-y','40','-c',str(R),'-e','FM_HOME='+str(p),'bash'],tm,'r2-retry-tmux-launch')
 socket=run(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path}'],tm,'r2-retry-socket').strip()
 tm['TMUX']=socket+',0,0'
 fault=R/'.r2-fault-tools';assert not fault.exists();fault.mkdir()
 real_mv=shutil.which('mv');real_date=shutil.which('date')
 retry_dir=p/'state/.fm-inherited-config-reread-retry/retry'
 (fault/'mv').write_text('#!/usr/bin/env bash\ntarget=\nfor arg in "$@"; do target="$arg"; done\ncase "$target" in\n'+shlex.quote(str(retry_dir))+'/.fm-inherited-config-reread.*)\n case "$target" in *.exact) ;; *) exit 1 ;; esac ;;\nesac\nexec '+shlex.quote(real_mv)+' "$@"\n')
 (fault/'date').write_text('#!/usr/bin/env bash\nif [ "$*" = "-u +%Y%m%dT%H%M%S" ]; then\n if [ -f '+shlex.quote(str(fault/'clock-read'))+' ]; then printf "%s\\n" 20261006T120000; else touch '+shlex.quote(str(fault/'clock-read'))+'; printf "%s\\n" 20261006T120001; fi\n exit 0\nfi\nexec '+shlex.quote(real_date)+' "$@"\n')
 for n in ('mv','date'):(fault/n).chmod(0o755)
 faultenv=dict(tm,PATH=str(fault)+':'+ev['PATH'])
 first=run(['bin/fm-config-push.sh'],faultenv,'r2-retry-first-push',(1,))
 assert 'retained exact retry generation' in first
 (p/'config/crew-harness').write_text('changed-before-retry\n');(fault/'mv').unlink()
 second=run(['bin/fm-config-push.sh'],faultenv,'r2-retry-second-push')
 assert 'config-reread: sent' in second
 inbox=[]
 for f in sorted((p/'state/retry.inbox').glob('*.msg')):
  body=f.read_text();inbox.append({'record':f.name,'body':body})
 if not inbox:
  for f in sorted((p/'state/retry.inbox').iterdir()):
   if f.is_file() and 'CONFIG_REREAD:' in f.read_text():inbox.append({'record':f.name,'body':f.read_text()})
 instructions=[]
 for record in inbox:
  match=re.search(r'CONFIG_REREAD: ([^\s]+)',record['body'])
  if match:
   dest=Path(match.group(1));instructions.append({'path':str(dest),'content':dest.read_text(),'inbox':record['record']})
 (E/'r2-retry-inbox.json').write_text(json.dumps(inbox,indent=2));(E/'r2-retry-instructions.json').write_text(json.dumps(instructions,indent=2))
 assert len(instructions)==2,instructions
 assert '\ncodex\n' in instructions[0]['content'],instructions
 assert 'changed-before-retry' in instructions[1]['content'],instructions
 assert '.20261006T120001.00000001.' in instructions[0]['path'] and '.20261006T120000.00000002.' in instructions[1]['path'],instructions
 assert (s/'config/crew-harness').read_text()=='changed-before-retry\n'
 log.write('PASS: public config-push delivered retained codex bytes before newer changed-before-retry bytes despite simulated UTC clock rollback. Real tmux, real fm-send, real inbox; only OS write/clock faults injected.\n')
finally:
 if tm:subprocess.run(['tmux','-L','fm-lab','kill-server'],env=tm,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 for h in (p,s):
  if h.exists():shutil.rmtree(h)
 fault=R/'.r2-fault-tools'
 if fault.exists():shutil.rmtree(fault)
 log.write('Disposable homes, fault tools and private tmux server removed.\n');log.close()
