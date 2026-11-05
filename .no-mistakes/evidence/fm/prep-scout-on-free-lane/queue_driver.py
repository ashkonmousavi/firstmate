import os, json, pathlib, subprocess, shutil, time, shlex
R = pathlib.Path.cwd()
E = pathlib.Path('~/.no-mistakes/evidence/01M6P2F9E2VSTH4R8X14HYZXZV')
L = R / '.test-tmp/queue'
L.mkdir()
env = dict(os.environ)
for k in list(env):
    if k.startswith('FM_') or k in ('TMUX', 'TMUX_PANE', 'CLAUDECODE'):
        env.pop(k)
def call(args, timeout=90, check=False):
    p = subprocess.run([str(x) for x in args], env=env, cwd=R, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    with (E/'queue-cli.log').open('a') as f:
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
    env.update(FM_HOME=str(L),TMPDIR=str(R/'.test-tmp'),FM_BACKEND='tmux')
    write(pathlib.Path('config/lane-capacity'),'0 0\n')
    p=call(['bash',R/'bin/fm-spawn.sh','ai',L/'projects/proj','--scout','--harness','codex','--model','gpt-6.1-sol'])
    assert p.returncode==75,p.stdout
    queue=list((L/'state/spawn-deferred/queue').glob('*'))
    assert len(queue)==1
    for f in queue: shutil.copyfile(f,E/'ordinary-deferred-record.txt')
    p=call(['bash',R/'bin/fm-spawn.sh','j01',L/'projects/proj','--scout','--no-defer-queue','--harness','codex','--model','gpt-6.1-sol'])
    assert p.returncode==75,p.stdout
    assert len(list((L/'state/spawn-deferred/queue').glob('*')))==1
    assert not list((L/'state').glob('*.meta'))
    (E/'queue-assertions.txt').write_text('Real fm-spawn with real capacity=0: ordinary scout returns 75 and records one deferred request; --no-defer-queue scout returns 75 and adds no queue record or task metadata. All assertions passed.\n')
finally:
    if L.exists():
        for root,dirs,files in os.walk(L): os.chmod(root,0o700)
        shutil.rmtree(L)
