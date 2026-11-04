import hashlib, json, os, pathlib, shutil, subprocess, time
ROOT=pathlib.Path('~/.no-mistakes/worktrees/049a88734b0e/01M6K2Y2DSAB6SW983JD0NTC91')
E=pathlib.Path('~/.no-mistakes/evidence/01M6K2Y2DSAB6SW983JD0NTC91')
lab=ROOT/'.i'; home=lab/'h'; mate=lab/'mate'; code=lab/'code'
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'HERDR_')) or k in ('TMUX','TMUX_PANE'): env.pop(k,None)
env.update(FM_HOME=str(home),TMPDIR=str(ROOT/'.quota-test-tmp'),TMUX_TMPDIR=str(home/'tmux'))
log=(E/'live-inheritance-transcript.txt').open('w')
results=[]
def run(cmd,label):
    p=subprocess.run(cmd,cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
    log.write('\n### '+label+'\n$ '+' '.join(cmd)+'\n'+p.stdout+'exit='+str(p.returncode)+'\n');log.flush();return p
try:
    assert not lab.exists(); code.mkdir(parents=True)
    # An exact, disposable installation of the production scripts permits the
    # two operational homes to be siblings of the code root inside this worktree.
    shutil.copytree(ROOT/'bin',code/'bin')
    assert hashlib.sha256((code/'bin/fm-config-push.sh').read_bytes()).digest()==hashlib.sha256((ROOT/'bin/fm-config-push.sh').read_bytes()).digest()
    assert run(['bash','bin/fm-lab-home.sh','create',str(home)],'Create isolated home').returncode==0
    for d in ('config','data','state','projects','bin'): (mate/d).mkdir(parents=True,exist_ok=True)
    (mate/'.fm-secondmate-home').write_text('labmate\n')
    shutil.copyfile(ROOT/'AGENTS.md',mate/'AGENTS.md')
    (home/'config/backend').write_text('tmux\n')
    (home/'tmux').mkdir()
    p=run(['tmux','-L','fm-lab','new-session','-d','-s','parked','-x','120','-y','40','-c',str(mate),'bash --noprofile --norc'],
          'Private model-free parked endpoint; no native primary or worker is launched')
    assert p.returncode==0
    p=run(['tmux','-L','fm-lab','display-message','-p','-t','parked','#{socket_path},#{pid},0'],'Private socket identity')
    assert p.returncode==0;env['TMUX']=p.stdout.strip()
    (home/'state/labmate.meta').write_text('kind=secondmate\nharness=codex\nbackend=tmux\nwindow=parked:0\nhome='+str(mate)+'\n')
    (home/'state/.secondmate-relaunch-bound-labmate').write_text(str(int(time.time()))+'\tdead\n')
    for policy in ('rank-only','absent'):
        setting=home/'config/quota-gate'
        if policy=='rank-only': setting.write_text('rank-only\n')
        else: setting.unlink()
        p=run(['bash',str(code/'bin/fm-config-push.sh')],'Public config push; source setting='+policy)
        dest=mate/'config/quota-gate'
        ok=(dest.read_bytes()==b'rank-only\n') if policy=='rank-only' and dest.exists() else (not dest.exists() if policy=='absent' else False)
        log.write('Observed destination quota-gate: '+(repr(dest.read_bytes()) if dest.exists() else 'absent')+'\n');log.flush()
        result={'policy':policy,'exit':p.returncode,'bytes_correct':ok};results.append(result)
        assert p.returncode==0 and ok
finally:
    if (home/'tmux').exists():
        p=run(['tmux','-L','fm-lab','kill-server'],'Stop private backend')
        log.write('private backend stop exit='+str(p.returncode)+'\n')
    shutil.rmtree(lab,ignore_errors=True)
    log.write('Disposed code copy and both operational homes.\n');log.close()
    (E/'live-inheritance-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results))
