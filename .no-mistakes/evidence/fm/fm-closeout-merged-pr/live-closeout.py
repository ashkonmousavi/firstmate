import os, sys, subprocess, pathlib, json, time, shutil, fcntl, signal, traceback
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M64E68ZHNYGVBAFEHRS8HAMS')
W=ROOT/'.closeout-live'
BASE={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
LOG=(E/'live-closeout.log').open('w', buffering=1)
RESULT=[]
def log(s): print(s, file=LOG); print(s, flush=True)
def run(args, home=None, budget=30, check=True):
    env=BASE.copy()
    if home: env.update(FM_HOME=str(home), FM_INACTIVE_RECONCILE_BUDGET_SECS=str(budget))
    args=list(map(str,args)); p=subprocess.run(args,cwd=home or ROOT,env=env,text=True,capture_output=True,timeout=45)
    log('$ '+ ' '.join(args)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode))
    if check and p.returncode: raise AssertionError('command failed '+str(args))
    return p

def home(name):
    h=W/name
    run([ROOT/'bin/fm-lab-home.sh','create',h])
    (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 100\n')
    return h

def task(h,id,body):
    run([ROOT/'bin/fm-tasks-axi.sh','add',id,'Validation '+id,'--body',body],h)
    run([ROOT/'bin/fm-tasks-axi.sh','start',id],h)

def state(h,id):
    p=run([ROOT/'bin/fm-tasks-axi.sh','show',id,'--full'],h)
    return next(x.split(':',1)[1].strip() for x in p.stdout.splitlines() if x.startswith('  state:'))

def scan(h,budget=30):
    t=time.monotonic(); run([ROOT/'bin/fm-inactive-reconcile.sh','scan','--startup'],h,budget)
    log('elapsed_seconds='+str(round(time.monotonic()-t,3)))

def doc(h): return json.loads((h/'data/x-reconcile.json').read_text())
def snapshot(h,label):
    for p in [h/'data/backlog.md',h/'data/x-reconcile.json',h/'state/backlog-pr-cursor',*sorted((h/'state/terminal-outcomes').glob('backlog-pr-*.closed'))]:
        if p.exists():
            dest=E/(label+'-'+p.name); shutil.copyfile(p,dest)
            log('PERSISTED '+str(p.relative_to(h))+'\n'+p.read_text())
def scenario(name,fn):
    log('\nSCENARIO '+name)
    try: fn(); RESULT.append(dict(name=name,result='pass',live=True,evidence='live-closeout.log',reason=''))
    except Exception as e:
        log(traceback.format_exc()); RESULT.append(dict(name=name,result='fail',live=True,evidence='live-closeout.log',reason=str(e)))

try:
    W.mkdir()
    oracle={}
    for n in [1,14867,14846]:
        p=run(['gh','pr','view',str(n),'-R','cli/cli','--json','state,mergedAt,closedAt,url'])
        oracle[n]=json.loads(p.stdout)
    (E/'github-oracle.json').write_text(json.dumps(oracle,indent=2)+'\n')
    assert oracle[1]['state']=='MERGED' and oracle[14867]['state']=='CLOSED' and oracle[14846]['state']=='OPEN'
    merged=oracle[1]['url']; closed=oracle[14867]['url']; opened=oracle[14846]['url']; bad='https://github.com/cli/cli/pull/999999999'
    def close_four():
        h=home('four-merged')
        for i in range(4): task(h,'merged-'+str(i),merged)
        seed={'schema':'x-reconcile.v1','written_at':7,'items':[{'id':'preserve','home':'server','finding':'place','source':'stage-age','observed_at':7}]}
        (h/'data/x-reconcile.json').write_text(json.dumps(seed))
        scan(h)
        for i in range(4): assert state(h,'merged-'+str(i))=='done'
        d=doc(h); mine=[x for x in d['items'] if x['source']=='inactive-reconcile']
        assert len(mine)==4 and all(x['finding']=='fix' and x['home']=='main' and isinstance(x['observed_at'],int) and x['detail']=='closed: PR 1 merged '+oracle[1]['mergedAt'] for x in mine),d
        assert d['written_at']==7 and seed['items'][0] in d['items']
        assert len(list((h/'state/terminal-outcomes').glob('backlog-pr-*.closed')))==4
        snapshot(h,'four-merged')
        run([ROOT/'bin/fm-tasks-axi.sh','reopen','merged-0'],h);run([ROOT/'bin/fm-tasks-axi.sh','start','merged-0'],h)
        scan(h); assert state(h,'merged-0')=='in_flight'
        snapshot(h,'once-after-reopen')
    scenario('Four merged records close with dated MAIN board evidence; a reopened receipted task stays open',close_four)
    def guards():
        h=home('guards'); padding='background '*500
        for id,body in [('closed',closed),('open',opened),('mixed',merged+' '+padding+opened),('hidden',padding+merged),('none','No PR yet'),('held',merged),('unreadable',bad)]: task(h,id,body)
        run([ROOT/'bin/fm-tasks-axi.sh','hold','held','--reason','validation captain call','--kind','captain'],h)
        scan(h)
        for id in ['closed','hidden']: assert state(h,id)=='done'
        for id in ['open','mixed','none','held','unreadable']: assert state(h,id)=='in_flight'
        mine={x['id']:x for x in doc(h)['items']}
        assert mine['closed']['detail']=='closed: PR 14867 closed '+oracle[14867]['closedAt']
        assert mine['unreadable']['finding']=='unknown'
        assert all(id not in mine for id in ['open','mixed','none','held'])
        snapshot(h,'guards')
    scenario('Closed PRs close, complete long bodies retain OPEN references, and held or unreadable tasks remain in flight',guards)
    def short():
        for budget in [1,2]:
            h=home('budget-'+str(budget));task(h,'a-unreadable',bad);task(h,'b-merged',merged)
            progress=[]
            for i in range(6):
                scan(h,budget); progress.append((h/'state/backlog-pr-cursor').read_text().strip() if (h/'state/backlog-pr-cursor').exists() else 'absent')
                if state(h,'b-merged')=='done': break
            assert len(set(progress)-{'absent'})>=2,('cursor did not advance',budget,progress)
            if state(h,'b-merged')!='done':
                mine={x['id']:x for x in doc(h)['items']}
                assert mine['b-merged']['finding']=='unknown' and mine['a-unreadable']['finding']=='unknown',mine
                snapshot(h,'deferred-budget-'+str(budget))
                scan(h,30)
                assert state(h,'b-merged')=='done'
            assert state(h,'a-unreadable')=='in_flight'
            log('saved cursor sequence '+json.dumps(progress));snapshot(h,'budget-'+str(budget))
    scenario('Budgets 1 and 2 save visit progress and unknown findings; deferred merged work closes with sufficient time',short)
    def recovery():
        h=home('recovery');task(h,'interrupted',merged)
        # A real exclusive board lock prevents publication while real task closure can commit.
        lock=(h/'data/x-reconcile.json.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX)
        scan(h)
        assert state(h,'interrupted')=='done'
        receipts=list((h/'state/terminal-outcomes').glob('backlog-pr-*.closed'));assert len(receipts)==1
        assert 'status=closing\n' in receipts[0].read_text()
        snapshot(h,'interrupted-before-recovery')
        fcntl.flock(lock,fcntl.LOCK_UN);lock.close()
        scan(h)
        assert 'status=closed\n' in receipts[0].read_text()
        mine=[x for x in doc(h)['items'] if x['id']=='interrupted']
        assert len(mine)==1 and mine[0]['detail']=='closed: PR 1 merged '+oracle[1]['mergedAt']
        snapshot(h,'interrupted-recovered')
    scenario('Publication blocked by the board lock leaves a closing intent; next scan recovers dated evidence',recovery)
    def mate():
        main=home('parent');h=home('mate')
        (h/'.fm-secondmate-home').write_text('mate\n')
        (h/'.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home='+str(main)+'\n')
        task(h,'mate-merged',merged);scan(h)
        assert state(h,'mate-merged')=='done' and not (h/'data/x-reconcile.json').exists()
        snapshot(h,'secondmate')
    scenario('A secondmate closes its own merged task without writing a board JSON file',mate)
finally:
    (E/'live-scenarios.json').write_text(json.dumps(RESULT,indent=2)+'\n')
    shutil.rmtree(W,ignore_errors=True)
    LOG.close()
if any(x['result']!='pass' for x in RESULT): sys.exit(1)
