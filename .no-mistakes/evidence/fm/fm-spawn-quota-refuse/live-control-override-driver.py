"""Real exhausted-quota control relaunch forwards its override and evidence."""
import os,pathlib,subprocess,json,shutil,time,hashlib,stat
R=pathlib.Path.cwd();L=R/'.q';H=L/'h';EV=pathlib.Path(__file__).parent
E=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TASK_ID','FM_TEST_SEAM','TMUX']:E.pop(k,None)
E.update(FM_HOME=str(H),HOME=str(L/'u'),GROK_HOME=str(L/'u/.grok'),TMUX_TMPDIR=str(L/'t'),TMPDIR=str(L/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
log=open(EV/'live-control-override-transcript.log','w',buffering=1)
def cmd(args,code=0):
 log.write('$ '+' '.join(args)+'\n');p=subprocess.run(args,env=E,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 log.write(p.stdout+'exit='+str(p.returncode)+'\n');assert p.returncode==code,p.stdout
 return p.stdout
def tm(*a):return subprocess.check_output(['tmux','-L','fm-lab',*a],env=E,text=True)
def discard(p):
 if not p.is_dir() or p.is_symlink():return
 assert p.stat().st_uid==os.getuid()
 for b,ds,fs in os.walk(p,followlinks=False):
  q=pathlib.Path(b);os.chmod(q,stat.S_IMODE(q.stat().st_mode)|stat.S_IRWXU)
 shutil.rmtree(p)
L.mkdir();cmd(['bin/fm-lab-home.sh','create',str(H)])
for d in ['u','t','tmp','project']:(L/d).mkdir()
proj=L/'project';cmd(['git','-C',str(proj),'init','-q','-b','main']);cmd(['git','-C',str(proj),'-c','user.name=Lab','-c','user.email=lab@example.invalid','-c','commit.gpgsign=false','-c','core.hooksPath=/dev/null','commit','--allow-empty','-qm','seed'])
(proj/'treehouse.toml').write_text('root = ".pool"\n')
(H/'config/backlog-backend').write_text('manual\n');(H/'config/lane-capacity').write_text('20 0\n')
(H/'config/machine-admission.json').write_text(json.dumps({'schema':'fm-machine-admission.v1','memory_floor_gib':0,'memory_full_avg60_max':100,'disk_floor_gib':0,'disk_paths':[str(L)]}))
(H/'config/crew-dispatch.json').write_text(json.dumps({'default':[{'harness':'grok','model':'grok-4.7'},{'harness':'codex','model':'gpt-6.1-sol'}]}))
p=json.load(open(R/'tests/fixtures/quota-axi-healthy.json'))
for x in p['providers']:
 if x['provider']=='grok':
  for r in x['quotaSemantics']['effectiveAvailability']:r['effectivePercentRemaining']=0;r['runway']={'status':'exhausted_now'}
f=L/'quota.json';f.write_text(json.dumps(p));E['FM_QUOTA_SNAPSHOT_FILE']=str(f)
id='control-override-live';d=H/'data'/id;d.mkdir()
(d/'brief.md').write_text("# Task\n## Captain's intent\nDisposable quota startup verification.\n## Firstmate spec\nNo tools or file changes. If authenticated, answer QUOTA_LAB_READY and wait.\n")
cmd(['tmux','-L','fm-lab','new-session','-d','-s','launcher','-x','120','-y','40','-c',str(R),'bash','--noprofile','--norc'])
try:
 E['TMUX']=tm('display-message','-p','-t','launcher','#{socket_path}').strip()+',0,0'
 cmd(['bin/fm-spawn.sh',id,str(proj),'--scout','--harness','grok','--model','grok-4.7','--quota-override','initial launch reason'])
 target='launcher:fm-'+id
 for i in range(300):
  if 'ctrl+q' in tm('capture-pane','-p','-t',target):break
  time.sleep(.1)
 else:raise AssertionError('Grok quit footer not ready')
 tm('send-keys','-t',target,'C-q')
 for i in range(100):
  if tm('display-message','-p','-t',target,'#{pane_current_command}').strip() in ['bash','zsh','sh']:break
  time.sleep(.1)
 else:raise AssertionError('Grok did not stop')
 out=cmd(['bin/fm-control.sh',id,'relaunch','--harness','grok','--model','grok-4.7','--quota-override','replacement reason with spaces','--note','live delegated quota override'])
 assert out.count('notice: fm-control quota check refuses grok')==1 and 'relaunched '+id in out
 m=(H/'state'/(id+'.meta')).read_text();log.write('Persisted replacement metadata:\n'+m)
 assert 'quota_override=replacement reason with spaces\n' in m and 'quota_override_evidence=refuse: provider grok' in m
 assert 'initial launch reason' not in m
 log.write('Real control relaunch preserved the new reason and refusal evidence through spawn delegation.\n')
finally:
 cmd(['tmux','-L','fm-lab','kill-server'])
 cmd(['bin/fm-lab-home.sh','teardown',str(H)])
 token=hashlib.sha256(str(H).encode()).hexdigest();discard(pathlib.Path('/tmp')/('fm-'+id+'+'+token));discard(L)
 log.close()
