import os, subprocess, pathlib, tempfile, time
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M6PYWK8CF5K753X1RN1KN9J8')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','HERDR_','REX_')) and k not in ('TMUX','TMUX_PANE')}
env['TMPDIR']=str(ROOT/'.test-validation-tmp')
log=(E/'live-routing.log').open('w')
def note(s): log.write('\n'+s+'\n'); log.flush()
def run(h,cmd,*args,timeout=180):
    note('$ FM_HOME=<disposable> '+cmd+' '+' '.join(args))
    p=subprocess.run([str(ROOT/'bin'/cmd),*args],env=env|{'FM_HOME':str(h)},text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    log.write(p.stdout+p.stderr+f'[exit {p.returncode}]\n');log.flush()
    assert p.returncode==0,(cmd,p.stderr)
    return p.stdout

def home(path):
    run(path,'fm-lab-home.sh','create',str(path))
    (path/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n')
    return path

def fleet(h,rows,age=0):
    (h/'data/blocked-by-fleet-rows.tsv').write_text(f'self\tlocal\ngenerated\t{int(time.time())-age}\nhomes\tlocal,other,third\n'+''.join('row\t'+'\t'.join(r)+'\n' for r in rows))
with tempfile.TemporaryDirectory(prefix='routing-',dir=ROOT/'.test-validation-tmp') as tmp:
    t=pathlib.Path(tmp); h=home(t/'home')
    note('SCENARIO autolaunch lists only genuinely ready prepared scouts')
    (h/'data/backlog.md').write_text('## Queued\n- [ ] good - Ready blocked-by: delivered (kind: scout) (repo: demo)\n- [ ] bad - Unknown blocked-by: ghost (kind: scout) (repo: demo)\n## Done\n- [x] delivered - Done\n')
    (h/'projects/demo').mkdir()
    for id in ['good','bad']:
        (h/'data'/id).mkdir(); (h/'data'/id/'brief.md').write_text('Prepared scout\n'); (h/'data'/id/'prep.md').write_text('Accepted prep\n')
    fleet(h,[('local','delivered','done')],7*3600)
    assert run(h,'fm-autolaunch.sh','--list-prepared').strip()=='good'
    fleet(h,[('local','delivered','done'),('other','delivered','open')],7*3600)
    assert run(h,'fm-autolaunch.sh','--list-prepared').strip()==''
    note('PASS autolaunch exposes the completed dependency only, then withholds it when another home holds it open')

    note('SCENARIO real public conflicting PR dry-run routes to the unique citing home, never registry order or local done namesake')
    task='add-json-jq-pr-create'; pr='https://github.com/cli/cli/pull/13798'
    other=home(t/'other'); third=home(t/'third')
    for mate in [other,third]: (mate/'data/backlog.md').write_text(f'## Queued\n- [ ] {task} - Open build (kind: ship) (repo: demo)\n')
    (h/'data/backlog.md').write_text(f'## Queued\n## Done\n- [x] {task} - Local old prep (kind: scout) (repo: demo)\n')
    (h/'data/projects.md').write_text('- demo [direct-PR branch=] - public CLI fixture\n')
    (h/'data/secondmates.md').write_text(f'- other - First registry home (home: {other}; scope: demo; projects: demo; added 2026-11-05)\n- third - Actual build owner (home: {third}; scope: demo; projects: demo; added 2026-11-05)\n')
    (h/'config/pr-triage-rules').write_text('repo=cli/cli\nproject=demo\ntitle=^Add JSON output support to pr create$\n')
    rows=[('other',task,'open','-'),('third',task,'open',pr)]
    fleet(h,rows)
    out=run(h,'fm-pr-triage.sh')
    selected=[line for line in out.splitlines() if pr in line]
    assert any('refused:owned by third: steered '+task in s for s in selected),selected
    assert 'third --one-way' in out and 'other --one-way' not in out
    assert not (h/'state/pr-triage.log').exists()
    fleet(h,[('other',task,'open',pr),('third',task,'open',pr)])
    out=run(h,'fm-pr-triage.sh')
    assert any(pr in s and 'owner UNKNOWN' in s and 'candidate homes local,other,third' in s for s in out.splitlines())
    assert '--one-way' not in out
    fleet(h,rows,7*3600)
    out=run(h,'fm-pr-triage.sh')
    assert any(pr in s and 'owner UNKNOWN' in s and 'fleet list stale' in s for s in out.splitlines())
    assert '--one-way' not in out
    note('PASS real GitHub PR and real home backlogs: correct home selected; ambiguity and stale evidence refuse; no messages, workers, or GitHub writes')
note('ALL SCENARIOS PASSED; disposable homes removed')
log.close(); print('Live routing passed; transcript:',E/'live-routing.log')
