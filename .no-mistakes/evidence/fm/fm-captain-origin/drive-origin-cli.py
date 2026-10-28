import json, os, pathlib, shlex, shutil, subprocess, tempfile
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('~/.no-mistakes/evidence/01M61D11BKFQH1DMTFW1H18EW9')
lab = pathlib.Path(tempfile.mkdtemp(prefix='.origin-live-', dir=ROOT))
log = (EVIDENCE/'origin-cli-transcript.txt').open('w')
env = {k:v for k,v in os.environ.items() if not k.endswith('_OVERRIDE') and k not in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_HOME','FM_SECOND_MATE','FM_PARENT_HOME','FM_PARENT_TASK_ID')}
env['FM_HOME'] = str(lab)
results = []
def run(*args, ok=True):
    log.write('$ ' + shlex.join(args).replace(str(lab), '<LAB>') + '\n'); log.flush()
    p = subprocess.run(args, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    log.write(p.stdout.replace(str(lab), '<LAB>') + f'[exit {p.returncode}]\n\n'); log.flush()
    assert (p.returncode == 0) == ok, (args, p.returncode, p.stdout)
    return p.stdout
H=str(ROOT/'bin/fm-captain-hold.sh'); T=str(ROOT/'bin/fm-tasks-axi.sh')
def hold(id, *args, ok=True): return run(H, 'hold', id, *args, ok=ok)
def show(id): return run(T, 'show', id, '--full')
def check(label, fn):
    fn(); results.append({'name':label,'result':'pass','live':True}); log.write('SCENARIO PASS: '+label+'\n\n'); log.flush()
try:
    run(str(ROOT/'bin/fm-lab-home.sh'), 'create', str(lab))
    (lab/'.tasks.toml').write_text('backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (lab/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    def classes():
        for kind in ('owner-request','finding','pipeline-outcome'):
            id='class-'+kind
            hold(id,'--title','Attribution '+kind,'--reason','Sample unresolved preference','--origin-kind',kind)
            s=show(id)
            assert 'held: yes' in s and 'Captain hold origin-kind: '+kind in s
        hold('legacy','--title','Existing caller without classification','--reason','Sample unresolved preference')
        s=show('legacy'); assert 'held: yes' in s and 'Captain hold origin-kind:' not in s
    check('Create holds for all three origins and retain compatibility without a class', classes)
    def preservation():
        run(T,'add','review-origin','Sample review','--kind','scout','--repo','sample','--body','Review context survives')
        run(T,'update','class-owner-request','--body','Unrelated task context survives')
        hold('class-owner-request','--reason','Owner request awaiting preference','--origin','review-origin','--origin-kind','owner-request')
        first=show('class-owner-request')
        stamp=first.split('Captain hold set: ',1)[1].split('\\n',1)[0]
        hold('class-owner-request','--reason','Unclassified re-hold preserves custody')
        s=show('class-owner-request'); assert stamp in s and 'Captain hold origin-kind: owner-request' in s and 'Captain hold origin: review-origin' in s
        hold('class-owner-request','--reason','Pipeline reclassification','--origin-kind','pipeline-outcome')
        s=show('class-owner-request'); assert 'Captain hold origin: review-origin' in s and 'Captain hold origin-kind: pipeline-outcome' in s and 'Captain hold origin-kind: owner-request' not in s and 'Unrelated task context survives' in s
        hold('class-owner-request','--reason','Association-only update','--origin','review-origin')
        s=show('class-owner-request'); assert 'Captain hold origin-kind: pipeline-outcome' in s
        hold('class-owner-request','--reason','Worker finding','--origin-kind','finding')
        s=show('class-owner-request'); assert s.count('Captain hold origin-kind:')==1 and 'Captain hold origin-kind: finding' in s and 'Captain hold origin: review-origin' in s and stamp in s
    check('Re-hold and edit either origin field without losing association, class, timestamp or task context', preservation)
    def invalid():
        before=(lab/'data/backlog.md').read_bytes()
        hold('invalid-new','--title','Should never exist','--reason','Invalid class','--origin-kind','owner_request',ok=False)
        assert before==(lab/'data/backlog.md').read_bytes()
        hold('class-owner-request','--reason','Should never change','--origin-kind','captain',ok=False)
        assert before==(lab/'data/backlog.md').read_bytes()
        show('class-owner-request')
    check('Invalid origin kinds refuse before creating or changing a task', invalid)
    def rollback():
        run(T,'add','other-origin','Different review','--kind','scout','--repo','sample')
        before=show('class-owner-request')
        # Deny the actual backend's write only for hold; its earlier metadata updates
        # and later rollback remain writable. No backend response is fabricated.
        real_tasks=shutil.which('tasks-axi',path=env['PATH'])
        inject=lab/'fault-bin'; inject.mkdir()
        (inject/'tasks-axi').write_text("#!/usr/bin/env python3\nimport os,pathlib,subprocess,sys\ndata=pathlib.Path(os.environ['FM_HOME'])/'data'\nbacklog=data/'backlog.md'\nif len(sys.argv)>1 and sys.argv[1]=='hold':\n    data.chmod(0o555); backlog.chmod(0o444)\n    try:\n        p=subprocess.run(["+repr(real_tasks)+"]+sys.argv[1:],text=True,capture_output=True)\n        pathlib.Path("+repr(str(EVIDENCE/'backend-denial.txt'))+").write_text(p.stdout+p.stderr+f'\\n[real tasks-axi exit {p.returncode}]\\n')\n        sys.stdout.write(p.stdout);sys.stderr.write(p.stderr);code=p.returncode\n    finally: data.chmod(0o755); backlog.chmod(0o644)\n    sys.exit(code)\nos.execv("+repr(real_tasks)+",["+repr(real_tasks)+"]+sys.argv[1:])\n")
        (inject/'tasks-axi').chmod(0o755)
        old_path=env['PATH']; env['PATH']=str(inject)+os.pathsep+old_path
        try:
            output=hold('class-owner-request','--reason','Filesystem-denied hold must roll back metadata','--origin','other-origin','--origin-kind','owner-request',ok=False)
            denial=(EVIDENCE/'backend-denial.txt').read_text()
            assert 'EACCES' in denial or 'permission denied' in denial.lower(), denial
        finally: env['PATH']=old_path
        after=show('class-owner-request')
        assert before==after, (before,after)
    check('A backend-refused re-hold restores the previous origin and attribution', rollback)
    def lifecycle():
        (lab/'state/review-origin.meta').write_text('kind=scout\nmode=scout\nharness=codex\nproject='+str(lab/'projects/sample')+'\n')
        run(H,'complete','review-origin','class-owner-request')
        run(H,'verify','review-origin')
        decision=lab/'decision.txt'; decision.write_text('Use the blue route.\n')
        run(H,'answer','class-owner-request','--decision-file',str(decision))
        s=show('class-owner-request'); assert 'state: done' in s and 'Use the blue route.' in s and 'Captain hold origin-kind: finding' in s and 'Captain hold origin: review-origin' in s
        run(H,'verify','review-origin')
        hold('class-owner-request','--reason','Must stay closed','--origin-kind','owner-request',ok=False)
        assert s==show('class-owner-request')
    check('Origin metadata survives completion, verification and an actual answer, while closed tasks stay closed',lifecycle)
finally:
    log.close()
    shutil.rmtree(lab)
    (EVIDENCE/'origin-cli-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
