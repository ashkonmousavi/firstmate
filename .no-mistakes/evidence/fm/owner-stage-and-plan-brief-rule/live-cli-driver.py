import json, os, pathlib, shutil, subprocess
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M6QATZCFP0RNDVNFA21RW85H')
LAB=ROOT/'.lab'
LOG=[]
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ['TASKS_AXI_FILE','NO_MISTAKES_GATE'])}
env['FM_HOME']=str(LAB)
def run(*args, ok=0):
    p=subprocess.run([str(x) for x in args],env=env,text=True,capture_output=True,timeout=30)
    LOG.append('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
    if p.returncode!=ok: raise AssertionError(LOG[-1])
    return p.stdout
try:
    run(ROOT/'bin/fm-lab-home.sh','create',LAB)
    backlog=LAB/'data/backlog.md'
    backlog.write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    plans=['task-system','lane-system','central-governance','red-main-loop','ci-v1','live-app-check']
    expected='- When a problem recurs or you are unsure, load `research` (research-book INDEX first, then 2026 primary sources) and/or run `grilling` (lists open questions) with `kun` answering them; do not ask the owner; save a research-book entry with the reading that proves the fix, and name it in each recurring-problem cut.'
    def rules(text): return text.split('# Rules\n',1)[1].split('\n# ',1)[0]
    for mode in ['no-mistakes','direct-PR','local-only','scout']:
        for i,plan in enumerate(plans):
            task='lab-'+mode+'-'+str(i)
            body='```text\nSLICE: product/example | example\n```\nSLICE: ops/'+plan+' | plan cut | role='+('owner' if i%2==0 else 'child')
            # Native tasks-axi builds isolated persisted fixture rows. fm-brief uses the real wrapper to read them.
            run('tasks-axi','add',task,'lab brief','--kind','scout' if mode=='scout' else 'ship','--body',body,'--file',backlog)
            args=['--scout'] if mode=='scout' else ['--mode',mode]
            run(ROOT/'bin/fm-brief.sh',task,'sample',*args)
            text=(LAB/'data'/task/'brief.md').read_text()
            r=rules(text)
            assert r.splitlines()[0]==expected and r.count(expected)==1
            assert '\nSLICE: ops/'+plan+' | plan cut' in text
            assert "## Captain's intent\n{TASK}" in text
            assert '## Firstmate spec\n{FIRSTMATE_SPEC}' in text
            if i==0: shutil.copy2(LAB/'data'/task/'brief.md',E/(mode+'-generated-brief.md'))
        for j,body in enumerate(['A task without a declaration.','SLICE: product/desk | ops/task-system is prose','```text\nSLICE: ops/task-system | example\n```','SLICE: opsish/task-system | different namespace']):
            task='negative-'+mode+'-'+str(j)
            run('tasks-axi','add',task,'lab brief','--body',body,'--file',backlog)
            args=['--scout'] if mode=='scout' else ['--mode',mode]
            out=run(ROOT/'bin/fm-brief.sh',task,'sample',*args)
            text=(LAB/'data'/task/'brief.md').read_text()
            assert expected not in text
        LOG.append('PASS '+mode+': all six plans, both roles, and four negative classifications\n')
    # Real registered check snapshot and receipt environment, no forged executable.
    check=LAB/'state/deploy.check.sh'
    check.write_text("#!/usr/bin/env bash\npython3 - <<'RECEIPT'\nimport json,os\nprint(json.dumps({'head':os.environ['FM_STAGE_HEAD'],'status':'pending','event':'lab-attempt','reason':os.environ['FM_STAGE_TASK']}))\nRECEIPT\n")
    check.chmod(0o700)
    run(ROOT/'bin/fm-check-register.sh','deploy')
    receipt=json.loads(run(ROOT/'bin/fm-stage-transition.sh','_receipt','deploy','lab-lead','a'*40))
    assert receipt=={'head':'a'*40,'status':'pending','event':'lab-attempt','reason':'lab-lead'}
    cfg=LAB/'config/plan-leads.json'
    cfg.write_text(json.dumps({'schema':1,'tasks':{'lab-lead':{'deploy_check':'deploy','installed_check':'installed'}}}))
    run(ROOT/'bin/fm-stage-transition.sh','arm')
    assert (LAB/'state/plan-stages.check.sh').is_file()
    budget=int(run(ROOT/'bin/fm-stage-transition.sh','budget'))
    assert budget>=600+120
    run(ROOT/'bin/fm-stage-transition.sh','can-close','unlisted')
    run('tasks-axi','add','lab-lead','lab lead','--kind','ship','--file',backlog)
    (LAB/'state/lab-lead.meta').write_text('kind=ship\nbranch=fm/lab-lead\nworktree='+str(ROOT)+'\npr=https://github.com/example/project/pull/42\n')
    run(ROOT/'bin/fm-stage-transition.sh','can-close','lab-lead',ok=1)
    run(ROOT/'bin/fm-tasks-axi.sh','done','lab-lead',ok=2)
    assert 'state: queued' in run(ROOT/'bin/fm-tasks-axi.sh','show','lab-lead')
    # Native Done rows must defer before endpoint inspection or forge reads.
    run('tasks-axi','done','lab-lead','--file',backlog)
    assert run(ROOT/'bin/fm-stage-transition.sh','_eligible','lab-lead').strip()=='done'
    run(ROOT/'bin/fm-stage-transition.sh','check')
    ledger=json.loads((LAB/'state/.stage-transitions.json').read_text())
    assert ledger['tasks']['lab-lead']['closed'] is False
    assert not ledger['tasks']['lab-lead']['events']
    # No registry and unlisted tasks preserve ordinary Done behavior.
    run(ROOT/'bin/fm-tasks-axi.sh','done','negative-local-only-0')
    cfg.unlink()
    assert int(run(ROOT/'bin/fm-stage-transition.sh','budget'))==30
    run(ROOT/'bin/fm-stage-transition.sh','can-close','lab-lead')
    LOG.append('PASS: registered receipt, arming/budget, incomplete-proof close refusal, unlisted completion, Done no-relaunch, absent-registry compatibility\n')
finally:
    (E/'live-cli-transcript.log').write_text('\n'.join(LOG))
    if LAB.exists(): shutil.rmtree(LAB)
