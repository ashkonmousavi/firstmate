import os, json, pathlib, subprocess, shutil, time, shlex
R = pathlib.Path.cwd()
E = pathlib.Path('~/.no-mistakes/evidence/01M6P2F9E2VSTH4R8X14HYZXZV')
L = R / '.test-tmp/negative'
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
    env.update(FM_HOME=str(L),TMPDIR=str(R/'.test-tmp'))
    # Real CLI and capacity; every injected stop is the product's SIGKILL seam.
    original=(L/'data/ai/brief.md').read_text()
    contract=(L/'data/ai/autolaunch-prep').read_text()
    for boundary in ('before:file-prep','after:file-prep','before:launch-prep'):
        env['FM_TEST_SEAM']='1'
        env['FM_AUTOLAUNCH_STEPS_STOP']=boundary
        p=launch(); assert p.returncode!=0, p.stdout
        assert not list((L/'state').glob('*.meta'))
        shutil.copyfile(L/'data/ai/slice-steps.log',E/('crash-'+boundary.replace(':','-')+'.jsonl'))
        env.pop('FM_AUTOLAUNCH_STEPS_STOP')
        write(pathlib.Path('data/ai/prep.md'),'Preparation arrived independently\n')
        write(pathlib.Path('data/ai/autolaunch-prep'),contract+'unknown=refuse\n')
        p=launch(); assert p.returncode==0,p.stdout
        assert (L/'data/ai/brief.md').read_text()==original
        assert not (L/'data/ai/prep-ship-brief.md').exists()
        rows=[json.loads(x) for x in (L/'data/ai/slice-steps.log').read_text().splitlines()]
        latest={x['trigger']:x for x in rows}
        assert all(x['receipt']=='completed' and x.get('superseded_by')=='prep-present' for x in latest.values()),latest
        assert not list((L/'state').glob('*.meta'))
        shutil.copyfile(L/'data/ai/slice-steps.log',E/('retired-'+boundary.replace(':','-')+'.jsonl'))
        (L/'data/ai/slice-steps.log').unlink()
        (L/'data/ai/prep.md').unlink()
        write(pathlib.Path('data/ai/autolaunch-prep'),contract)
    write(pathlib.Path('data/backlog.md'),'## In flight\n## Queued\n## Done\n')
    p=launch(); assert 'nothing-to-prep' in p.stdout,p.stdout
    (E/'crash-assertions.txt').write_text('Real launcher SIGKILL before/after filing and before launch: new own prep retires receipts, restores original ship brief, and never spawns a scout. Empty ready queue reports nothing-to-prep. All assertions passed.\n')
finally:
    if L.exists():
        for root,dirs,files in os.walk(L): os.chmod(root,0o700)
        shutil.rmtree(L)
