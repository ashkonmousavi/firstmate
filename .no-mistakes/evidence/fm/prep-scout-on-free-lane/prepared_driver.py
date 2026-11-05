import os, json, pathlib, subprocess, shutil, time, shlex
R = pathlib.Path.cwd()
E = pathlib.Path('~/.no-mistakes/evidence/01M6P2F9E2VSTH4R8X14HYZXZV')
L = R / '.test-tmp/prepared'
L.mkdir()
env = dict(os.environ)
for k in list(env):
    if k.startswith('FM_') or k in ('TMUX', 'TMUX_PANE', 'CLAUDECODE'):
        env.pop(k)
def call(args, timeout=90, check=False):
    p = subprocess.run([str(x) for x in args], env=env, cwd=R, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    with (E/'prepared-cli.log').open('a') as f:
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
               TMUX_TMPDIR=f'/proc/{os.getpid()}/cwd/.test-tmp/prepared/tmux')
    # The /proc cwd alias only shortens the socket pathname; all files remain in this worktree.
    primaryenv = dict(env)
    primaryenv.pop('NO_MISTAKES_GATE',None)
    p=subprocess.run(['tmux','-L','fm-lab','-S',env['TMUX_TMPDIR']+'/fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',str(R),'-e','FM_HOME='+str(L),'codex'],env=primaryenv,capture_output=True,text=True)
    (E/'primary-start.log').write_text(p.stdout+p.stderr+'exit='+str(p.returncode))
    assert p.returncode==0
    env['TMUX']=call(['tmux','-L','fm-lab','-S',env['TMUX_TMPDIR']+'/fm-lab','display-message','-p','-t','primary','#{socket_path},#{pid},0'],check=True).stdout.strip()
    write(pathlib.Path('config/lane-capacity'),'2 0\n')
    write(pathlib.Path('data/help/brief.md'),'# Task\nRespond with PREPARED_HELP_LIVE and wait. Do not modify any file.\nDelivery contract: mode=local-only\nShip branch: fm/help\n')
    write(pathlib.Path('data/help/prep.md'),'Preparation complete. Run the existing prepared outcome.\n')
    write(pathlib.Path('data/help/autolaunch-prep'),'project=proj\nkind=ship\nmode=local-only\nyolo=off\n')
    p=launch()
    assert [x.name for x in (L/'state').glob('*.meta')]==['help.meta'],p.stdout
    assert 'kind=ship' in (L/'state/help.meta').read_text()
    assert not (L/'data/ai/slice-steps.log').exists(), 'prep scout launched despite prepared work'
    assert 'Prepare this' not in (L/'data/ai/brief.md').read_text()
    call(['bash',R/'bin/fm-capacity.sh','--json'],check=True)
    call(['tmux','-L','fm-lab','-S',env['TMUX_TMPDIR']+'/fm-lab','list-windows','-t','primary'])
    call(['tmux','-L','fm-lab','-S',env['TMUX_TMPDIR']+'/fm-lab','capture-pane','-p','-t','primary:fm-help','-S','-100'])
    shutil.copyfile(L/'state/help.meta',E/'prepared-help.meta.txt')
    shutil.copyfile(L/'state/autolaunch.log',E/'prepared-help-autolaunch.log')
    (E/'prepared-assertions.txt').write_text('Two free lanes, prepared help plus unprepared AI/J-01: real launcher starts only help as ship, leaves one lane free, and creates no initial AI prep receipt. All assertions passed.\n')
finally:
    if env.get('TMUX_TMPDIR'):
        call(['tmux','-L','fm-lab','-S',env['TMUX_TMPDIR']+'/fm-lab','kill-server'])
    if L.exists():
        for root,dirs,files in os.walk(L): os.chmod(root,0o700)
        for attempt in range(10):
            try:
                shutil.rmtree(L); break
            except FileNotFoundError: break
            except OSError: time.sleep(0.3)
        assert not L.exists(), 'lab cleanup did not finish'
