import os,pathlib,subprocess,json,time,urllib.request,base64,traceback,shutil
R=pathlib.Path.cwd();D=R/'.test-live';E=pathlib.Path('~/.no-mistakes/evidence/01M6P6CGV28DT78F2NZW37QR91');v=json.loads((D/'lab-env.json').read_text());env=v['env'];lab=pathlib.Path(v['lab']);proj=pathlib.Path(v['project']);sock=v['socket'];PR=v['branch_pr'];URL=PR['html_url'].split('/labuser/')[0]
log=(E/'remaining-live-transcript.log').open('w',buffering=1)
def note(s):print(s,flush=True);log.write(s+'\n')
def run(a,check=True,cwd=R,e=None,timeout=180):
 p=subprocess.run([str(x) for x in a],env=e or env,cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
 if check and p.returncode:raise RuntimeError(f'{a}: {p.returncode}: {p.stdout}')
 return p
basic='Basic '+base64.b64encode(b'labuser:DisposableLab-12345').decode()
def api(path,data=None,method=None):
 req=urllib.request.Request(URL+'/api/v1'+path,data=json.dumps(data).encode() if data is not None else None,method=method,headers={'Authorization':basic,'Content-Type':'application/json'})
 with urllib.request.urlopen(req,timeout=15) as r:return json.load(r)
server=None; moved=False
try:
 out=(E/'forgejo-positive-server.log').open('w')
 server=subprocess.Popen(v['fargs']+['web'],env=env,cwd=R,stdout=out,stderr=subprocess.STDOUT)
 for _ in range(80):
  try:api('/version');break
  except Exception:time.sleep(.2)
 else:raise RuntimeError('server startup failed')
 run(['tmux','-S',sock,'new-session','-d','-s','lab','-x','120','-y','40','-c',R])
 env['TMUX']=sock+','+run(['tmux','-S',sock,'display-message','-p','#{pid}']).stdout.strip()+',0'
 # Observe real executable invocations without replacing their behavior.
 observer=D/'observe';observer.mkdir(exist_ok=True)
 trace=D/'exec-trace.log';trace.write_text('')
 for cmd in ('git','tea'):
  real=shutil.which(cmd,path=env['PATH'])
  (observer/cmd).write_text('#!/usr/bin/env python3\nimport os,sys,json\nwith open('+repr(str(trace))+',"a") as f:f.write(json.dumps([sys.argv[0],*sys.argv[1:]])+"\\n")\nos.execv('+repr(real)+','+repr([real])+'+sys.argv[1:])\n')
  (observer/cmd).chmod(0o755)
 env['PATH']=str(observer)+':'+env['PATH']
 run(['git','fetch','--quiet','origin'],cwd=proj)
 assert any('fetch' in json.loads(x)[1:] for x in trace.read_text().splitlines())
 run(['tea','login','list','--output','json'])
 assert any('tea' in json.loads(x)[0] for x in trace.read_text().splitlines())
 note('OBSERVERS: positive controls recorded actual Git fetch and actual tea login list; both wrappers exec the installed real binary')
 def brief(task,mode='direct-PR'):
  x=lab/'data'/task;x.mkdir(exist_ok=True)
  (x/'brief.md').unlink(missing_ok=True)
  args=['bash','bin/fm-brief.sh',task,'project','--mode',mode]
  if mode!='local-only':args+=['--forge','forgejo']
  p=run(args);note('SCAFFOLD: '+p.stdout.strip())
  file=x/'brief.md'
  file.write_text(file.read_text().replace('{TASK}','Verify isolated spawn attachment and metadata.').replace('{FIRSTMATE_SPEC}','Run only the caller-supplied real CLI version command.'))
 def spawn(task,*flags,expect=0,contains=None,mode='direct-PR'):
  trace.write_text('');a=['bash','bin/fm-spawn.sh',task,str(proj),'--mode',mode,'--yolo','off',*flags,'codex --version']
  p=run(a,check=False);note('$ '+' '.join(a)+'\n'+p.stdout.strip()+f'\nexit={p.returncode}')
  assert p.returncode==expect,p.stdout
  if contains:assert contains in p.stdout,p.stdout
  return p, [json.loads(x) for x in trace.read_text().splitlines()]
 # Ordinary local-only must skip every lookup invocation.
 (lab/'data/projects.md').write_text('- project [local-only] - disposable lab (added 2026-11-05)\n')
 brief('local-ordinary','local-only')
 p,calls=spawn('local-ordinary',mode='local-only')
 assert not any(a[0].endswith('/tea') for a in calls)
 assert 'continue_pr=' not in (lab/'state/local-ordinary.meta').read_text()
 note('PASS ordinary local-only spawn succeeds with no tea call or continuation metadata')
 (lab/'data/projects.md').write_text('- project [direct-PR forge=forgejo] - disposable lab (added 2026-11-05)\n')
 # Explicit bypass reason against an actual task-naming open PR.
 bodypr=api('/repos/labuser/project/pulls/5')
 api('/repos/labuser/project/pulls/5',{'body':bodypr['body']+'\nTask: skip-live\nTask: unknown-live'},'PATCH')
 brief('skip-live')
 p,calls=spawn('skip-live','--no-forge-check','isolated lab explicit bypass')
 assert 'forge_check_skipped=isolated lab explicit bypass' in (lab/'state/skip-live.meta').read_text()
 assert not any(a[0].endswith('/tea') for a in calls)
 note('PASS explicit bypass launches and records the printable reason without a forge call')
 spawn('invalid-reason','--no-forge-check',' ',expect=1,contains='needs a one-line reason')
 # Make only tea unavailable; real forge and Git transport stay healthy.
 brief('unknown-live')
 run(['git','fetch','--quiet','origin'],cwd=proj)
 # Existing PR branch is needed for a continuation UNKNOWN fallback.
 api('/repos/labuser/project/branches',{'new_branch_name':'fm/unknown-live','old_branch_name':'fm/dup-live'})
 (D/'bin/tea').rename(D/'bin/tea-disabled');moved=True
 (observer/'tea').unlink()
 p,calls=spawn('unknown-live','--continue-pr','999',contains='UNKNOWN')
 meta=(lab/'state/unknown-live.meta').read_text();wt2=next(x.split('=',1)[1] for x in meta.splitlines() if x.startswith('worktree='))
 assert run(['git','rev-parse','HEAD'],cwd=wt2).stdout.strip()==PR['head']['sha']
 assert 'continue_pr=999' in meta
 note('PASS explicitly authorized UNKNOWN continuation fetches the real branch and records the requested PR number')
except Exception:
 note(traceback.format_exc());raise
finally:
 if moved:(D/'bin/tea-disabled').rename(D/'bin/tea')
 p=run(['tmux','-S',sock,'kill-server'],check=False);note('Private tmux stopped; exit='+str(p.returncode))
 if server is not None:server.terminate();server.wait(timeout=25)
 note('Forgejo stopped and child exit status awaited')
 log.close()
