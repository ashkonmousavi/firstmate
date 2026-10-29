import os, pathlib, subprocess, tempfile, shutil, json, time, signal, hashlib
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M63C7BBG117KTXSCWYQZZ9EG')
log=(E/'live-transcript.log').open('w',buffering=1)
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
    h=home()
    def guard():
        axi(h,'add','guard','guarded task','--repo','demo')
        for opts in [[],['--kind','external'],['--release-on','marker:relative'],['--release-on','pr:cli/cli#0']]:
            axi(h,'hold','guard','--reason','waiting',*opts,ok=(2,))
            assert '  held: no' in axi(h,'show','guard').stdout
        axi(h,'hold','guard','--reason','dated','--kind','external','--until','2099-01-01')
        axi(h,'unhold','guard')
        axi(h,'hold','guard','--reason','parked','--kind','parked')
        axi(h,'unhold','guard')
    scenario('Undated external and malformed conditions refuse before mutation; dated and parked exemptions work',guard)
    def pr():
        run(['gh-axi','pr','view','1','-R','cli/cli'])
        for id,number in [('merged',1),('open',14858),('unknown',2147483647)]:
            axi(h,'add',id,id+' public PR condition','--repo','demo')
            axi(h,'hold',id,'--reason','waiting for public PR','--kind','external','--release-on',f'pr:cli/cli#{number}')
        out=evaluate(h).stdout
        assert out.strip()=='hold condition met: merged pr:cli/cli#1',out
        assert 'hold-release-merged' in decisions(h,'merged')
        assert not decisions(h,'open') and not decisions(h,'unknown')
        assert '  held: yes' in axi(h,'show','merged').stdout
        assert not evaluate(h).stdout.strip()
        assert 'hold-release-merged' in decisions(h,'merged')
        snapshot(h,'state/.wake-queue','pr-wake-queue.txt')
        snapshot(h,'state/merged.status','pr-open-decision.txt')
    scenario('A PR merged over 24 hours ago opens one persistent decision; open and missing PRs stay waiting',pr)
    def markers():
        a=h/'activated-a'; b=h/'activated-b'
        axi(h,'add','marker','activation condition','--repo','demo')
        axi(h,'hold','marker','--reason','awaiting activation','--kind','external','--release-on',f'marker:{a}')
        assert 'marker ' not in evaluate(h).stdout
        a.touch(); assert f'hold condition met: marker marker:{a}' in evaluate(h).stdout
        assert not evaluate(h).stdout.strip()
        axi(h,'hold','marker','--reason','new activation','--kind','external','--release-on',f'marker:{b}')
        assert not decisions(h,'marker')
        # Deliberately lose only the disposable derived cache; the committed native hold remains authoritative.
        (h/'state/hold-releases/marker').unlink()
        assert not evaluate(h).stdout.strip()
        assert 'condition=marker:'+str(b) in (h/'state/hold-releases/marker').read_text()
        b.touch(); assert f'hold condition met: marker marker:{b}' in evaluate(h).stdout
        axi(h,'unhold','marker'); assert not decisions(h,'marker')
        assert not (h/'state/hold-releases/marker').exists()
        axi(h,'hold','marker','--reason','remove after ready','--release-on',f'marker:{b}')
        evaluate(h); axi(h,'rm','marker'); assert not evaluate(h).stdout.strip()
        assert not (h/'state/hold-releases/marker').exists() and not decisions(h,'marker')
        snapshot(h,'state/marker.status','marker-lifecycle.txt')
    scenario('Marker activation, re-hold cache recovery, release, and deleted-task reconciliation preserve decision lifecycle',markers)
    def transfer():
        dest=home()
        axi(h,'add','travel','transferred hold','--repo','demo')
        axi(h,'hold','travel','--reason','waiting merge','--kind','external','--release-on','pr:cli/cli#1')
        axi(h,'mv','travel','--to',dest/'data/backlog.md')
        assert not (dest/'state/hold-releases/travel').exists()
        assert 'hold_release_on: "pr:cli/cli#1"' in axi(dest,'show','travel').stdout
        assert evaluate(dest).stdout.strip()=='hold condition met: travel pr:cli/cli#1'
        assert 'hold-release-travel' in decisions(dest,'travel')
        assert not evaluate(dest).stdout.strip()
        snapshot(dest,'state/travel.status','transferred-hold-decision.txt')
    scenario('Moving a held task to another home preserves its PR condition and destination decision',transfer)
    def watcher():
        w=home(); flag=w/'activated'; flag.touch()
        for id,cond in [('watch-marker','marker:'+str(flag)),('watch-pr','pr:cli/cli#1')]:
            axi(w,'add',id,id,'--repo','demo')
            axi(w,'hold',id,'--reason','ready event','--kind','external','--release-on',cond)
        # Avoid unrelated optional summary refresh while driving the real watcher.
        (w/'state/home-summary.json').write_text('{}\n')
        out=run(['bin/fm-watch.sh'],w,extra={'FM_POLL':'1','FM_CHECK_INTERVAL':'1','FM_SIGNAL_GRACE':'0'},timeout=45).stdout
        assert 'check: hold-release: hold condition met:' in out,out
        queue=snapshot(w,'state/.wake-queue','watcher-wake-queue.txt')
        assert 'hold condition met: watch-pr pr:cli/cli#1' in queue
        assert 'hold condition met: watch-marker marker:' in queue
        assert 'hold-release-watch-pr' in decisions(w,'watch-pr')
        assert 'hold-release-watch-marker' in decisions(w,'watch-marker')
    scenario('The real watcher evaluates merged PR and activation conditions and queues both wakes',watcher)
    # The runbook authorizes a marked throwaway home and its private tmux socket.
    parent=home(); mate=home()
    socket=parent/'tmux'; socket.mkdir()
    tenv={'TMUX_TMPDIR':str(socket),'FM_SEND_SETTLE':'0','FM_SEND_SLEEP':'0','FM_SEND_RETRIES':'1'}
    run(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','fm-lab-walk','-n','fm-mate','-x','100','-y','30','-c',ROOT],parent,tenv)
    try:
        (mate/'.fm-secondmate-home').write_text('mate\n')
        (mate/'.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={parent}\n')
        (parent/'state/mate.meta').write_text(f'kind=secondmate\nharness=claude\nbackend=tmux\nwindow=fm-lab-walk:fm-mate\nhome={mate}\nworktree={ROOT}\n')
        briefs=mate/'data/walk-briefs'; briefs.mkdir(); brief=briefs/'brief.md'
        brief.write_text('Exercise the disposable test checkpoint and report the observed outcome.\n')
        release='0dc10300c6ac2abcadefc8f9661c91f63650528a'
        def carrier_guards():
            for bad in ['relative.md',str(parent/'config/forbidden.md')]:
                run(['bin/fm-walk-request.sh','--brief',bad,'--release',release,'--walks','live-walk'],mate,ok=(2,))
            assert not (parent/'state/mate.status').exists()
        scenario('The walk carrier refuses relative and private briefs without publishing a request',carrier_guards)
        def walk_missing():
            out=run(['bin/fm-walk-request.sh','--brief',brief,'--release',release,'--walks','live-walk','--bot','LabWalker'],mate).stdout
            assert 'once-key=live-walk@'+release in out
            snapshot(parent,'state/mate.status','walk-parent-channel.txt')
            run(['bin/fm-walk-request-check.sh','arm'],parent,tenv)
            assert (parent/'state/walk-request.check-trust').exists()
            assert not (parent/'data/bin/fm-grok-bot-dispatch.sh').exists()
            for _ in range(5):
                run(['bin/fm-walk-request-check.sh','check'],parent,tenv)
                msgs=list((parent/'state/mate.inbox').glob('*.msg'))
                if msgs: break
            assert msgs,'real fm-send must return the unavailable-dispatcher outcome to the mate inbox'
            message=msgs[0].read_text(); log.write('RETURNED INBOX RECORD\n'+message+'\n')
            assert 'no walker dispatcher' in message and 'walk was not dispatched' in message,message
            (E/'walk-returned-inbox.txt').write_text(message)
            count=len(msgs)
            for _ in range(3): run(['bin/fm-walk-request-check.sh','check'],parent,tenv)
            assert len(list((parent/'state/mate.inbox').glob('*.msg')))==count
            run(['tmux','-L','fm-lab','capture-pane','-p','-t','fm-lab-walk:fm-mate'],parent,tenv)
            run(['bin/fm-walk-request-check.sh','disarm'],parent,tenv)
        scenario('A mate request reaches the registered check and a missing-dispatcher outcome returns once through the real steering inbox',walk_missing)
    finally:
        run(['tmux','-L','fm-lab','kill-server'],parent,tenv,ok=None)
finally:
    for p in labs:
        shutil.rmtree(p)
    log.write('CLEANUP: all disposable lab homes removed; private tmux server stopped.\n')
    (E/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    log.close()
print(json.dumps(results,indent=2))
raise SystemExit(1 if any(x['result']=='fail' for x in results) else 0)
