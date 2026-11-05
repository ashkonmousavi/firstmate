import copy, hashlib, json, os, pathlib, shutil, subprocess, time
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M6PQME4YX4EXPVGXDT30GMFT')
LAB=ROOT/'.test-live'/'join'
LAB.mkdir(parents=True)
A=LAB/'a'; B=LAB/'b'
for h in [A,B]:
    subprocess.run(['bash','bin/fm-lab-home.sh','create',str(h)],check=True,capture_output=True)
(A/'data/secondmates.md').write_text(f'- sibling - test home (home: {B}; scope: test; projects: proj; added 2026-11-05)\n')
env=dict(os.environ,FM_HOME=str(A))
for k in list(env):
    if k.startswith('FM_') and k not in ['FM_HOME']: env.pop(k)
env.pop('TASKS_AXI_BACKEND',None)
records=[]
def digest(b): return 'sha256:'+hashlib.sha256(b).hexdigest()
def entry(h,task):
    d=h/'data'/task; d.mkdir(parents=True,exist_ok=True)
    (d/'prep.md').write_text('Accepted prep\n'); (d/'brief.md').write_text('Accepted brief\n')
    auth={'task':'tasks','dependencies':'tasks','prep':'prep','phase':'slice','placement':'catalogue','claim':'claims'}
    refs={s:s+'-r1' for s in ['tasks','prep','slice','catalogue','claims']}
    return dict(owner=dict(home=str(h),task=task),actor=dict(home=str(h),task=task,kind='builder'),slice_id='ops/live',phase='build',cut='first',owner_generation=1,prep=dict(revision=refs['prep'],digest=digest((d/'prep.md').read_bytes()),brief_digest=digest((d/'brief.md').read_bytes())),source_refs=refs,facts={k:dict(verdict='allow',authority=v,source_ref=refs[v]) for k,v in auth.items()})
def pub(h,entries):
    clock=int(time.time())
    doc=dict(schema='fm-seat-candidates/v1',home=str(h),machine='disposable-lab',publication_id=h.name+'-publication',completed_at=clock-5,valid_until=clock+3600,complete=True,sources={s:dict(status='ok',revision=s+'-r1',evidence_digest=digest((s+' read').encode())) for s in ['tasks','prep','slice','catalogue','claims']},entries=entries)
    write(h,doc); return doc
def write(h,doc): (h/'state/autolaunch-steps.candidates').write_text(json.dumps(doc)+'\n')
def snapshot():
    return {str(p.relative_to(LAB)):digest(p.read_bytes()) for p in LAB.rglob('*') if p.is_file() and not p.is_symlink()}
def call(name,expect_status,expect_entries=None,home=A,args=['--join']):
    before=snapshot(); t=time.monotonic()
    p=subprocess.run(['bash','bin/fm-autolaunch.sh',*args],env=dict(env,FM_HOME=str(home)),capture_output=True,text=True,timeout=30)
    elapsed=time.monotonic()-t
    rec=dict(name=name,argv=['bin/fm-autolaunch.sh',*args],home=str(home),exit=p.returncode,elapsed_seconds=elapsed,stdout=p.stdout,stderr=p.stderr)
    records.append(rec)
    try:
        doc=json.loads(p.stdout)
        if args==['--publish-candidates']: assert p.returncode==0,(name,p.returncode,p.stderr)
        if args==['--join']:
            assert p.returncode==(0 if expect_status=='COMPLETE' else 75),(name,p.returncode,p.stderr)
            assert doc['status']==expect_status,(name,doc)
            if expect_entries is not None: assert [x['result'] for x in doc['entries']]==expect_entries,(name,doc)
            assert before==snapshot(),name+' join mutated files'
        rec['assertions']='pass'
        return doc
    except Exception:
        rec['assertions']='fail'; raise
