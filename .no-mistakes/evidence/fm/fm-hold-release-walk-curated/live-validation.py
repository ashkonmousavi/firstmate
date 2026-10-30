import os, subprocess, pathlib, tempfile, shutil, json, time, datetime, hashlib, base64, traceback
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M653CRY7NAGXTSWXGCEEE7W9')
LOG=(E/('live-corrected-transcript.log' if os.environ.get('LIVE_RECHECK') else 'live-product-transcript.log')).open('w')
RESULTS=[]
LABS=[]
BASE={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('TASKS_AXI') or k in ('TMUX','TMUX_PANE'))}
def log(s):
    LOG.write(s+'\n'); LOG.flush()
def run(args,home=None,ok=(0,),env=None,data=None,timeout=65):
    en=BASE.copy()
    if home:
        en.update(FM_HOME=str(home),TMUX_TMPDIR=str(home/'tmux'),TMUX=str(home/'tmux'/'tmux-1000'/'fm-lab')+',0,0')
    if env: en.update(env)
    log('$ '+('FM_HOME='+str(home)+' ' if home else '')+' '.join(map(str,args)))
    p=subprocess.run(list(map(str,args)),cwd=ROOT,env=en,text=True,input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    log('exit='+str(p.returncode)+'\n'+p.stdout+('STDERR:\n'+p.stderr if p.stderr else ''))
    assert p.returncode in ok,(args,p.returncode,p.stdout,p.stderr)
    return p

def lab(name):
    # Disposable manual-verification fixture, following fm-lab-home's contract.
    h=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.'+name+'.'))
    LABS.append(h)
    run(['bin/fm-lab-home.sh','create',h])
    (h/'tmux').mkdir()
    (h/'config/supervision-host-off').touch()
    (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    return h

def axi(h,*a,**kw):return run(['bin/fm-tasks-axi.sh',*a],h,**kw)
def add(h,i):axi(h,'add',i,'Disposable live-validation '+i,'--repo','demo')
def hold(h,i,condition):axi(h,'hold',i,'--reason','waiting for independently observed event','--kind','external','--release-on',condition)
def sweep(h,**kw):return run(['bin/fm-watch-checkpoint.sh','--seconds','12'],h,ok=(0,124),env={'FM_POLL':'1','FM_CHECK_INTERVAL':'0','FM_HEARTBEAT':'999999','FM_SIGNAL_GRACE':'0',**kw},timeout=30)
def evaluate(h):return run(['bash','-c','. bin/fm-hold-release-lib.sh; fm_hold_release_evaluate "$FM_HOME/state"'],h)
def drain(h):return run(['bin/fm-wake-drain.sh'],h,ok=(0,1)).stdout
def decision(h,i):
    return run(['bash','-c','. bin/fm-classify-lib.sh; status_open_decisions "$1"','_',h/'state'/f'{i}.status'],h).stdout

def scenario(name,fn):
    log('\nSCENARIO: '+name)
    try:
        fn()
        RESULTS.append(dict(name=name,result='pass',live=True,evidence=('live-corrected-transcript.log: ' if os.environ.get('LIVE_RECHECK') else 'live-product-transcript.log: ')+name,reason=''))
        log('OBSERVED RESULT: PASS')
    except Exception as ex:
        RESULTS.append(dict(name=name,result='fail',live=True,evidence=('live-corrected-transcript.log: ' if os.environ.get('LIVE_RECHECK') else 'live-product-transcript.log: ')+name,reason=str(ex)))
        log('OBSERVED RESULT: FAIL '+traceback.format_exc())
    (E/('live-corrected-scenarios.json' if os.environ.get('LIVE_RECHECK') else 'live-scenarios.json')).write_text(json.dumps(RESULTS,indent=2))


def guards():
    h=lab('guard');add(h,'guard')
    for opts in [[],['--kind','external'],['--kind','external','--release-on','pr:bad#0'],['--release-on','marker:relative']]:
        axi(h,'hold','guard','--reason','unstructured wait',*opts,ok=(2,))
        assert '  held: no' in axi(h,'show','guard').stdout
    axi(h,'hold','guard','--reason','dated wait','--until','2099-01-01')
    assert '  hold_until: 2099-01-01' in axi(h,'show','guard').stdout
    axi(h,'hold','guard','--reason','accepted parked exemption','--kind','parked')
    assert '  held: yes' in axi(h,'show','guard').stdout


def marker():
    h=lab('marker');add(h,'activation');hold(h,'activation','marker:'+str(h/'activated'))
    p=sweep(h);assert 'hold condition met' not in p.stdout
    (h/'activated').touch()
    for attempt in range(3):
        p=sweep(h)
        if 'hold condition met: activation marker:' in p.stdout:break
        assert 'check: rearm-resurface' in p.stdout,'only the documented restart recovery may precede this sweep'
    else:raise AssertionError('hold activation never reached the actual watcher sweep')
    assert 'hold-release-activation' in decision(h,'activation')
    first=drain(h);assert 'OPEN DECISIONS' in first and 'hold-release-activation' in first
    assert '  held: yes' in axi(h,'show','activation').stdout
    status_before=(h/'state/activation.status').read_text()
    sweep(h)
    assert (h/'state/activation.status').read_text()==status_before,'must not open the same episode twice'
    with (h/'state/activation.status').open('a') as f:f.write('resolved [key=hold-release-activation] [at=1]: answered: unrelated message\n')
    assert 'hold-release-activation' in decision(h,'activation')
    assert 'hold-release-activation' in drain(h),'draining/restarting must not disposition the hold'
    axi(h,'unhold','activation')
    assert not decision(h,'activation')
    assert '  held: no' in axi(h,'show','activation').stdout
    drain(h)

MERGED='pr:cli/cli#14854'
def merged():
    oracle=json.loads(run(['curl','-fsSL','--max-time','20','https://api.github.com/repos/cli/cli/pulls/14854']).stdout)
    assert oracle['merged'] is True
    age=time.time()-datetime.datetime.fromisoformat(oracle['merged_at'].replace('Z','+00:00')).timestamp()
    assert age>86400,age
    (E/'public-pr-oracle.json').write_text(json.dumps({k:oracle[k] for k in ('number','state','merged','merged_at','html_url')},indent=2))
    log('Independent GitHub REST oracle: merged '+str(round(age/3600,2))+' hours ago')
    h=lab('merged');add(h,'oldmerge');hold(h,'oldmerge',MERGED)
    p=sweep(h);assert 'hold condition met: oldmerge '+MERGED in p.stdout
    assert 'hold-release-oldmerge' in drain(h)
    assert '  held: yes' in axi(h,'show','oldmerge').stdout


def negatives():
    h=lab('negative')
    for i,n,state in [('open','14846','open'),('closed','100','closed')]:
        oracle=json.loads(run(['curl','-fsSL','--max-time','20',f'https://api.github.com/repos/cli/cli/pulls/{n}']).stdout)
        assert oracle['state']==state and not oracle['merged']
        add(h,i);hold(h,i,'pr:cli/cli#'+n)
    add(h,'unavailable');hold(h,'unavailable','pr:cli/cli#999999999')
    evaluate(h)
    for i in ('open','closed','unavailable'):
        assert not decision(h,i)
        assert '  held: yes' in axi(h,'show',i).stdout
    drain(h)


def recover():
    h=lab('recover');add(h,'recover')
    old='marker:'+str(h/'old');new='marker:'+str(h/'new')
    hold(h,'recover',old)
    cache=h/'state/hold-releases/recover'
    cache.unlink()
    (h/'old').touch();evaluate(h)
    assert 'hold-release-recover' in decision(h,'recover'),'native committed hold must rebuild a missing cache'
    stale=cache.read_bytes()
    hold(h,'recover',new)
    cache.write_bytes(stale)
    p=evaluate(h)
    assert not p.stdout and not decision(h,'recover'),'old met A must not wake after committed B'
    assert 'condition='+new in cache.read_text()
    (h/'new').touch();p=evaluate(h);assert 'hold condition met: recover '+new in p.stdout
    axi(h,'hold','recover','--reason','dated disposition','--until','2099-01-01')
    cache.write_bytes(stale)
    assert not evaluate(h).stdout and not decision(h,'recover')
    assert not cache.exists(),'dated re-hold must retire stale release cache'


def transfer():
    for route in ('move','receipt'):
        src=lab('source-'+route);dst=lab('destination-'+route)
        add(src,'travels');hold(src,'travels',MERGED)
        if route=='move':axi(src,'mv','travels','--to',dst/'data/backlog.md')
        else:
            (dst/'AGENTS.md').write_text('Disposable receipt fixture.\n')
            (dst/'bin').mkdir()
            outbox=src/'outbox.md';axi(src,'mv','travels','--to',outbox)
            payload=outbox.read_bytes();digest=hashlib.sha256(payload).hexdigest()
            run(['bin/fm-remote-file.sh','put','state/handoff/sender.outbox.md','1048576',str(len(payload)),digest,'1'],dst,data=payload.decode())
            run(['bin/fm-backlog-receive.sh','state/handoff/sender.outbox.md',str(len(payload)),digest,'1'],dst)
        assert not (dst/'state/hold-releases/travels').exists()
        assert '  hold_release_on: "'+MERGED+'"' in axi(dst,'show','travels').stdout
        p=evaluate(dst);assert 'hold condition met: travels '+MERGED in p.stdout
        assert 'hold-release-travels' in drain(dst)
        assert not evaluate(dst).stdout


def removal():
    h=lab('removed');add(h,'vanishes');hold(h,'vanishes','marker:'+str(h/'met'));(h/'met').touch();evaluate(h)
    assert decision(h,'vanishes')
    axi(h,'rm','vanishes')
    p=axi(h,'show','vanishes',ok=(1,));assert 'code: NOT_FOUND' in p.stdout+p.stderr,'the real backend must report NOT_FOUND'
    evaluate(h)
    assert not (h/'state/hold-releases/vanishes').exists() and not decision(h,'vanishes')


def captain_hold():
    h=lab('captain')
    run(['bin/fm-captain-hold.sh','hold','question','--title','Disposable release-condition question','--reason','await activation','--repo','demo','--release-on','marker:'+str(h/'answer-ready')],h)
    assert '  hold_release_on: "marker:' in axi(h,'show','question').stdout
    (h/'answer-ready').touch();sweep(h)
    assert 'hold-release-question' in drain(h)
    (h/'answer.txt').write_text('Resume the disposable task.\n')
    run(['bin/fm-captain-hold.sh','answer','question','--release','--decision-file',h/'answer.txt'],h)
    assert not decision(h,'question')
    assert '  held: no' in axi(h,'show','question').stdout


def walk_missing():
    main=lab('main');mate=lab('mate')
    (mate/'.fm-secondmate-home').write_text('mate\n')
    (mate/'.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home='+str(main)+'\n')
    (main/'state/mate.meta').write_text('kind=secondmate\nbackend=tmux\nharness=claude\nwindow=fm-lab-walk:mate\nhome='+str(mate)+'\nworktree='+str(mate)+'\n')
    (mate/'data/walk-briefs').mkdir();brief=mate/'data/walk-briefs/brief.md';brief.write_text('Exercise the disposable walk carrier.\n')
    release='8797976169b061d3deed2b93d5e32036d52b8f1c'
    p=run(['bin/fm-walk-request.sh','--brief',brief,'--release',release,'--walks','step','--bot','Walker'],mate)
    corr=next(x.split('=',1)[1] for x in p.stdout.splitlines() if x.startswith('corr='))
    run(['bin/fm-walk-request-check.sh','arm'],main)
    p=run(['bash',main/'state/walk-request.check.sh'],main)
    assert 'dispatcher absent at' in p.stdout,'missing private dependency must be visible'
    inbox=list((main/'state/mate.inbox').glob('*.json')) if (main/'state/mate.inbox').exists() else []
    # The steering inbox format is owned output; retain every actual record byte.
    files=[x for x in (main/'state/mate.inbox').rglob('*') if x.is_file()] if (main/'state/mate.inbox').exists() else []
    for f in files:log('PERSISTED INBOX '+str(f)+'\n'+f.read_text())
    record=(main/'state/walk-requests'/f'{corr}.record').read_text();log('PERSISTED WALK RECORD\n'+record)
    assert 'phase=failed' in record,'the real fm-send must durably return the refusal'
    assert any('MAIN has no walker dispatcher' in f.read_text() for f in files)
    before={str(f):f.read_bytes() for f in files}
    p=run(['bash',main/'state/walk-request.check.sh'],main);assert not p.stdout
    assert before=={str(f):f.read_bytes() for f in files},'repeat sweeps must not duplicate the returned outcome'
    run(['bin/fm-walk-request-check.sh','disarm'],main)
    assert not (main/'state/walk-request.check.sh').exists() and not (main/'state/walk-request.check-trust').exists()


def remote_and_boundary():
    h=lab('remote');(h/'.fm-secondmate-home').write_text('remote-mate\n');(h/'.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=remote\n')
    (h/'data/walk-briefs').mkdir();brief=h/'data/walk-briefs/large.md';content=('A'*65535+'\n');brief.write_text(content)
    cmd=['bin/fm-walk-request.sh','--brief',brief,'--release','8797976169b061d3deed2b93d5e32036d52b8f1c','--walks','large-step','--bot','Walker']
    run(cmd,h)
    channel=h/'state/parent-replies.status';line=channel.read_text();encoded=line.split(' brief64=',1)[1].split(' ',1)[0]
    assert base64.b64decode(encoded)==content.encode() and len(line)>65536
    p=run(['bin/fm-remote-delta-read.sh','state/parent-replies.status','0',hashlib.sha256(b'').hexdigest(),'0'],h)
    header,payload=p.stdout.split('\n\n',1)
    assert 'status=delta' in header and payload==line,'largest allowed brief must travel as one complete typed line'
    log('REMOTE BYTE PROOF: brief=65536 bytes, complete typed channel='+str(len(line.encode()))+' bytes, delta payload identical')
    before=channel.read_bytes()
    brief.write_text('A'*65537);run(cmd,h,ok=(2,));assert channel.read_bytes()==before
    brief.write_bytes(b'\x00secret');run(cmd,h,ok=(2,));assert channel.read_bytes()==before
    secret=h/'config/private.txt';secret.write_text('must not leave this home')
    symlink=h/'data/walk-briefs/escaped.md';symlink.symlink_to(secret)
    run([*cmd[:2],symlink,*cmd[3:]],h,ok=(2,));assert channel.read_bytes()==before
    run([*cmd[:2],secret,*cmd[3:]],h,ok=(2,));assert channel.read_bytes()==before

try:
    for name,fn in [
        ('Undated external and kindless holds refuse missing or malformed conditions; dates and accepted parked exemption work',guards),
        ('Marker activation wakes through the watcher once, persists in OPEN DECISIONS, and closes only after disposition',marker),
        ('A real GitHub PR merged more than 24 hours ago produces a durable disposition decision',merged),
        ('Open, closed-unmerged, and failed PR lookups leave holds waiting without false readiness',negatives),
        ('Lost or stale caches recover from the committed hold and never reuse a previous condition',recover),
        ('Native task moves and uploaded remote receipts preserve PR conditions without copying sidecars',transfer),
        ('Removing a met held task reconciles the real backend NOT_FOUND and retires its decision',removal),
        ('Captain hold wrapper evaluates a marker and its answer-release retires the disposition decision',captain_hold),
        ('A mate request reaches the registered MAIN check; missing dispatcher refusal returns once through the real steering inbox',walk_missing),
        ('A maximum-size remote brief survives the real delta reader while oversized, binary, and private paths are refused',remote_and_boundary)
    ]:
        if not os.environ.get('LIVE_RECHECK') or fn in (marker,removal):scenario(name,fn)
finally:
    for h in reversed(LABS):
        # No primary/server is started by this driver; all product commands are awaited.
        shutil.rmtree(h)
        log('TEARDOWN removed disposable lab '+str(h))
    log('All manual-verification subprocesses completed; no detached dispatch was launched (private dispatcher absent).')
    LOG.close()
print(json.dumps(RESULTS,indent=2))
raise SystemExit(1 if any(r['result']=='fail' for r in RESULTS) else 0)
