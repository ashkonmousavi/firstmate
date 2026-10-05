import pathlib, tempfile, os, subprocess, shutil, re, json
R=pathlib.Path.cwd(); E=pathlib.Path('/home/zcrew/.no-mistakes/evidence/01M45JNGXNRJ522PPBNYHJF1VA')
L=pathlib.Path(tempfile.mkdtemp(prefix='l.',dir=R)); (L/'tmux').mkdir()
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('TASKS_AXI') or k.startswith('TMUX'))}
env.update(FM_HOME=str(L), FM_BACKEND='tmux', TMUX='.test-phase/absent-private-socket,0,0', TMUX_TMPDIR=str(L/'tmux'), TMPDIR=str(R/'.test-phase/tmp'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
log=(E/'live-compat-transcript.log').open('w'); results=[]
started=False

def run(args):
 p=subprocess.run(args,env=env,cwd=R,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45)
 log.write('\n$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+'\nraw exit: '+str(p.returncode)+'\n'); log.flush(); return p

def passed(name,detail):
 results.append(dict(name=name,result='pass',live=True,detail=detail)); log.write('OBSERVATION '+name+': '+detail+'\n');log.flush()

def lib(fn,p): return run(['bash','-c','set -o pipefail; . bin/fm-dod-lib.sh; "$1" "$2"','_',fn,str(p)])

try:
 # Mint before population; the private socket is a real disposable tmux, not a harness or login imitation.
 (L/'tmux').rmdir()
 assert run(['bash','bin/fm-lab-home.sh','create',str(L)]).returncode==0
 (L/'tmux').mkdir(); (L/'config/backlog-backend').write_text('manual\n')
 proj=L/'projects/proj'; proj.mkdir(); assert run(['git','-C',str(proj),'init','-q']).returncode==0
 child=L/'nav'; (child/'data/nav-preps').mkdir(parents=True)
 (L/'data/secondmates.md').write_text('- nav - navigation (home: '+str(child)+'; scope: wayfinding; projects: firstmate; added 2026-10-05)\n')
 for fmt in ['full','surgical']:
  for mode in ['direct-PR','no-mistakes']:
   for placement in ['tier','appendix']:
    id='large-'+fmt+'-'+mode+'-'+placement
    data=(E/('filled-'+fmt+'-prep.md')).read_text()
    choice='checks-only (direct-PR)' if mode=='direct-PR' else 'checks + AI review (no-mistakes)'
    data=re.sub(r'^- Delivery depth:.*$','- Delivery depth: '+choice+', isolated large record checks.',data,flags=re.M)
    extra='\n'.join('- Retained context '+str(n)+': '+('x'*80) for n in range(1200))+'\n'
    data=data.replace('## Tier\n','## Tier\n'+extra,1) if placement=='tier' else data+'\n## Appendix\n'+extra
    source=child/'data/nav-preps'/ (id+'.md'); source.write_text(data)
    p=lib('fm_prep_delivery_mode',source); assert p.returncode==0 and p.stdout.strip()==mode, p.stdout
    p=lib('fm_prep_unfilled_reason',source); assert p.returncode==1 and not p.stdout,p.stdout
    p=run(['bash','bin/fm-prep-install.sh',id]); assert p.returncode==0,p.stdout
    dest=L/'data'/id/'prep.md'; assert dest.read_bytes()==source.read_bytes()
    passed(id,'Reader and completeness survive pipefail on '+str(len(data))+' bytes; the real prep-install consumer copies identical bytes from isolated nav-prep.')
 # Scout exclusion reaches the actual unavailable private backend without any prep.
 id='live-scout'; p=run(['bash','bin/fm-brief.sh',id,'proj','--scout']); assert p.returncode==0,p.stdout
 brief=L/'data'/id/'brief.md'; brief.write_text(brief.read_text().replace('{TASK}','Verify isolated scout admission.').replace('{FIRSTMATE_SPEC}','Do not write source or contact external services.'))
 p=run(['bash','bin/fm-spawn.sh',id,str(proj),'codex','--scout']); assert 'Delivery depth' not in p.stdout and (L/'data'/id/'launch-brief.md').exists() and 'absent-private-socket' in p.stdout,p.stdout
 passed('Scout omits prep and reaches real backend','No preparation exists; scout renders launch brief then real tmux refuses only its absent private socket.')
 p=run(['bash','bin/fm-spawn.sh',id,str(proj),'codex','--scout','--mode','direct-PR']); assert 'applies only to ship spawns' in p.stdout,p.stdout
 passed('Scout still rejects ship mode flags','Existing explicit --mode refusal remains unchanged.')
 id='live-secondmate'
 p=run(['bash','bin/fm-spawn.sh',id,str(child),'codex','--secondmate','--mode','no-mistakes','--yolo','off']); assert 'applies only to ship spawns' in p.stdout,p.stdout
 p=run(['bash','bin/fm-spawn.sh',id,str(child),'codex','--secondmate']); assert 'Delivery depth' not in p.stdout and 'secondmate home cannot be inside' in p.stdout,p.stdout
 passed('Secondmate bypasses depth and retains role and home guards','With no prep, --mode refuses as ship-only; without it the existing in-repository home restriction refuses, rather than new depth validation.')
 # Real agent-free shell endpoint permits recorded recovery. Stop at the existing primary-copy guard after launch rendering.
 env.pop('TMUX',None)
 p=run(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','fm-lab-compat','-n','fm-recovery','-x','120','-y','40','-c',str(proj),'bash --noprofile --norc']); assert p.returncode==0,p.stdout
 started=True
 p=run(['tmux','-L','fm-lab','display-message','-p','-t','fm-lab-compat:fm-recovery','#{socket_path},#{pid},0']); assert p.returncode==0,p.stdout
 env['TMUX']=p.stdout.strip()
 for mode in ['direct-PR','no-mistakes','local-only']:
  id='recorded-'+mode
  p=run(['tmux','-L','fm-lab','rename-window','-t','fm-lab-compat:', 'fm-'+id]); assert p.returncode==0,p.stdout
  p=run(['bash','bin/fm-brief.sh',id,'proj','--mode',mode]); assert p.returncode==0,p.stdout
  brief=L/'data'/id/'brief.md'; brief.write_text(brief.read_text().replace('{TASK}','Recover the recorded isolated task without preparation.').replace('{FIRSTMATE_SPEC}','Verify recovery admission; do not contact external services.'))
  meta=L/'state'/(id+'.meta'); meta.write_text('window=fm-lab-compat:fm-'+id+'\nkind=ship\nproject='+str(proj)+'\nworktree='+str(proj)+'\nharness=codex\nmode='+mode+'\nyolo=off\nbranch=fm/'+id+'\n')
  p=run(['bash','bin/fm-spawn.sh',id,'--relaunch'])
  launch=L/'data'/id/'launch-brief.md'
  assert launch.exists() and 'Delivery depth' not in p.stdout and ('refusing' in p.stdout or 'refused' in p.stdout),p.stdout
  assert not (L/'data'/id/'prep.md').exists()
  assert 'Delivery contract: mode='+mode in launch.read_text()
  assert 'Accepted specification for --intent' not in launch.read_text()
  (E/(id+'-launch-brief.md')).write_bytes(launch.read_bytes())
  passed('Recorded '+mode+' recovery omits prep','Real tmux reports an agent-free shell; relaunch preserves recorded mode and renders launch brief without prep or accepted-spec overlay, then existing primary-copy isolation guard refuses before any agent launch.')
 print('Live compatibility scenarios completed:',len(results))
finally:
 if started:
  p=run(['tmux','-L','fm-lab','kill-server'])
  log.write('Private fm-lab server stopped: '+str(p.returncode)+'\n')
 (E/'live-compat-results.json').write_text(json.dumps(results,indent=2)+'\n')
 shutil.rmtree(L)
 log.write('CLEANUP: disposable home, project, nav-preps and private tmux socket removed.\n');log.close()
