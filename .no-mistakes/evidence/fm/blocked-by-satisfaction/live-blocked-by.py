import os, subprocess, pathlib, tempfile, time, json, re
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M6PYWK8CF5K753X1RN1KN9J8')
LOG=(E/'live-blocked-by.log').open('w')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'HERDR_', 'REX_')) and k not in ('TMUX','TMUX_PANE')}
env['TMPDIR']=str(ROOT/'.test-validation-tmp')
PR='https://github.com/cli/cli/pull/14918'
CLOSED='https://github.com/cli/cli/pull/14942'
def note(s): LOG.write('\n'+s+'\n'); LOG.flush()
def run(home, command, *args, rc=0, save=None, timeout=100):
    argv=[str(ROOT/'bin'/command), *args]
    e=env|{'FM_HOME':str(home)}
    note('$ FM_HOME=<disposable> '+command+' '+' '.join(args))
    p=subprocess.run(argv,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    LOG.write(p.stdout+p.stderr+f'[exit {p.returncode}]\n'); LOG.flush()
    if save: (E/save).write_text(p.stdout+p.stderr)
    assert p.returncode==rc,(command,p.returncode,p.stderr)
    return p.stdout

def backlog(h,queued,done=''):
    (h/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n'+queued+'\n\n## Done\n'+done+'\n')
def fleet(h,rows,age=0):
    (h/'data/blocked-by-fleet-rows.tsv').write_text(f'self\tlocal\ngenerated\t{int(time.time())-age}\nhomes\tlocal,other,third\n'+''.join('row\t'+'\t'.join(r)+'\n' for r in rows))
def verdict(h):
    return {a[0]:(a[3],a[4]) for line in run(h,'fm-blocked-by.sh','verdicts').splitlines() if len(a:=line.split('\t'))>=5}
def ready(h,save=None):
    out=run(h,'fm-tasks-axi.sh','ready',save=save)
    group=re.search(r'^ready\[\d+\].*\n((?:  [^\n]*\n)*)',out,re.M)
    return out, {line.strip().split(',')[0] for line in group[1].splitlines()} if group else set()
def snapshot(h):
    out=run(h,'fm-fleet-snapshot.sh','--json')
    return {r['id']:r['unresolved_blocker_ids'] for r in json.loads(out)['backlog']['records'] if r.get('structured')}

def row(id,target): return f'- [ ] {id} - Wait blocked-by: {target} (kind: ship) (repo: demo)'
with tempfile.TemporaryDirectory(prefix='live-',dir=ROOT/'.test-validation-tmp') as tmp:
    h=pathlib.Path(tmp)/'home'
    run(h,'fm-lab-home.sh','create',str(h))
    (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n')
    (h/'config/backend').write_text('tmux\n')
    note('SCENARIO archived x-person-region blockers clear; an open preference blocker remains')
    backlog(h,row('x-person-region','x-person-preferences blocked-by: x-region-registry blocked-by: x-record-ux-data-compat')+'\n- [ ] x-person-preferences - Open (kind: ship)')
    (h/'data/done-archive.md').write_text('## Archived\n- [x] x-region-registry - Delivered https://github.com/ashkonmousavi/NOT_Q/pull/2978\n- [x] x-record-ux-data-compat - Delivered https://github.com/ashkonmousavi/NOT_Q/pull/2700\n')
    fleet(h,[('local','x-region-registry','archive'),('local','x-record-ux-data-compat','archive'),('local','x-person-preferences','open')])
    out=run(h,'fm-blocked-by.sh','verdicts')
    assert '\tx-region-registry\tsatisfied\tarchive row https://github.com/ashkonmousavi/NOT_Q/pull/2978' in out
    assert '\tx-record-ux-data-compat\tsatisfied\tarchive row https://github.com/ashkonmousavi/NOT_Q/pull/2700' in out
    assert snapshot(h)['x-person-region']==['x-person-preferences']
    assert 'x-person-region' not in ready(h)[1]
    backlog(h,row('x-person-region','x-person-preferences blocked-by: x-region-registry blocked-by: x-record-ux-data-compat'),'- [x] x-person-preferences - Done')
    assert 'x-person-region' in ready(h)[1]
    assert snapshot(h)['x-person-region']==[]
    a=run(h,'fm-blocked-by.sh','verdicts'); assert a==run(h,'fm-blocked-by.sh','verdicts')
    note('PASS archived evidence cites both PRs, open blocker stops readiness, closing it releases; repeated reads agree')

    note('SCENARIO seven-hour list satisfies local completion but not absent IDs or remote open conflicts')
    backlog(h,'\n'.join([row('wait-done','done-id'),row('wait-archive','archive-id'),row('wait-unknown','ghost'),row('wait-remote','other:remote-id'),row('wait-self','local:done-id')]),'- [x] done-id - Done')
    (h/'data/done-archive.md').write_text('## Archived\n- [x] archive-id - Done\n')
    listed=[('local','done-id','done'),('local','archive-id','archive'),('other','remote-id','done')]
    fleet(h,listed,7*3600)
    v=verdict(h); assert v['wait-done'][0]==v['wait-archive'][0]==v['wait-self'][0]=='satisfied'; assert v['wait-unknown'][0]==v['wait-remote'][0]=='unknown'
    out,ids=ready(h,'stale-ready.txt'); assert ids=={'wait-done','wait-archive','wait-self'} and '(age 7h), covers local,other,third;' in out
    digest=run(h,'fm-session-start.sh','--reemit',save='stale-session-digest.txt',timeout=140)
    assert 'blocked_by_fleet_list: "fleet list stale: generated ' in digest and 'wait-done,queued' in digest
    fleet(h,listed+[('other','done-id','open'),('third','done-id','open'),('other','archive-id','open')],7*3600)
    v=verdict(h); assert v['wait-done'][0]==v['wait-archive'][0]==v['wait-self'][0]=='blocked'
    assert ready(h)[1]==set(); assert snapshot(h)['wait-done']==['done-id']
    fleet(h,listed)
    assert verdict(h)['wait-remote'][0]=='satisfied'
    (h/'data/blocked-by-fleet-rows.tsv').unlink()
    assert verdict(h)['wait-done'][0]=='unknown'; assert not ready(h)[1]
    fleet(h,[])
    assert verdict(h)['wait-done'][0]=='unknown'
    note('PASS stale local completion stays visible; remote opens override it; absent list/ID and stale remote completions stay UNKNOWN')

    note('SCENARIO real merged-PR marks are explicit, self-qualified, idempotent, reversible, and never override an open row')
    backlog(h,'\n'.join([row('plain','old'),row('self','local:old'),row('remote','other:old'),row('unmerged','closed')]))
    fleet(h,[('local','old','done'),('local','closed','done')])
    assert verdict(h)['plain'][0]=='unknown' # A merged PR alone does not clear an edge.
    run(h,'fm-blocked-by.sh','mark','unmerged','closed','--pr',CLOSED,rc=1)
    assert not (h/'data/blocked-by-marks.tsv').exists()
    run(h,'fm-blocked-by.sh','mark','plain','old','--pr',PR)
    run(h,'fm-blocked-by.sh','mark','self','local:old','--pr',PR)
    ledger=(h/'data/blocked-by-marks.tsv').read_text()
    note('Persisted append-only ledger:\n'+ledger)
    assert '\tself\tlocal:old\t'+PR in ledger
    assert 'already marked:' in run(h,'fm-blocked-by.sh','mark','self','local:old','--pr',PR)
    assert ledger==(h/'data/blocked-by-marks.tsv').read_text()
    run(h,'fm-blocked-by.sh','mark','remote','other:old','--pr',PR,rc=1)
    assert ready(h)[1]=={'plain','self'}
    assert snapshot(h)['self']==[]
    fleet(h,[('local','old','done'),('local','closed','done')],7*3600)
    assert ready(h)[1]=={'plain','self'}
    run(h,'fm-blocked-by.sh','unmark','self','local:old')
    assert ready(h)[1]=={'plain'} and snapshot(h)['self']==['local:old']
    fleet(h,[('local','old','done'),('other','old','open')],7*3600)
    assert verdict(h)['plain'][0]=='blocked'
    run(h,'fm-blocked-by.sh','mark','plain','old','--pr',PR,rc=1)
    note('PASS real merge verified; CLOSED refused; self qualifier retained; repeat is no-op; unmark and remote open restore blocking')

    note('SCENARIO PR ownership selects the citing home or unique branch identity; ambiguous and incomplete evidence never guesses')
    PR2='https://github.com/cli/cli/pull/14910'
    backlog(h,'- [ ] same - Local prep (kind: scout)')
    fleet(h,[('other','same','open','-'),('third','same','open',PR),('other','branch-only','archive','-')])
    a=run(h,'fm-pr-owner.sh',PR,'--branch','fm/same'); assert a.startswith('known\tthird\tsame\telsewhere\t')
    assert run(h,'fm-pr-owner.sh',PR2,'--branch','fm/branch-only').startswith('known\tother\tbranch-only\telsewhere\t')
    fleet(h,[('other','same','open',PR),('third','same','open',PR)])
    assert run(h,'fm-pr-owner.sh',PR,'--branch','fm/same',rc=3).startswith('unknown\tlocal,other,third\there\t')
    fleet(h,[('other','same','open','https://github.com/other/repo/pull/14918'),('third','build','done',PR)])
    assert run(h,'fm-pr-owner.sh',PR,'--branch','fm/absent').startswith('known\tthird\tbuild\telsewhere\t')
    fleet(h,[('other','same','open',PR)],7*3600)
    assert run(h,'fm-pr-owner.sh',PR,'--branch','fm/same',rc=3).startswith('unknown\tlocal\there\t')
    (h/'data/blocked-by-fleet-rows.tsv').unlink()
    assert run(h,'fm-pr-owner.sh',PR,'--branch','fm/same',rc=3).startswith('unknown\t.\there\t')
    note('PASS branch identity, unique citation, ambiguous candidates, full URL matching, stale and absent ownership verified')
note('ALL SCENARIOS PASSED; disposable home removed')
LOG.close()
print('Live blocked-by scenarios passed; transcript:',E/'live-blocked-by.log')
