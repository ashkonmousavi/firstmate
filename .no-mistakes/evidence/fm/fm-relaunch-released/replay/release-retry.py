import os,sys,pathlib,subprocess,json,urllib.request,time,hashlib,shlex,traceback
R=pathlib.Path.cwd(); L=R/'.validation-live'; E=pathlib.Path(os.environ['FM_LIVE_EVIDENCE']);E.mkdir(parents=True,exist_ok=True)
con=json.load(open(L/'connection.json')); base=f"http://127.0.0.1:{con['port']}"; results=[]
env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','HERDR_')) or k in ['TMUX','TMUX_PANE','NO_MISTAKES_GATE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','CLAUDECODE','CODEX_THREAD_ID']:env.pop(k,None)
env.update(PATH=str(L/'tools')+':'+env['PATH'],HOME=str(L/'user'),XDG_CONFIG_HOME=str(L/'user/config'),CODEX_HOME=str(L/'user/codex'),GIT_CONFIG_GLOBAL=str(L/'user/client-gitconfig'),GIT_CONFIG_SYSTEM='/dev/null',GIT_CONFIG_NOSYSTEM='1',TMPDIR=str(L/'tmp'),TERM='xterm-256color',SHELL='/bin/bash',FM_CONTROL_EXIT_WAIT='3',FM_CONTROL_LAUNCH_WAIT='8',FM_CONTROL_POLL='.1',DISABLE_AUTOUPDATER='1')
# Keep the Unix socket pathname short without writing outside the worktree.
socket_home=L/'retry-socket-home'
subprocess.run(['bash',str(R/'bin/fm-lab-home.sh'),'create',str(socket_home)],check=True,capture_output=True)
(L/'user/codex').mkdir(exist_ok=True)
sock=subprocess.check_output(['bash',str(R/'bin/fm-lab-home.sh'),'tmux-dir',str(socket_home)],text=True).strip()
env['TMUX_TMPDIR']=sock
log=open(E/'release-retry-cli.log','w',buffering=1)
def run(args,cwd=R,check=True,timeout=100,custom=None):
 p=subprocess.run([str(x) for x in args],cwd=cwd,env=custom or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 safe=['[redacted local fixture credential]' if str(x).startswith('Authorization:') else x for x in args]
 log.write('$ '+' '.join(shlex.quote(str(x)) for x in safe)+'\n'+p.stdout+f'\n[exit={p.returncode}]\n')
 if check and p.returncode:raise RuntimeError(p.stdout)
 return p

def api(path,data=None,method=None):
 req=urllib.request.Request(base+'/api/v1/'+path,data=None if data is None else json.dumps(data).encode(),headers={'Authorization':'token '+con['token'],'Content-Type':'application/json'},method=method)
 with urllib.request.urlopen(req,timeout=15) as r:return json.load(r)
def git(p,*args):return run(['git','-C',p,*args]).stdout.strip()
def tm(*args,check=True):return run(['tmux','-L','fm-lab',*args],check=check)
def fields(file):return dict(x.split('=',1) for x in file.read_text().splitlines() if '=' in x)
def snapshot(h,id):return {str(p.relative_to(h)):p.read_bytes() for p in [h/f'state/{id}.meta',h/f'data/{id}/brief.md',h/f'state/{id}.control-relaunch'] if p.exists()}
def outcome(name,fn):
 try:
  detail=fn(); results.append({'name':name,'result':'pass','live':True,'detail':detail});print('PASS '+name+': '+str(detail),flush=True)
 except Exception as e:
  results.append({'name':name,'result':'fail','live':True,'detail':str(e)});print('FAIL '+name+': '+str(e),flush=True);traceback.print_exc(file=log)
 (E/'release-retry-results.json').write_text(json.dumps(results,indent=2))

def fixture(id,released=True):
 id=id+'edge';d=L/id;d.mkdir(exist_ok=True);h=d/'home';run(['bash','bin/fm-lab-home.sh','create',h]);(h/'config/backend').write_text('tmux\n');(h/'config/lane-capacity').write_text('999999 0\n');(h/'config/machine-admission.json').write_text(json.dumps({'schema':'fm-machine-admission.v1','memory_floor_gib':3,'memory_full_avg60_max':5,'disk_floor_gib':1,'disk_paths':[str(h)]}));(h/'config/supervision-host-off').touch();(h/'config/herdr-presentation-spaces').write_text('off\n')
 p=d/'repo';p.mkdir();run(['git','init','-q','-b','main',p]);git(p,'config','user.name','Lab');git(p,'config','user.email','lab@example.invalid');(p/'README.md').write_text('lab\n');git(p,'add','.');git(p,'commit','-qm','base')
 # Treehouse uses an explicitly bounded per-project pool.
 run(['treehouse','init'],cwd=p);(p/'treehouse.toml').write_text('max_trees = 1\nroot = '+json.dumps(str(d/'pool'))+'\n');git(p,'add','treehouse.toml');git(p,'commit','-qm','pool config')
 api('user/repos',{'name':id,'private':False,'default_branch':'main'})
 git(p,'remote','add','origin',base+'/labowner/'+id+'.git')
 # git authentication is configured only for this disposable local repository.
 git(p,'config','http.extraHeader','Authorization: Basic '+__import__('base64').b64encode(('labowner:'+con['token']).encode()).decode())
 git(p,'push','-qu','origin','main');git(p,'checkout','-qb','fm/'+id);(p/'work.txt').write_text('pushed branch work\n');git(p,'add','work.txt');git(p,'commit','-qm','task work');head=git(p,'rev-parse','HEAD');git(p,'push','-qu','origin','fm/'+id);git(p,'checkout','-q','main');git(p,'branch','-D','fm/'+id)
 for _ in range(60):
  try:
   if api('repos/labowner/'+id+'/branches/fm%2F'+id)['commit']['id']==head:break
  except Exception:pass
  time.sleep(.2)
 pr=api('repos/labowner/'+id+'/pulls',{'head':'fm/'+id,'base':'main','title':'Disposable validation PR'})
 # A canonical PR identity omits the port; tea's isolated login supplies transport.
 url='https://127.0.0.1/labowner/'+id+'/pulls/'+str(pr['number'])
 be=env.copy();be.update(FM_HOME=str(h),TREEHOUSE_ROOT=str(d/'pool'))
 meta={'window':'lab:fm-'+id,'endpoint_task_id':id,'worktree':str(h/f'state/{id}.released-copy'),'released_head':head,'released_branch':'fm/'+id,'released_pr':url,'project':str(p),'harness':'codex','kind':'ship','mode':'no-mistakes','yolo':'off','branch':'fm/'+id,'model':'default','effort':'default','pr':url}
 (h/f'data/{id}').mkdir();(h/f'data/{id}/brief.md').write_text("# Task\n## Captain's intent\nValidate copy recreation.\n## Firstmate spec\nRead the relaunch progress note and respond with LAB_NOTE_RECEIVED. Do not edit files or run any commands.\n")
 (h/f'state/{id}.meta').write_text(''.join(k+'='+v+'\n' for k,v in meta.items()))
 if not released:
  lease=run(['treehouse','get','--lease','--no-fetch'],cwd=p,custom=be).stdout.strip().splitlines()[-1];git(lease,'checkout','-qb','fm/'+id,'origin/fm/'+id);meta.pop('released_head');meta.pop('released_branch');meta.pop('released_pr');meta['worktree']=lease;(h/f'state/{id}.meta').write_text(''.join(k+'='+v+'\n' for k,v in meta.items()));tm('new-window','-d','-t','lab:','-n','fm-'+id,'-c',lease)
 return d,h,p,be,head,url

def relaunch(f,note='Live lab recreation'):
 d,h,p,be,head,url=f
 return run(['bash',R/'bin/fm-control.sh',d.name,'relaunch','--note',note],custom=be,check=False,timeout=110)

def refusal_cases():
 f=fixture('liverefuse');d,h,p,be,head,url=f;mp=h/f'state/{d.name}.meta';before=snapshot(h,d.name);desc=[]
 # Existing idle shell is not considered an absent endpoint.
 tm('new-window','-d','-t','lab:','-n','fm-'+d.name,'-c',p)
 a=relaunch(f);assert a.returncode!=0 and 'close that window first' in a.stdout,a.stdout;assert before==snapshot(h,d.name);desc.append('existing shell refused unchanged');tm('kill-window','-t','lab:fm-'+d.name)
 # Capacity deferral must not write either a note or a journal.
 (h/'config/lane-capacity').write_text('0 0\n');a=relaunch(f);assert a.returncode==75,a.stdout;assert before==snapshot(h,d.name);desc.append('lane deferral=75 unchanged');(h/'config/lane-capacity').write_text('999999 0\n')
 for backend in ['orca','cmux','zellij']:
  text=mp.read_text();mp.write_text(text+'backend='+backend+'\n');prior=snapshot(h,d.name);a=relaunch(f);assert a.returncode!=0 and backend in a.stdout.lower(),a.stdout;assert prior==snapshot(h,d.name);mp.write_text(text);desc.append(backend+' refused')
 # Real remote PR state drives closed / unreadable responses.
 api('repos/labowner/'+d.name+'/pulls/1',{'state':'closed'},'PATCH');a=relaunch(f);assert a.returncode!=0 and 'closed without merging' in a.stdout,a.stdout;assert before==snapshot(h,d.name);desc.append('closed PR refused')
 api('repos/labowner/'+d.name+'/pulls/1',{'state':'open'},'PATCH');text=mp.read_text();mp.write_text(text.replace('/pulls/1','/pulls/999'));prior=snapshot(h,d.name);a=relaunch(f);assert a.returncode!=0 and 'could not be read' in a.stdout,a.stdout;assert prior==snapshot(h,d.name);mp.write_text(text);desc.append('unreadable PR refused')
 return '; '.join(desc)

def release_safety():
 f=fixture('livesafety',False);d,h,p,be,head,url=f;mp=h/f'state/{d.name}.meta';wt=pathlib.Path(fields(mp)['worktree']);before=snapshot(h,d.name)
 (wt/'dirty.txt').write_text('uncommitted must survive');a=run(['bash','bin/fm-teardown.sh',d.name,'--keep-open'],custom=be,check=False);assert a.returncode!=0 and (wt/'dirty.txt').exists(),a.stdout;assert fields(mp)['worktree']==str(wt);(wt/'dirty.txt').unlink()
 (wt/'unpublished.txt').write_text('local commit');git(wt,'add','unpublished.txt');git(wt,'commit','-qm','not published');local=git(wt,'rev-parse','HEAD')
 gate=d/'gate.git';run(['git','init','--bare','-q',gate]);git(p,'remote','add','no-mistakes',str(gate));git(wt,'push','-q','no-mistakes','HEAD:fm/'+d.name)
 a=run(['bash','bin/fm-teardown.sh',d.name,'--keep-open'],custom=be,check=False);assert a.returncode!=0,a.stdout;assert wt.exists() and git(wt,'rev-parse','HEAD')==local;assert fields(mp)['worktree']==str(wt)
 return 'dirty files retained; commit held only by no-mistakes refused and retained at '+local

def roundtrip():
 f=fixture('liveround',False);d,h,p,be,head,url=f
 a=run(['bash','bin/fm-teardown.sh',d.name,'--keep-open'],custom=be,check=False);assert a.returncode==0,a.stdout
 m=fields(h/f'state/{d.name}.meta');assert m['worktree']==str(h/f'state/{d.name}.released-copy') and m['released_head']==head,m
 a=relaunch(f)
 cap=tm('capture-pane','-p','-t','lab:fm-'+d.name,'-S','-200',check=False).stdout;(E/'tmux-launch-attempt.txt').write_text(cap)
 assert a.returncode==0,a.stdout+'\nPANE:\n'+cap
 m=fields(h/f'state/{d.name}.meta');wt=pathlib.Path(m['worktree']);assert git(wt,'rev-parse','HEAD')==head;assert git(wt,'branch','--show-current')=='fm/'+d.name
 assert git(wt,'status','--porcelain')=='',git(wt,'status','--porcelain')
 brief=(h/f'data/{d.name}/brief.md').read_text();assert brief.count('This task was relaunched on a recreated local copy')==1,brief
 journal=fields(h/f'state/{d.name}.control-relaunch');note=pathlib.Path(journal['note_file']);assert note.exists() and 'recreated' in note.read_text(),journal
 time.sleep(3);cap=tm('capture-pane','-p','-t',m['window'],'-S','-120').stdout;(E/'tmux-recreated-worker.txt').write_text(cap)
 assert 'resume ' not in cap,cap
 # Actual push verifies branch and upstream remain usable (no changes sent).
 git(wt,'push','origin','HEAD')
 (E/'recreated-note.md').write_text(note.read_text());(E/'recreated-record.txt').write_text((h/f'state/{d.name}.meta').read_text())
 return 'released and recreated branch fm/'+d.name+' at '+head+'; durable note published; actual push succeeded; worker transcript retained'

def release_retry():
 f=fixture('releaseretry',False);d,h,p,be,head,url=f;mp=h/f'state/{d.name}.meta';wt=fields(mp)['worktree']
 # The idle endpoint has left the copy, so a return cannot itself close it.
 tm('send-keys','-t','lab:fm-'+d.name,'cd '+shlex.quote(str(p)),'Enter');time.sleep(.3)
 shim=d/'fault-bin';shim.mkdir();return_fault=d/'return-fault';close_fault=d/'close-fault';return_fault.touch();close_fault.touch()
 (shim/'treehouse').write_text('''#!/usr/bin/env python3
import os,sys,pathlib
if sys.argv[1:2]==['return'] and pathlib.Path(os.environ['FM_LAB_RETURN_FAULT']).exists():raise SystemExit(70)
os.execv(os.environ['FM_LAB_REAL_TREEHOUSE'],['treehouse']+sys.argv[1:])
''')
 (shim/'tmux').write_text('''#!/usr/bin/env python3
import os,sys,pathlib
if sys.argv[1:2]==['kill-window'] and pathlib.Path(os.environ['FM_LAB_CLOSE_FAULT']).exists():raise SystemExit(70)
os.execv('/usr/bin/tmux',['tmux']+sys.argv[1:])
''')
 for q in shim.iterdir():q.chmod(0o755)
 be.update(PATH=str(shim)+':'+be['PATH'],FM_LAB_RETURN_FAULT=str(return_fault),FM_LAB_CLOSE_FAULT=str(close_fault),FM_LAB_REAL_TREEHOUSE=__import__('shutil').which('treehouse'))
 def td():return run(['bash','bin/fm-teardown.sh',d.name,'--keep-open'],custom=be,check=False)
 a=td();assert a.returncode!=0,a.stdout;m=fields(mp);assert m['released_head']==head and m['worktree']==wt,m;assert pathlib.Path(wt).exists()
 return_fault.unlink();a=td();assert a.returncode!=0,a.stdout;m=fields(mp);assert m['released_head']==head and m['worktree']==wt,m;assert git(wt,'rev-parse','HEAD')!=head
 close_fault.unlink();a=td();assert a.returncode==0,a.stdout;m=fields(mp);assert m['worktree'].endswith('.released-copy') and m['released_head']==head,m
 assert '[fm/'+d.name+']' not in git(p,'worktree','list')
 a=relaunch(f);assert a.returncode==0,a.stdout;m=fields(mp);assert git(m['worktree'],'rev-parse','HEAD')==head
 return 'persisted proof survived failed return, then real return plus failed endpoint close; third teardown published sentinel only after cleanup, and relaunch restored original SHA'
try:
 tm('new-session','-d','-s','lab','-x','120','-y','40','-c',R,'/bin/bash --noprofile --norc');env['TMUX']=tm('display-message','-p','-t','lab','#{socket_path},#{pid},0').stdout.strip();tm('set-option','-gw','automatic-rename','off');tm('set-option','-gw','allow-rename','off');tm('set-option','-g','default-terminal','xterm-256color');tm('set-option','-g','default-shell','/bin/bash');tm('set-option','-g','default-command','/bin/bash --noprofile --norc')
 for k in ['PATH','HOME','XDG_CONFIG_HOME','CODEX_HOME','GIT_CONFIG_GLOBAL','GIT_CONFIG_SYSTEM','GIT_CONFIG_NOSYSTEM','TMPDIR']:tm('set-environment','-g',k,env[k])
 outcome('Release retry retains publication proof until both copy return and endpoint close complete',release_retry)
finally:
 tm('kill-server',check=False);run(['bash','bin/fm-lab-home.sh','teardown',socket_home]);log.close()
