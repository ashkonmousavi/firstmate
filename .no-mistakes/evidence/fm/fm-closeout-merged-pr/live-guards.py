import os,pathlib,subprocess,shutil,json,traceback
R=pathlib.Path.cwd();E=pathlib.Path('~/.no-mistakes/evidence/01M64E68ZHNYGVBAFEHRS8HAMS');H=R/'.closeout-guards'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_'))};env.update(FM_HOME=str(H),FM_INACTIVE_RECONCILE_BUDGET_SECS='30')
log=(E/'live-guards.log').open('w',buffering=1);results=[];holders=[]
def run(args):
    p=subprocess.run(list(map(str,args)),cwd=R,env=env,text=True,capture_output=True,timeout=40)
    log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n');assert p.returncode==0
    return p.stdout

def task(id):
    run([R/'bin/fm-tasks-axi.sh','add',id,'Validate '+id,'--body','https://github.com/cli/cli/pull/1']);run([R/'bin/fm-tasks-axi.sh','start',id])
def state(id):return run([R/'bin/fm-tasks-axi.sh','show',id,'--full'])
def scan():run([R/'bin/fm-inactive-reconcile.sh','scan','--startup'])
def snapshot(label):
    for name in ['data/backlog.md','data/x-reconcile.json']:
        p=H/name
        if p.exists():shutil.copyfile(p,E/(label+'-'+p.name));log.write('PERSISTED '+name+'\n'+p.read_text()+'\n')
try:
    run([R/'bin/fm-lab-home.sh','create',H]);(H/'.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\ndone_keep=100\n')
    task('uncertain-worker');meta=H/'state/uncertain-worker.meta';meta.write_text('kind=scout\nharness=codex\nworktree='+str(H/'not-created')+'\npr=https://github.com/cli/cli/pull/1\n')
    s=run([R/'bin/fm-crew-state.sh','uncertain-worker']);assert s.startswith('state: unknown ')
    scan();assert '  state: in_flight\n' in state('uncertain-worker');assert not list((H/'state/terminal-outcomes').glob('backlog-pr-*.closed'))
    snapshot('unknown-worker-retained');meta.unlink();scan();assert '  state: done\n' in state('uncertain-worker');snapshot('removed-worker-closed')
    results.append(dict(name='An unknown worker state prevents closeout; removing its metadata permits closure',result='pass',live=True,evidence='live-guards.log',reason=''))
    for kind in ['control','meta']:
        id='locked-'+kind;task(id);lock=H/'state'/('.'+kind+'-'+id+'.lock')
        script='source "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" || exit 1; echo acquired; read -r release; fm_lock_release "$2"'
        p=subprocess.Popen(['bash','-c',script,'guard',str(R),str(lock)],env=env,cwd=R,text=True,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE);holders.append(p)
        assert p.stdout.readline().strip()=='acquired';log.write('Held real '+kind+' lock in owned subprocess '+str(p.pid)+'\n')
        scan();assert '  state: in_flight\n' in state(id);snapshot(kind+'-lock-retained')
        out,err=p.communicate('release\n',timeout=10);log.write(out+err+'lock_holder_exit='+str(p.returncode)+'\n');assert p.returncode==0
        scan();assert '  state: done\n' in state(id);snapshot(kind+'-lock-released')
    results.append(dict(name='Held control and metadata locks independently prevent closure; releasing each permits closure',result='pass',live=True,evidence='live-guards.log',reason=''))
except Exception as e:
    log.write(traceback.format_exc());results.append(dict(name='Worker-state and control/meta lock guards',result='fail',live=True,evidence='live-guards.log',reason=str(e)))
finally:
    for p in holders:
        if p.poll() is None:p.communicate('release\n',timeout=10)
    shutil.rmtree(H,ignore_errors=True);(E/'guards-scenarios.json').write_text(json.dumps(results,indent=2)+'\n');log.close()
if any(x['result']!='pass' for x in results):raise SystemExit(1)
