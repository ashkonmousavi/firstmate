import os, pathlib, subprocess, tempfile, shutil, json, time, signal, hashlib
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M63C7BBG117KTXSCWYQZZ9EG')
log=(E/'live-publication-transcript.log').open('w',buffering=1)
results=[]; labs=[]
base={k:v for k,v in os.environ.items() if not k.startswith('FM_') and not k.startswith('TASKS_AXI_') and k not in ('TMUX','TMUX_TMPDIR')}
base['TMPDIR']='/tmp'
def run(args,home=None,extra=None,ok=(0,),timeout=45,stdin=None):
    env=base.copy()
    if home: env['FM_HOME']=str(home)
    if extra: env.update(extra)
    cmd=[str(x) for x in args]
    log.write('$ '+ ' '.join(cmd)+('\nFM_HOME='+str(home) if home else '')+'\n')
    p=subprocess.run(cmd,cwd=ROOT,env=env,input=stdin,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
    log.write(p.stdout+'\nexit='+str(p.returncode)+'\n')
    if ok is not None: assert p.returncode in ok, (cmd,p.returncode,p.stdout)
    return p

def home():
    p=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.')); labs.append(p)
    run(['bin/fm-lab-home.sh','create',p])
    (p/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (p/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    return p

def axi(h,*args,**kw): return run(['bin/fm-tasks-axi.sh',*args],h,**kw)
def evaluate(h):
    return run(['bash','-c','. bin/fm-hold-release-lib.sh; fm_hold_release_evaluate "$FM_HOME/state"'],h)
def decisions(h,id):
    return run(['bash','-c','. bin/fm-classify-lib.sh; status_open_decisions "$FM_HOME/state/$1.status"','_',id],h).stdout

def snapshot(h,path,label):
    data=(h/path).read_text(); log.write('PERSISTED '+str(h/path)+'\n'+data+'\n')
    (E/label).write_text(data); return data

def scenario(name,fn):
    log.write('\nSCENARIO '+name+'\n')
    try:
        fn(); results.append({'name':name,'result':'pass'})
    except Exception as ex:
        log.write('FAIL '+repr(ex)+'\n'); results.append({'name':name,'result':'fail','error':repr(ex)})

try:
    def publication():
        for writer in ('tasks','captain'):
            h=home(); a=h/'ready-a'; b=h/'ready-b'; a.touch()
            def hold(condition):
                if writer=='tasks':
                    return axi(h,'hold','t1','--reason','disposable publication failure','--kind','external','--release-on',condition,ok=None)
                return run(['bin/fm-captain-hold.sh','hold','t1','--title','disposable test question','--reason','disposable publication failure','--repo','demo','--release-on',condition],h,ok=None)
            if writer=='tasks': axi(h,'add','t1','disposable task','--repo','demo')
            # An actual filesystem failure prevents derived-cache publication after the real backend commit.
            cache=h/'state/hold-releases'; cache.write_text('injected disposable cache obstruction\n')
            p=hold('marker:'+str(a)); assert p.returncode!=0
            shown=axi(h,'show','t1').stdout
            assert '  held: yes' in shown and 'hold_release_on: "marker:'+str(a)+'"' in shown
            cache.unlink()
            assert evaluate(h).stdout.strip()=='hold condition met: t1 marker:'+str(a)
            assert 'hold-release-t1' in decisions(h,'t1')
            # Keep stale episode A while the real backend commits B and cache publication fails.
            backup=h/'state/cache-before-rehold'; cache.rename(backup); cache.write_text('injected disposable cache obstruction\n')
            p=hold('marker:'+str(b)); assert p.returncode!=0
            cache.unlink(); backup.rename(cache)
            assert not evaluate(h).stdout.strip()
            assert not decisions(h,'t1')
            assert 'condition=marker:'+str(b) in (cache/'t1').read_text()
            b.touch(); assert evaluate(h).stdout.strip()=='hold condition met: t1 marker:'+str(b)
            if writer=='captain':
                answer=h/'synthetic-answer.txt'; answer.write_text('Synthetic fixture answer: resume this disposable task.\n')
                run(['bin/fm-captain-hold.sh','answer','t1','--release','--decision-file',answer],h)
            else: axi(h,'unhold','t1')
            assert not decisions(h,'t1')
            snapshot(h,'state/t1.status','publication-'+writer+'-decisions.txt')
    scenario('Both hold writers recover real cache-publication failures after initial commit and re-hold, then close decisions on release',publication)
finally:
    for p in labs: shutil.rmtree(p)
    log.write('CLEANUP: all disposable lab homes removed.\n')
    (E/'live-publication-results.json').write_text(json.dumps(results,indent=2)+'\n')
    log.close()
print(json.dumps(results,indent=2))
raise SystemExit(1 if any(x['result']=='fail' for x in results) else 0)
