"""Drive the real publication/join CLI with disposable serialized input, no executable mocks.
Oracle: required input-join completeness/disagreement/valid-empty/unavailable-home
contract and documented fm-seat-candidates/v1 protocol. Synthetic publications
stand in for external data only, never the product executable.
"""
import copy, hashlib, json, os, pathlib, shutil, subprocess, tempfile, time
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M6Q0DRS6DKKAHX20S266GB9E')
S=pathlib.Path(tempfile.mkdtemp(prefix='manual-',dir=ROOT/'.validation-tmp'))
transcript=[]; results=[]
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('TASKS_AXI_') or k.startswith('HERDR_'))}
env['TMPDIR']=str(S)
AL=ROOT/'bin/fm-autolaunch.sh'
def home(name):
    h=S/name
    for d in ('state','data','config','projects/proj'): (h/d).mkdir(parents=True,exist_ok=True)
    (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (h/'data/backlog.md').write_text('## In flight\n## Queued\n## Done\n')
    return h
R=home('root'); B=home('child'); G=home('grandchild')
def registry(parent,child,name):
    (parent/'data/secondmates.md').write_text(f'- {name} - disposable lab (home: {child}; scope: validation; projects: proj; added 2026-11-05)\n')
registry(R,B,'lab-child')
def parent(child,p): (child/'.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={p}\n')
def digest(p): return 'sha256:'+hashlib.sha256(p.read_bytes()).hexdigest()
def entry(h,t):
    d=h/'data'/t; d.mkdir(exist_ok=True)
    (d/'prep.md').write_text(f'# Prep\nAccepted prep for {t}\n'); (d/'brief.md').write_text(f'# Task\nBrief for {t}\n')
    refs={s:s+'-v1' for s in ('tasks','prep','slice','catalogue','claims')}
    return dict(owner=dict(home=str(h),task=t),actor=dict(home=str(h),task=t,kind='builder'),slice_id='validation/cut',phase='build',cut='one',owner_generation=1,prep=dict(revision='prep-v1',digest=digest(d/'prep.md'),brief_digest=digest(d/'brief.md')),source_refs=refs,facts={n:dict(verdict='allow',authority=a,source_ref=refs[a]) for n,a in dict(task='tasks',dependencies='tasks',prep='prep',phase='slice',placement='catalogue',claim='claims').items()})
def publication(h,entries=None):
    now=int(time.time())
    return dict(schema='fm-seat-candidates/v1',machine='isolated-validation-machine',home=str(h),publication_id='lab-'+h.name,completed_at=now-1,valid_until=now+3600,complete=True,sources={s:dict(status='ok',revision=s+'-v1',evidence_digest='sha256:'+'1'*64) for s in ('tasks','prep','slice','catalogue','claims')},entries=entries or [])
def write(h,doc): (h/'state/autolaunch-steps.candidates').write_text(json.dumps(doc)+'\n')
def command(h,*args,extra=None):
    e=dict(env,FM_HOME=str(h)); e.update(extra or {})
    c=subprocess.run(['bash',str(AL),*args],env=e,text=True,capture_output=True,timeout=60)
    try: out=json.loads(c.stdout)
    except json.JSONDecodeError: out=c.stdout
    transcript.append(dict(command=['bash','bin/fm-autolaunch.sh',*args],home=str(h),exit=c.returncode,stdout=out,stderr=c.stderr))
    return c.returncode,out

def join(h=R):
    rc,d=command(h,'--join'); assert d['schema']=='join/v1',d
    assert rc==(0 if d['status']=='COMPLETE' else 75),(rc,d)
    return d

def complete(d): assert d['status']=='COMPLETE',d

def unavailable(d,h):
    assert d['status']=='NO_PICK',d
    hs=[x for x in d['homes'] if x['home']==str(h)]; assert len(hs)==1 and hs[0]['status']=='unavailable' and hs[0]['reason'],d
    assert any(x.get('home')==str(h) and x.get('owner')==str(h) and x.get('retry') for x in d['reasons']),d

def states(d): return {x['owner']['task']:x['result'] for x in d['entries']}
def run(name,fn):
    start=len(transcript)
    try: fn(); result='pass'
    except Exception as ex:
        results.append(dict(name=name,result='fail',error=repr(ex),calls=[start,len(transcript)])); raise
    results.append(dict(name=name,result=result,calls=[start,len(transcript)])); print('PASS '+name,flush=True)

def producer_empty():
    rc,p=command(R,'--publish-candidates'); assert rc==0 and p['entries']==[] and p['complete'] is False,p
    assert p==json.loads((R/'state/autolaunch-steps.candidates').read_text())
    assert p['sources']['tasks']['status']=='ok' and p['sources']['prep']['status']=='ok',p
    assert all(p['sources'][s]['status']=='missing' for s in ('slice','catalogue','claims')),p
    write(B,publication(B)); unavailable(join(),R)

def producer_rows():
    (R/'data/backlog.md').write_text('## In flight\n## Queued\n- [ ] prepared - prepared candidate (repo: proj) (kind: ship) (since 2026-11-01)\n- [ ] unprepared - missing evidence (repo: proj) (kind: scout) (since 2026-11-01)\n## Done\n')
    entry(R,'prepared'); (R/'data/prepared/autolaunch-prep').write_text('project=proj\nkind=ship\nmode=direct-PR\nyolo=off\n')
    rc,p=command(R,'--publish-candidates'); assert rc==0,p
    rows={x['owner']['task']:x for x in p['entries']}; assert set(rows)=={'prepared','unprepared'},p
    assert rows['prepared']['facts']['prep']['verdict']=='allow',p
    assert rows['unprepared']['facts']['prep']['verdict']=='unknown' and rows['unprepared']['facts']['prep']['reason'],p
    assert p['complete'] is False and not (R/'state/autolaunch.log').exists(),p
    first=p['publication_id']; rc,p=command(R,'--publish-candidates'); assert rc==0 and p['publication_id']!=first
    assert not list((R/'state').glob('.autolaunch-candidates-*'))
    traps=home('override-trap'); before=tree(traps)
    rc,p=command(R,'--publish-candidates',extra={k:str(traps/v) for k,v in [('FM_STATE_OVERRIDE','state'),('FM_DATA_OVERRIDE','data'),('FM_CONFIG_OVERRIDE','config')]})
    assert rc==0 and {x['owner']['task'] for x in p['entries']}==set(rows) and tree(traps)==before,p

def tree(h):
    return sorted((str(p.relative_to(h)),digest(p)) for p in h.rglob('*') if p.is_file())

def valid_empty():
    write(R,publication(R));write(B,publication(B)); before=tree(S)
    d=join();complete(d);assert d['entries']==[] and len(d['homes'])==2,d
    assert tree(S)==before,'read-only join changed the sandbox'

def eligibility():
    a=entry(R,'allowed'); n=entry(R,'denied'); u=entry(R,'uncertain')
    n['facts']['dependencies'].update(verdict='deny',reason='accepted dependency still active')
    u['facts']['dependencies'].update(verdict='deny',reason='accepted dependency still active');u['facts']['claim'].update(verdict='unknown',reason='writer identity uncertain')
    write(R,publication(R,[a,n,u]));d=join();complete(d)
    assert states(d)=={'allowed':'ELIGIBLE','denied':'INELIGIBLE','uncertain':'UNKNOWN'},d

def evidence_validation():
    base=publication(R,[entry(R,'target')]);write(B,publication(B))
    variants=[]
    for source in ('claims','extra'):
        for mode in ('missing-digest','missing-reason','missing-revision','missing-ref','valid-not-applicable'):
            p=copy.deepcopy(base); row=p['entries'][0]
            if source=='extra':
                p['sources']['extra']=dict(status='ok',revision='extra-v1',evidence_digest='sha256:'+'2'*64)
                row['source_refs']['extra']='extra-v1';row['facts']['extra']=dict(authority='extra',source_ref='extra-v1',verdict='allow')
            s=p['sources'][source]
            if mode=='missing-digest': s.pop('evidence_digest')
            if mode=='missing-reason':s.update(status='not_applicable')
            if mode=='missing-revision':s.pop('revision')
            if mode=='missing-ref':row['source_refs'].pop(source)
            if mode=='valid-not-applicable':s.update(status='not_applicable',reason='authoritative policy excludes this scope');s.pop('evidence_digest')
            write(R,p);d=join();complete(d)
            expected='ELIGIBLE' if mode=='valid-not-applicable' else 'UNKNOWN'
            assert states(d)=={'target':expected},(source,mode,d)
            variants.append((source,mode,expected))
    p=copy.deepcopy(base);p['sources']['unused']=dict(status='missing');write(R,p);d=join();complete(d);assert states(d)=={'target':'ELIGIBLE'},d
    transcript.append(dict(assertion='unused optional coverage remains optional; every consumed source validated',variants=variants))

def disagreement():
    base=publication(R,[entry(R,'target'),entry(R,'sibling')]);write(B,publication(B))
    for variant in ('stale-reference','changed-prep','changed-brief'):
        p=copy.deepcopy(base)
        if variant=='stale-reference':p['entries'][0]['source_refs']['tasks']='stale'
        else:
            f=R/'data/target'/('prep.md' if variant=='changed-prep' else 'brief.md');original=f.read_bytes();f.write_text('changed after publication\n')
        write(R,p);d=join();complete(d);assert states(d)=={'target':'UNKNOWN','sibling':'ELIGIBLE'},(variant,d)
        if variant!='stale-reference':f.write_bytes(original)

def membership():
    write(R,publication(R));write(B,publication(B));write(G,publication(G)); registry(B,G,'lab-grandchild');parent(B,R)
    # Missing current state cannot erase its readable child registry.
    shutil.rmtree(B/'state');d=join(B);unavailable(d,B);assert any(x['home']==str(G) and x['status']=='available' for x in d['homes']),d
    (B/'state').mkdir();write(B,publication(B))
    # Removed root: discovery started from B must still inspect B's children.
    parked=S/'parked-root';R.rename(parked)
    try:
        d=join(B);unavailable(d,R);assert any(x['home']==str(G) and x['status']=='available' for x in d['homes']),d
    finally:parked.rename(R)
    # Missing and unreadable registered homes remain named, with retry disposition.
    gone=S/'parked-child'; B.rename(gone)
    try:d=join();unavailable(d,B)
    finally:gone.rename(B)
    B.chmod(0)
    try:d=join();unavailable(d,B)
    finally:B.chmod(0o755)
    (B/'data/secondmates.md').unlink();(B/'.fm-secondmate-parent').unlink()

def invalid_publication():
    base=publication(B); write(R,publication(R)); path=B/'state/autolaunch-steps.candidates'
    for mode in ('expired','incomplete','missing-required-digest','duplicate-json-key','fifo','missing-file'):
        write(B,base)
        if mode in ('expired','incomplete','missing-required-digest'):
            p=copy.deepcopy(base)
            if mode=='expired':p['valid_until']=int(time.time())-10;p['completed_at']=int(time.time())-20
            if mode=='incomplete':p['complete']=False
            if mode=='missing-required-digest':p['sources']['tasks'].pop('evidence_digest')
            write(B,p)
        if mode=='duplicate-json-key':path.write_text(json.dumps(base)[:-1]+', "complete": true}')
        if mode in ('fifo','missing-file'):path.unlink()
        if mode=='fifo':os.mkfifo(path)
        started=time.monotonic()
        try:d=join();unavailable(d,B);assert time.monotonic()-started<5,(mode,d)
        finally:
            if mode=='fifo':path.unlink()
    write(B,base)

def ownership():
    a=entry(R,'target');write(R,publication(R,[a,a]));write(B,publication(B));d=join();assert d['status']=='NO_PICK' and all(x['result']=='UNKNOWN' for x in d['entries']),d
    foreign=copy.deepcopy(a);write(R,publication(R,[a]));write(B,publication(B,[foreign]));d=join();assert d['status']=='NO_PICK' and all(x['result']=='UNKNOWN' for x in d['entries']),d
    assert any(x['code']=='ownership-conflict' for x in d['reasons']),d

try:
    for name,fn in [('Publish an empty native backlog without claiming missing production coverage',producer_empty),('Publish native prepared and unprepared tasks atomically with isolated home overrides',producer_rows),('Join two valid empty homes without writing or starting work',valid_empty),('Distinguish eligible, denied and uncertain entries with uncertainty taking precedence',eligibility),('Reject invalid consumed authority evidence while retaining valid exclusions and unused optional sources',evidence_validation),('Keep stale revisions and changed prep or brief evidence UNKNOWN without blocking valid siblings',disagreement),('Retain unavailable homes and readable descendants through missing state and parents',membership),('Refuse expired, incomplete, malformed, nonregular and absent publications promptly',invalid_publication),('Refuse duplicate or cross-home ownership rather than admitting either entry',ownership)]:run(name,fn)
finally:
    (E/'live-candidates-transcript.json').write_text(json.dumps(transcript,indent=2)+'\n')
    (E/'live-candidates-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(S)
