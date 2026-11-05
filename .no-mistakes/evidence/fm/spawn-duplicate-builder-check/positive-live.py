import os,pathlib,subprocess,json,time,urllib.request,base64,traceback,shutil
R=pathlib.Path.cwd();D=R/'.test-live';E=pathlib.Path('~/.no-mistakes/evidence/01M6P6CGV28DT78F2NZW37QR91');v=json.loads((D/'lab-env.json').read_text());env=v['env'];lab=pathlib.Path(v['lab']);proj=pathlib.Path(v['project']);sock=v['socket'];PR=v['branch_pr'];URL=PR['html_url'].split('/labuser/')[0]
log=(E/'attachment-live-transcript.log').open('w',buffering=1)
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
 # Newer PRs force target #4 beyond the first page regardless of list direction.
 for n in range(3):
  b='later-'+str(n)
  try:api('/repos/labuser/project/branches/'+b);continue
  except Exception:pass
  api('/repos/labuser/project/branches',{'new_branch_name':b,'old_branch_name':'main'})
  api('/repos/labuser/project/contents/'+b+'.txt',{'branch':b,'message':'Later unrelated change','content':base64.b64encode(b'later\n').decode()})
  api('/repos/labuser/project/pulls',{'base':'main','head':b,'title':b,'body':'unrelated'})
 pages=[]
 for n in range(1,10):
  p=api('/repos/labuser/project/pulls?state=open&limit=50&page='+str(n));pages.append([x['number'] for x in p])
  if not p:break
 note('REAL API pages (requested limit=50; configured cap=2): '+json.dumps(pages))
 assert all(len(x)<=2 for x in pages)
 assert PR['number'] not in pages[0] and any(PR['number'] in x for x in pages[1:])
 p=run(['python3','bin/fm-open-pr-lookup.py','--forge','forgejo','--origin',URL+'/labuser/project.git','--branch','fm/dup-live','--task-id','dup-live'])
 note('LOOKUP beyond page 1: '+p.stdout.strip());assert json.loads(p.stdout)['prs'][0]['number']==PR['number']
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
 # Bad continuations are verified before allocation.
 spawn('dup-live','--continue-pr','999',expect=1,contains='already has an open pull request')
 api('/repos/labuser/project/pulls/'+str(PR['number']),{'state':'closed'},'PATCH')
 spawn('dup-live','--continue-pr',str(PR['number']),expect=1,contains='is not an open pull request')
 api('/repos/labuser/project/pulls/'+str(PR['number']),{'state':'open'},'PATCH')
 for flags in (['--continue-pr','999'],['--continue-pr=999']):
  p,calls=spawn('local-boundary',*flags,expect=1,mode='local-only',contains='local-only has none')
  assert not (lab/'state/local-boundary.meta').exists()
  assert not any('fetch' in a[1:] or a[0].endswith('/tea') for a in calls)
 note('PASS local-only split/equals attachment refusal: verified no Git fetch or tea execution; no task metadata')
 brief('dup-live')
 p,calls=spawn('dup-live','--continue-pr',str(PR['number']))
 meta=(lab/'state/dup-live.meta').read_text();wt=next(x.split('=',1)[1] for x in meta.splitlines() if x.startswith('worktree='))
 head=run(['git','rev-parse','HEAD'],cwd=wt).stdout.strip()
 branch=run(['git','branch','--show-current'],cwd=wt).stdout.strip()
 assert head==PR['head']['sha'] and pathlib.Path(wt,'fm-dup-live.txt').exists()
 assert 'branch=fm/dup-live' in meta
 assert 'continue_pr='+PR['html_url'] in meta
 note('PERSISTED attachment: '+json.dumps({'HEAD':head,'checkout_branch':branch or '(detached as the standard launch brief specifies)','recorded_branch':'fm/dup-live','PR_head':PR['head']['sha'],'PR_only_file':True,'continue_pr':PR['html_url']}))
 # Real terminal capture demonstrates the supplied real CLI command ran.
 time.sleep(1)
 wins=run(['tmux','-S',sock,'list-panes','-a','-F','#{pane_id} #{pane_current_path}']).stdout
 note('PRIVATE TMUX panes:\n'+wins)
 for line in wins.splitlines():
  pane,path=line.split(' ',1)
  if path==wt:
   capture=run(['tmux','-S',sock,'capture-pane','-p','-t',pane]).stdout
   note('WORKER TERMINAL:\n'+capture)
   assert 'codex-cli' in capture
 note('PASS continuation starts the real allocated copy at the real open PR head and records its URL')
 # Retained relaunch reuses its own checkout and deliberately does not consult the forge.
 trace.write_text('')
 a=['bash','bin/fm-spawn.sh','dup-live','--relaunch','--harness','codex --version']
 p=run(a,check=False);note('$ '+' '.join(a)+'\n'+p.stdout.strip()+f'\nexit={p.returncode}')
 assert p.returncode==0,p.stdout
 calls=[json.loads(x) for x in trace.read_text().splitlines()]
 assert not any(a[0].endswith('/tea') for a in calls)
 assert 'worktree='+wt in (lab/'state/dup-live.meta').read_text()
 note('PASS relaunch with an open PR reuses its existing checkout without a forge call')
 # Machine admission must defer first, then a manual retry rechecks the now-open task PR.
 brief('defer-live')
 (lab/'config/lane-capacity').write_text('0 0\n')
 p,calls=spawn('defer-live',expect=75,contains='no free machine lane')
 assert not any(a[0].endswith('/tea') for a in calls)
 assert not (lab/'state/defer-live.meta').exists()
 queue=list((lab/'state/spawn-deferred/queue').iterdir())
 assert queue
 note('PERSISTED deferral: '+queue[0].read_text())
 body=api('/repos/labuser/project/pulls/5')['body']
 api('/repos/labuser/project/pulls/5',{'body':body+'\nTask: defer-live'},'PATCH')
 (lab/'config/lane-capacity').write_text('999999 0\n')
 p,calls=spawn('defer-live',expect=1,contains='already has an open pull request')
 assert any(a[0].endswith('/tea') for a in calls)
 assert not (lab/'state/defer-live.meta').exists()
 note('PASS capacity deferral reads no forge and retry performs a fresh real lookup and hard-refuses the new matching PR')

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
