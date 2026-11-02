import hashlib, json, os, pathlib, shutil, subprocess, time
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6DEE8N3FPKKWF8CNR4SPFE0')
home=root/'.contrib-live-validation/manual-home'
for p in ('data','state','config','projects','tmp','gh-empty'): (home/p).mkdir(parents=True,exist_ok=True)
(home/'data/backlog.md').write_text('# Backlog\n\n## Queued\n')
for i in range(400):
    task=f'owner-{i:03d}'
    folder=home/'data'/task
    folder.mkdir()
    record=dict(url=f'https://github.com/disposable-fixture/monitor/pull/{i+1}',kind='pr',checked_at='2026-11-02T08:00:00Z',error=None,pending=[],seen=[],notified=[],verdict=None,observation=dict(head='a'*40,state='merged',draft=False,mergeable='mergeable',review_decision='APPROVED',can_merge=False,checks=[],reviews=[],events=[dict(body='x'*5000)]))
    if i==399: record['pending']=[dict(token='sentinel-at-end',type='comment',source=record['url']+'#issuecomment-1')]
    (folder/'contributions.json').write_text(json.dumps(dict(schema='fm-contributions.v1',task=task,records=[record]))+'\n')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'GH_', 'GITHUB_', 'TASKS_AXI_'))}
env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(root),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_PROJECTS_OVERRIDE=str(home/'projects'),FM_CONTRIBUTIONS_NOW='2026-11-02T08:00:00Z',TMPDIR=str(home/'tmp'),GH_CONFIG_DIR=str(home/'gh-empty'),GH_TOKEN='disposable-unusable-token',GITHUB_TOKEN='disposable-unusable-token',HTTPS_PROXY='http://127.0.0.1:1',HTTP_PROXY='http://127.0.0.1:1',ALL_PROXY='http://127.0.0.1:1',NO_PROXY='')
files=sorted((home/'data').glob('*/contributions.json'))
def hashes(): return {str(p.relative_to(home)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
before=hashes()
results=[]
def drive(args,label,extra=None):
    actual=['bash',str(root/'bin/fm-contributions.sh'),*args]
    started=time.monotonic()
    proc=subprocess.run(actual,env={**env,**(extra or {})},capture_output=True,text=True,timeout=35)
    elapsed=time.monotonic()-started
    (evidence/(label+'.stdout')).write_text(proc.stdout)
    (evidence/(label+'.stderr')).write_text(proc.stderr)
    results.append(dict(label=label,command='bash bin/fm-contributions.sh '+' '.join(args),environment=extra or {},exit=proc.returncode,elapsed_seconds=round(elapsed,3),stdout=proc.stdout if len(proc.stdout)<500 else '<retained in '+label+'.stdout>',stderr=proc.stderr,all_400_records_byte_identical=(before==hashes())))
    print(json.dumps(results[-1]),flush=True)
    assert proc.returncode==0,proc.stderr
    return proc.stdout,elapsed
try:
    out,elapsed=drive(['poll'],'manual-natural-scan-skip',dict(FM_CHECK_TIMEOUT='4'))
    assert out=='contributions: scan skipped (time budget exhausted)\n'
    assert elapsed<4 and hashes()==before
    out,elapsed=drive(['pending'],'manual-pending-full-scan',dict(FM_CHECK_TIMEOUT='4'))
    assert json.loads(out)==[dict(token='sentinel-at-end',type='comment',source='https://github.com/disposable-fixture/monitor/pull/400#issuecomment-1',task='owner-399',url='https://github.com/disposable-fixture/monitor/pull/400')]
    assert elapsed>1 and hashes()==before
    input_file=home/'input.json'
    canonical=subprocess.run(['bash',str(root/'bin/fm-fleet-snapshot.sh'),'--contribution-input'],env=env,capture_output=True,text=True,check=True,timeout=10)
    input_file.write_text(canonical.stdout)
    (evidence/'manual-canonical-input.json').write_text(canonical.stdout)
    out,elapsed=drive(['snapshot',str(input_file),'--all'],'manual-snapshot-full-scan',dict(FM_CHECK_TIMEOUT='4'))
    snapshot=json.loads(out)
    assert snapshot['known']==400 and snapshot['checked']==400
    assert elapsed>1 and hashes()==before
    out,elapsed=drive(['poll'],'manual-400-owner-retry')
    assert out=='' and elapsed<30 and hashes()==before
    (evidence/'manual-record-digests.json').write_text(json.dumps(dict(before=before,after=hashes()),indent=2)+'\n')
finally:
    (evidence/'manual-cli-transcript.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(home)
