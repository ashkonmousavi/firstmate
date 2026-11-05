import os, json, pathlib, subprocess, shutil, time, shlex
R = pathlib.Path.cwd()
E = pathlib.Path('~/.no-mistakes/evidence/01M6P2F9E2VSTH4R8X14HYZXZV')
L = R / '.test-tmp/live'
L.mkdir()
env = dict(os.environ)
for k in list(env):
    if k.startswith('FM_') or k in ('TMUX', 'TMUX_PANE', 'CLAUDECODE'):
        env.pop(k)
def call(args, timeout=90, check=False):
    p = subprocess.run([str(x) for x in args], env=env, cwd=R, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    with (E/'live-cli.log').open('a') as f:
        f.write('$ '+ ' '.join(str(x) for x in args) + '\n' + p.stdout + '\nexit='+str(p.returncode)+'\n')
    if check and p.returncode:
        raise RuntimeError(p.stdout)
    return p
def write(p, s):
    p=L/p; p.parent.mkdir(parents=True,exist_ok=True); p.write_text(s)
def launch(*args): return call(['bash',R/'bin/fm-autolaunch.sh',*args], timeout=180)
try:
    call(['bash',R/'bin/fm-lab-home.sh','create',L],check=True)
    write(pathlib.Path('config/lane-capacity'),'1 0\n')
    write(pathlib.Path('config/machine-admission.json'),json.dumps(dict(schema='fm-machine-admission.v1', memory_floor_gib=0,memory_full_avg60_max=100,disk_floor_gib=0,disk_paths=[str(L)])))
    write(pathlib.Path('config/crew-harness'),'codex\n')
    write(pathlib.Path('config/crew-dispatch.json'),json.dumps({'shared_quota':True,'default':[{'harness':'codex','model':'gpt-6.1-sol','effort':'low'}]}))
    write(pathlib.Path('config/autolaunch-steps'),'off\n')
    write(pathlib.Path('.tasks.toml'),'[tasks]\nadapter = "markdown"\nfile = "data/backlog.md"\n')
    write(pathlib.Path('data/backlog.md'),'## In flight\n## Queued\n'+''.join(f'- [ ] {id} - {title} (repo: proj) (kind: ship)\n  SLICE: main/{id}\n' for id,title in [('help','Help/UX'),('j01','J-01'),('ai','X AI')])+'## Done\n')
    write(pathlib.Path('data/slices/catalog.json'),json.dumps(dict(schema='slice-catalog.v1',revision='live',slices=[dict(id='main/'+id,queue_band=i,queue_order=0) for i,id in enumerate(['ai','j01','help'])])))
    write(pathlib.Path('config/slicing.json'),json.dumps(dict(catalog=str(L/'data/slices/catalog.json'))))
    write(pathlib.Path('data/ai/brief.md'),"## Captain's intent\nPrepare a plan to add a greeting to this disposable project.\n## Firstmate spec\nPreserve this outcome.\n")
    write(pathlib.Path('data/ai/autolaunch-prep'),'project=proj\nkind=ship\nmode=local-only\nyolo=off\n')
    (L/'projects/proj').mkdir(parents=True)
    call(['git','-C',L/'projects/proj','init','-b','main'],check=True)
    write(pathlib.Path('projects/proj/README.md'),'# Disposable greeting project\n')
    call(['git','-C',L/'projects/proj','add','README.md'],check=True)
    call(['git','-C',L/'projects/proj','-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-m','initial'],check=True)
    call(['git','init','--bare',L/'origin.git'],check=True)
    call(['git','-C',L/'projects/proj','remote','add','origin',str(L/'origin.git')],check=True)
    call(['git','-C',L/'projects/proj','push','-u','origin','main'],check=True)
    call(['git','--git-dir='+str(L/'origin.git'),'symbolic-ref','HEAD','refs/heads/main'],check=True)
    (L/'user').mkdir(); (L/'tmux').mkdir()
    env.update(FM_HOME=str(L),TREEHOUSE_ROOT=str(L/'pool'),TMPDIR=str(R/'.test-tmp'),
               FM_TEST_SEAM='1', FM_ACTIVITY_READER=os.environ['HOME']+'/.config/skills-master/.agents/skills/activity/activity.sh',
               CODEX_HOME=os.environ.get('CODEX_HOME',os.environ['HOME']+'/.codex'),HOME=str(L/'user'),
               TMUX_TMPDIR=f'/proc/{os.getpid()}/cwd/.test-tmp/live/tmux')
    # The /proc cwd alias only shortens the socket pathname; all files remain in this worktree.
    primaryenv = dict(env)
    primaryenv.pop('NO_MISTAKES_GATE',None)
    p=subprocess.run(['tmux','-L','fm-lab','-S',env['TMUX_TMPDIR']+'/fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',str(R),'-e','FM_HOME='+str(L),'codex'],env=primaryenv,capture_output=True,text=True)
    (E/'primary-start.log').write_text(p.stdout+p.stderr+'exit='+str(p.returncode))
    assert p.returncode==0
    env['TMUX']=call(['tmux','-L','fm-lab','-S',env['TMUX_TMPDIR']+'/fm-lab','display-message','-p','-t','primary','#{socket_path},#{pid},0'],check=True).stdout.strip()
    call(['bash',R/'bin/fm-capacity.sh','--json'],check=True)
    launch('--dry-run')
    launch('--list-prepared')
    launch('--steps-only')
    call(['bash',R/'bin/fm-tasks-axi.sh','ready'],check=True)
    assert not (L/'data/ai/slice-steps.log').exists(), 'observation filed prep'
    catalog=(L/'data/slices/catalog.json').read_text()
    write(pathlib.Path('data/slices/catalog.json'),'{"slices":[]}')
    p=launch(); assert 'unranked=help,j01,ai' in p.stdout and not (L/'data/ai/slice-steps.log').exists(), p.stdout
    write(pathlib.Path('data/slices/catalog.json'),'broken json')
    p=launch(); assert p.returncode!=0 and not (L/'data/ai/slice-steps.log').exists(), p.stdout
    write(pathlib.Path('data/slices/catalog.json'),catalog)
    write(pathlib.Path('config/lane-capacity'),'0 0\n')
    p=launch(); assert 'no capacity' in p.stdout and not (L/'data/ai/slice-steps.log').exists(), p.stdout
    write(pathlib.Path('config/lane-capacity'),'1 0\n')
    # Fault injection changes only the disposable home's capacity immediately before real spawn.
    write(pathlib.Path('capacity-race'), '#!/bin/bash\nprintf "0 0\\n" > "$FM_HOME/config/lane-capacity"\nexec bash '+shlex.quote(str(R/'bin/fm-spawn.sh'))+' "$@"\n')
    (L/'capacity-race').chmod(0o700)
    env['FM_AUTOLAUNCH_SPAWN_BIN']=str(L/'capacity-race')
    p=launch()
    assert 'prep-pending ai' in p.stdout and not list((L/'state').glob('*.meta')),p.stdout
    assert not list((L/'state/spawn-deferred/queue').glob('*')), 'prep entered durable deferred queue'
    assert 'launched|relaunched' not in (L/'state/autolaunch.log').read_text()
    shutil.copyfile(L/'data/ai/slice-steps.log',E/'race-pending-receipts.jsonl')
    shutil.copyfile(L/'state/autolaunch.log',E/'race-autolaunch.log')
    write(pathlib.Path('config/lane-capacity'),'1 0\n')
    write(pathlib.Path('config/autolaunch-steps'),'act ai\n')
    write(pathlib.Path('data/help/prep.md'),'Ready to build\n')
    write(pathlib.Path('data/help/brief.md'),'Delivery contract: mode=local-only\nPrepared help outcome\n')
    write(pathlib.Path('data/help/autolaunch-prep'),'project=proj\nkind=ship\nmode=local-only\nyolo=off\nunknown=refuse\n')
    p=launch(); assert not list((L/'state').glob('*.meta')), p.stdout
    assert 'launched|relaunched' not in (L/'state/autolaunch.log').read_text()
    p=launch('--step-dispatch','ai','','','ai:initial-prep:1')
    assert p.returncode!=0 and 'prepared-item-exists' in p.stdout,p.stdout
    shutil.copyfile(L/'data/ai/slice-steps.log',E/'prepared-sibling-pending-receipts.jsonl')
    for p in (L/'data/help').iterdir(): p.unlink()
    write(pathlib.Path('config/autolaunch-steps'),'off\n')
    env.pop('FM_AUTOLAUNCH_SPAWN_BIN')
    p=launch()
    assert ('prep-started ai' in p.stdout or 'already-prepping ai' in p.stdout),p.stdout
    assert [x.name for x in (L/'state').glob('*.meta')]==['ai.meta']
    assert 'kind=scout' in (L/'state/ai.meta').read_text()
    assert (L/'data/ai/prep-ship-brief.md').read_text()=="## Captain's intent\nPrepare a plan to add a greeting to this disposable project.\n## Firstmate spec\nPreserve this outcome.\n"
    assert (L/'data/ai/autolaunch-prep').read_text()=='project=proj\nkind=ship\nmode=local-only\nyolo=off\n'
    assert (L/'state/autolaunch.log').read_text().count('launched|relaunched ai initial-prep:1')==1
    print(p.stdout,flush=True)
    for path in (L/'state').glob('*.meta'):
        (E/(path.name+'.txt')).write_text(path.read_text())
    for name in ('slice-steps.log','brief.md','prep-ship-brief.md','autolaunch-prep'):
        p=L/'data/ai'/name
        if p.exists(): (E/('ai-'+name+'.txt')).write_bytes(p.read_bytes())
    if (L/'state/autolaunch.log').exists(): shutil.copyfile(L/'state/autolaunch.log',E/'autolaunch.log')
    call(['tmux','-L','fm-lab','-S',env['TMUX_TMPDIR']+'/fm-lab','list-windows','-t','primary'])
    call(['tmux','-L','fm-lab','-S',env['TMUX_TMPDIR']+'/fm-lab','capture-pane','-p','-t','primary','-S','-100'])
    if (L/'state/ai.meta').exists():
        call(['tmux','-L','fm-lab','-S',env['TMUX_TMPDIR']+'/fm-lab','capture-pane','-p','-t','primary:fm-ai','-S','-100'])
    p=launch(); assert 'no capacity' in p.stdout and (L/'state/autolaunch.log').read_text().count('launched|relaunched ai initial-prep:1')==1,p.stdout
    call(['bash',R/'bin/fm-tasks-axi.sh','show','ai','--full'],check=True)
    (E/'live-assertions.txt').write_text('All live assertions passed: observation has no prep effects; missing catalogue ranks never use row order; corrupt catalogue refuses; zero capacity has no effect; lost spawn capacity returns pending without queue or witness; newly prepared sibling blocks leased/direct retry; later retry starts exactly AI scout with one witness; original ship brief and launch contract preserved; repeated pass adds no launch.\n')
finally:
    if env.get('TMUX_TMPDIR'):
        call(['tmux','-L','fm-lab','-S',env['TMUX_TMPDIR']+'/fm-lab','kill-server'])
    if L.exists():
        for root,dirs,files in os.walk(L): os.chmod(root,0o700)
        for attempt in range(10):
            try:
                shutil.rmtree(L); break
            except FileNotFoundError: break
            except OSError:
                time.sleep(0.3)
        assert not L.exists(), 'lab cleanup did not finish'