try:
    ea=entry(A,'candidate-a'); eb=entry(B,'candidate-b')
    da=pub(A,[]); db=pub(B,[eb])
    call('Complete empty home allows eligible sibling; join is read-only','COMPLETE',['ELIGIBLE'])
    da=pub(A,[ea]); db=pub(B,[eb])
    for authority in ['claims','additional']:
        for invalid in ['missing_digest','missing_reason','empty_revision']:
            x=copy.deepcopy(da)
            if authority=='additional':
                x['sources']['additional']=dict(status='ok',revision='additional-r1',evidence_digest=digest(b'evidence'))
                x['entries'][0]['source_refs']['additional']='additional-r1'
                x['entries'][0]['facts']['extra']=dict(verdict='allow',authority='additional',source_ref='additional-r1')
            s=x['sources'][authority]
            if invalid=='missing_digest': s.pop('evidence_digest')
            if invalid=='missing_reason': s['status']='not_applicable'; s.pop('reason',None)
            if invalid=='empty_revision':
                s['revision']=''; x['entries'][0]['source_refs'][authority]=''
                for f in x['entries'][0]['facts'].values():
                    if f['authority']==authority: f['source_ref']=''
            write(A,x)
            call(f'Consumed {authority} {invalid} stays UNKNOWN, eligible sibling survives','COMPLETE',['UNKNOWN','ELIGIBLE'])
    x=copy.deepcopy(da); x['sources']['claims']=dict(status='not_applicable',revision='claims-r1',reason='Authoritative no-claim applicability')
    write(A,x); call('Valid authoritative not_applicable permits eligibility','COMPLETE',['ELIGIBLE','ELIGIBLE'])
    x=copy.deepcopy(da); x['entries'][0]['facts']['task']['verdict']='deny'; write(A,x)
    call('Authoritative deny yields INELIGIBLE','COMPLETE',['INELIGIBLE','ELIGIBLE'])
    x['entries'][0]['facts']['claim']['verdict']='unknown'; write(A,x)
    call('Unknown claim takes precedence over deny','COMPLETE',['UNKNOWN','ELIGIBLE'])
    write(A,da); (A/'data/candidate-a/prep.md').write_text('Changed prep\n')
    call('Changed accepted prep is UNKNOWN','COMPLETE',['UNKNOWN','ELIGIBLE'])
    (A/'data/candidate-a/prep.md').write_text('Accepted prep\n')
    x=copy.deepcopy(da); x['entries'][0]['source_refs']['slice']='old'; write(A,x)
    call('Conflicting source revision is UNKNOWN','COMPLETE',['UNKNOWN','ELIGIBLE'])
    write(A,da); x=copy.deepcopy(db); x['entries']=[ea]; write(B,x)
    call('Cross-home conflicting ownership picks no side','NO_PICK',['UNKNOWN','UNKNOWN'])
    write(B,db)
    x=copy.deepcopy(db); x['valid_until']=int(time.time())-10; write(B,x)
    call('Expired sibling publication blocks machine completeness','NO_PICK',['ELIGIBLE'])
    write(B,db)
    (B/'state/autolaunch-steps.candidates').unlink(); os.mkfifo(B/'state/autolaunch-steps.candidates')
    # snapshot never reads FIFOs; command must reject without blocking.
    call('FIFO publication is rejected without blocking','NO_PICK',['ELIGIBLE'])
    (B/'state/autolaunch-steps.candidates').unlink()
    (B/'state/autolaunch-steps.candidates').symlink_to(A/'state/autolaunch-steps.candidates')
    call('Symlink publication is unavailable without following it','NO_PICK',['ELIGIBLE'])
    (B/'state/autolaunch-steps.candidates').unlink(); write(B,db)
    shutil.rmtree(B)
    got=call('Removed registered home retains unavailable disposition','NO_PICK',['ELIGIBLE'])
    assert any(r.get('home')==str(B) and r.get('owner') and r.get('retry') for r in got['reasons'])
    got=call('Missing entry home retains identity and disposition','NO_PICK',[],home=B)
    assert any(r.get('home')==str(B) and r.get('owner') and r.get('retry') for r in got['reasons'])
    # Known descendant is still enumerated when the current state directory is absent.
    subprocess.run(['bash','bin/fm-lab-home.sh','create',str(B)],check=True,capture_output=True)
    eb=entry(B,'candidate-b'); pub(B,[eb]); shutil.rmtree(A/'state')
    got=call('Missing current state preserves readable registered child','NO_PICK',['ELIGIBLE'])
    assert any(h['home']==str(B) and h['status']=='available' for h in got['homes'])
    (A/'state').mkdir()
    missing_parent=LAB/'parent'
    (A/'.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={missing_parent}\n')
    pub(A,[])
    got=call('Removed ancestor preserves ancestor identity and readable children','NO_PICK',['ELIGIBLE'])
    assert any(h['home']==str(B) and h['status']=='available' for h in got['homes'])
    assert any(r.get('home')==str(missing_parent) and r.get('owner') and r.get('retry') for r in got['reasons'])
    subprocess.run(['bash','bin/fm-lab-home.sh','create',str(missing_parent)],check=True,capture_output=True)
    (missing_parent/'data/secondmates.md').write_text(f'- sibling - test home (home: {B}; scope: test; projects: proj; added 2026-11-05)\n')
    (A/'data/secondmates.md').unlink()
    shutil.rmtree(missing_parent/'state')
    got=call('Ancestor without state still exposes readable registered children','NO_PICK',['ELIGIBLE'])
    assert any(h['home']==str(B) and h['status']=='available' for h in got['homes'])
    (A/'.fm-secondmate-parent').unlink()
    (A/'data/secondmates.md').write_text(f'- sibling - test home (home: {B}; scope: test; projects: proj; added 2026-11-05)\n')
    (A/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (A/'data/backlog.md').write_text('## In flight\n## Queued\n## Done\n')
    doc=call('Real empty native backlog publishes honestly incomplete coverage',None,args=['--publish-candidates'])
    assert not doc['complete'] and doc['sources']['tasks']['status']=='ok' and doc['entries']==[]
    assert all(doc['sources'][s]['status']=='missing' for s in ['slice','catalogue','claims'])
    call('Incomplete production publication cannot be treated as valid empty','NO_PICK',['ELIGIBLE'])
    (A/'data/backlog.md').write_text('## In flight\n## Queued\n- [ ] unprepared - No prep (kind: ship; repo: proj; added 2026-11-05)\n## Done\n')
    doc=call('Real producer retains identified unprepared native task',None,args=['--publish-candidates'])
    assert len(doc['entries'])==1 and doc['entries'][0]['owner']['task']=='unprepared',doc
    assert doc['entries'][0]['facts']['prep']['verdict']!='allow' and 'no brief' in doc['entries'][0]['facts']['prep']['reason'],doc
    # Isolate the service-manager bus: inspect refusal, never reach shared manager.
    (A/'config/autolaunch-sole').touch()
    private_env=dict(env,FM_HOME=str(A),DBUS_SESSION_BUS_ADDRESS='unix:path='+str(LAB/'absent-bus'),XDG_RUNTIME_DIR=str(LAB/'runtime'))
    p=subprocess.run(['bash','bin/fm-autolaunch.sh'],env=private_env,capture_output=True,text=True,timeout=15)
    records.append(dict(name='Activated controller refuses unavailable private manager',exit=p.returncode,stdout=p.stdout,stderr=p.stderr))
    assert p.returncode!=0 and 'controller obligations preserved' in p.stderr,(p.returncode,p.stdout,p.stderr)
    assert not (A/'state/autolaunch-controller').exists()
finally:
    (E/'live-cli-transcript.json').write_text(json.dumps(records,indent=2)+'\n')
    shutil.rmtree(LAB)
print('Real CLI scenarios passed; inputs/outputs retained in live-cli-transcript.json')
