import os, re, json, subprocess, tempfile, shutil
from pathlib import Path
ROOT=Path.cwd()
EVIDENCE=Path('/home/tegris/.no-mistakes/evidence/01M49KKA9G4BTVR16V17MDQ3V1')
lab=Path(tempfile.mkdtemp(prefix='.gate-review-lab-',dir=ROOT))
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
        env.pop(key,None)
env['FM_HOME']=str(lab)
log=[]
def run(args, check=True):
    p=subprocess.run(args,cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    log.append('$ '+repr(args)+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
    if check and p.returncode:
        raise AssertionError(log[-1])
    return p

def command(contract,marker):
    lines=[line for line in contract.splitlines() if marker in line]
    assert len(lines)==1, (marker,lines)
    return lines[0].split('`')[1]
try:
    run(['bash','bin/fm-lab-home.sh','create',str(lab)])
    (lab/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    contracts={}
    for mode,forge in [('no-mistakes','none'),('no-mistakes','gerrit'),('direct-PR','none'),('direct-PR','gerrit'),('local-only','none')]:
        task=mode.lower()+'-'+forge
        run(['bash','bin/fm-brief.sh',task,'firstmate','--mode',mode]+(['--forge',forge] if forge!='none' else []))
        brief=(lab/'data'/task/'brief.md').read_text()
        pointer=re.search(r'```bash\n(.*?)\n```',brief,re.S).group(1)
        output=run(['bash','-c',pointer]).stdout
        (EVIDENCE/('contract-'+task+'.md')).write_text(output)
        contracts[task]=output
        if mode=='no-mistakes':
            assert 'The third distinct Review finding list is the last' in output
            assert 'no-mistakes axi respond --step review --action approve' in output
            assert 'never another fix' in output
            assert 'Test, document, lint, push, PR and CI still run' in output
            assert 'protected-path or Test refusal' in output
        elif mode=='direct-PR':
            assert output.count('Perform exactly one code review round')==1
            assert 'never request a second review list' in output
            assert 'axi respond' not in output
        else:
            assert 'Review follow-ups:' not in output
    heads=run(['git','rev-list','--max-count=3','HEAD']).stdout.splitlines()
    assert len(heads)==3
    for task in ('no-mistakes-none','no-mistakes-gerrit'):
        contract=contracts[task]
        template=command(contract,'review-lists.txt').replace('<run>','isolated-review')
        ledger=lab/'data'/task/'nm-isolated-review-review-lists.txt'
        for expected,head in enumerate(heads,1):
            cmd=template.replace('<head_sha>',head)
            for repeat in range(3):
                result=run(['bash','-c',cmd])
                assert int(result.stdout)==expected
                assert ledger.read_text().splitlines()==heads[:expected]
                log.append(f'LEDGER {task}: distinct_list={expected}, read={repeat+1}, ordinal={result.stdout.strip()}')
        (EVIDENCE/(task+'-ledger.txt')).write_bytes(ledger.read_bytes())
        ledger.write_bytes(('\n'.join(heads[:2])+'\n'+heads[2][:-1]).encode())
        damaged=ledger.read_bytes()
        for retry in range(2):
            p=run(['bash','-c',template.replace('<head_sha>',heads[2])],check=False)
            assert p.returncode!=0 and p.stdout==''
            assert ledger.read_bytes()==damaged
            log.append(f'CORRUPTION {task}: retry={retry+1}, refused without ordinal or mutation')
        ledger.write_text('\n'.join(heads[:2])+'\n')
        before=ledger.read_bytes()
        p=run(['bash','-c',"ulimit -f 0; trap '' XFSZ; "+template.replace('<head_sha>',heads[2])],check=False)
        assert p.returncode!=0 and p.stdout=='' and ledger.read_bytes()==before
        log.append(f'STORAGE {task}: third append refused without ordinal; retained two prior heads')
        assert int(run(['bash','-c',template.replace('<head_sha>',heads[2])]).stdout)==3
    findings=[
        {'id':'terminal-warning','severity':'warning','file':'bin/example.sh','line':42,'action':'auto-fix','description':'Remaining third-list detail: preserve "quotes", `commands`, and $literal verbatim.'},
        {'id':'terminal-stop-set','severity':'error','file':'src/example.py','line':7,'action':'ask-user','description':'Requires a human decision; deferred, not fixed.'},
        {'id':'terminal-info','severity':'info','file':None,'line':None,'action':'no-op','description':'Keep every finding, including one without a location.'},
    ]
    for task,review in [('no-mistakes-none','isolated-review'),('direct-pr-none','pr')]:
        contract=contracts[task]
        followup=lab/'data'/task/f'review-followups-{review}.txt'
        body='\n'.join(json.dumps(f,ensure_ascii=False) for f in findings)+'\n'
        followup.write_text(body)
        filing=command(contract,'fm-tasks-axi.sh').replace('<review>',review)
        p=run(['bash','-c',filing])
        item=re.search(r'^\s*id:\s*(\S+)',p.stdout,re.M)
        assert item, p.stdout
        item=item.group(1)
        detail=run(['bash','bin/fm-tasks-axi.sh','show',item,'--full']).stdout
        assert 'state: queued' in detail
        persisted=(lab/'data/backlog.md').read_text()
        for line in body.splitlines():
            assert line in persisted, (task,line,persisted)
        assert followup.read_text()==body
        (EVIDENCE/(task+'-followups.txt')).write_text(body)
        (EVIDENCE/(task+'-queued-item.txt')).write_text(detail)
        log.append(f'FOLLOWUP {task}: item={item}, queued, all three serialized findings retained verbatim')
    (EVIDENCE/'isolated-backlog.md').write_text((lab/'data/backlog.md').read_text())
    log.append('All public rendering, ledger, integrity, storage recovery, and real tasks-axi filing checks passed. No pipeline control command was executed.')
finally:
    shutil.rmtree(lab)
    log.append('Disposable worktree lab removed.')
    (EVIDENCE/'live-review-transcript.log').write_text('\n'.join(log))
print('\n'.join(line for line in log if not line.startswith('$')))
