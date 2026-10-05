import os, pathlib, subprocess, tempfile, shutil, re, json, sys
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/home/zcrew/.no-mistakes/evidence/01M45JNGXNRJ522PPBNYHJF1VA')
records = []
log = (EVIDENCE / 'live-depth-transcript.log').open('w')
LAB = pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.', dir=ROOT / '.test-phase'))
env = {k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('TASKS_AXI') or k in ['TMUX', 'TMUX_PANE'])}
env.update(FM_HOME=str(LAB), FM_BACKEND='tmux', TMUX='.test-phase/absent-private-socket,0,0', TMUX_TMPDIR=str(LAB / 'tmux'), TMPDIR=str(ROOT / '.test-phase/tmp'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')

def run(args, label, check=None):
    p = subprocess.run(args, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
    log.write('\n$ ' + ' '.join(str(x) for x in args) + '\n' + p.stdout + '\nraw exit: ' + str(p.returncode) + '\n')
    log.flush()
    if check is not None:
        assert p.returncode == check, (label, p.returncode, p.stdout)
    return p

def lib(fn, prep):
    return run(['bash', '-c', 'set -o pipefail; . bin/fm-dod-lib.sh; "$1" "$2"', '_', fn, str(prep)], fn)

def record(name, p, detail):
    records.append(dict(name=name, result='pass', live=True, raw_exit=p.returncode, detail=detail))
    log.write('OBSERVATION ' + name + ': ' + detail + '\n')
    log.flush()

def scaffold(id, fmt, selected):
    run(['bash', 'bin/fm-brief.sh', id, 'proj', '--mode', selected], 'brief scaffold', 0)
    brief = LAB / 'data' / id / 'brief.md'
    brief.write_text(brief.read_text().replace('{TASK}', 'Verify only the isolated delivery admission contract.').replace('{FIRSTMATE_SPEC}', 'Do not modify any source or contact external services; this disposable CLI scenario stops before an agent launches.'))
    run(['bash', 'bin/fm-brief.sh', id, '--prep'] + (['--surgical'] if fmt == 'surgical' else []), 'prep scaffold', 0)
    prep = LAB / 'data' / id / 'prep.md'
    raw = prep.read_text()
    assert len(re.findall(r'^- Delivery depth:', raw, re.M)) == 1 and '- Delivery depth: {DELIVERY_DEPTH}' in raw
    (EVIDENCE / ('generated-' + fmt + '-prep.md')).write_text(raw)
    values = {'Q1':'yes' if fmt == 'surgical' else 'no', 'Q2':'no', 'UI_WIRING':'no, isolated command admission only.', 'Q1_REASON':'Confined admission output inspected.', 'Q2_REASON':'No shared application module is changed.', 'INTENT_AND_BOXES':'Exercise the delivery decision through an isolated public CLI.'}
    for i in range(1,6):
        values['C'+str(i)]='yes'
        values['C'+str(i)+'_EVIDENCE']='bin/fm-spawn.sh:1674; confined owner, reproduced boundary, focused check, no sensitive paths.'
    for key, value in values.items():
        raw = raw.replace('{'+key+'}', value)
    prep.write_text(raw)
    run(['bash', '-c', '. tests/prep-record-helper.sh; fm_test_fill_prep_common "$1" direct-PR', '_', str(prep)], 'fill common author fields', 0)
    raw = prep.read_text()
    raw = re.sub(r'^\{[A-Z0-9_]+\}$', 'n/a: this isolated admission demonstration has no application changes.', raw, flags=re.M)
    prep.write_text(raw)
    return prep

def depth(text, mode):
    choice = 'checks-only (direct-PR)' if mode == 'direct-PR' else 'checks + AI review (no-mistakes)'
    return re.sub(r'^- Delivery depth:.*$', '- Delivery depth: '+choice+', verify the explicit admission decision.', text, flags=re.M)

def set_brief_mode(id, mode):
    # Regenerate the public brief so its delivery contract agrees with the selected flag.
    brief = LAB / 'data' / id / 'brief.md'
    brief.unlink()
    run(['bash', 'bin/fm-brief.sh', id, 'proj', '--mode', mode], 'matching brief scaffold', 0)
    brief.write_text(brief.read_text().replace('{TASK}', 'Verify the isolated delivery decision.').replace('{FIRSTMATE_SPEC}', 'Do not change source or contact external services.'))

def spawn(id, selected):
    return run(['bash', 'bin/fm-spawn.sh', id, str(LAB / 'projects/proj'), 'codex', '--mode', selected, '--yolo', 'off'], id)

def no_alloc(id):
    assert not (LAB / 'data' / id / 'launch-brief.md').exists()
    assert not (LAB / 'state' / (id+'.meta')).exists()
    assert not list((LAB / 'state').rglob('*lock*'))
    assert not list((LAB / 'projects').rglob('.git/worktrees'))
    assert not (ROOT / '.test-phase/absent-private-socket').exists()
    log.write('POSTCONDITION: no launch brief, task metadata, task lock, worktree allocation or private endpoint\n')

def matched(id, selected, label):
    set_brief_mode(id, selected)
    p=spawn(id, selected)
    launch=LAB / 'data' / id / 'launch-brief.md'
    assert launch.exists(), p.stdout
    assert 'Delivery depth' not in p.stdout, p.stdout
    assert 'absent-private-socket' in p.stdout and ('connecting' in p.stdout or 'server' in p.stdout), p.stdout
    assert p.returncode != 0
    (EVIDENCE / (id+'-launch-brief.md')).write_text(launch.read_text())
    record(label, p, 'Admission rendered the launch brief and reached the real tmux client; only the intentionally absent private socket refused. No agent or model was substituted or launched.')
    launch.unlink()
    return p

try:
    run(['bash', 'bin/fm-lab-home.sh', 'create', str(LAB)], 'mint disposable home', 0)
    (LAB / 'tmux').mkdir()
    (LAB / 'config/backlog-backend').write_text('manual\n')
    (LAB / 'projects/proj').mkdir()
    run(['git', '-C', str(LAB / 'projects/proj'), 'init', '-q'], 'initialize disposable project', 0)
    log.write('Isolation: marked FM_HOME, no FM_*_OVERRIDE, no FM_GATE_REFUSE_BYPASS or FM_TEST_SEAM; real system tmux addressed only through an absent private socket.\n')
    for fmt in ['full','surgical']:
        id='live-'+fmt
        prep=scaffold(id, fmt, 'direct-PR')
        baseline=prep.read_text()
        p=lib('fm_prep_unfilled_reason', prep)
        assert p.returncode == 1 and not p.stdout, p.stdout
        record(fmt+' canonical checks-only completeness', p, 'Empty reason and raw exit 1 on the fully answered generated record.')
        for mode in ['direct-PR','no-mistakes']:
            prep.write_text(depth(baseline, mode))
            p=lib('fm_prep_delivery_mode', prep)
            assert p.returncode == 0 and p.stdout.strip() == mode
            p=lib('fm_prep_unfilled_reason', prep)
            assert p.returncode == 1 and not p.stdout, p.stdout
            matched(id, mode, fmt+' matching '+mode+' continues to real backend')
            opposite='no-mistakes' if mode == 'direct-PR' else 'direct-PR'
            set_brief_mode(id, opposite)
            p=spawn(id, opposite)
            choice='checks-only (direct-PR)' if mode=='direct-PR' else 'checks + AI review (no-mistakes)'
            assert p.returncode != 0 and '--mode '+opposite in p.stdout and choice in p.stdout and id in p.stdout and 'reconcile' in p.stdout, p.stdout
            no_alloc(id)
            record(fmt+' contradicting '+opposite+' refuses '+mode, p, 'Diagnostic names task, selected flag, declared depth and reconciliation; refusal leaves no allocation artifacts.')
            matched(id, 'local-only', fmt+' local-only accepts authored '+mode)
        variants={
            'missing':'', 'empty':'- Delivery depth:', 'placeholder':'- Delivery depth: {DELIVERY_DEPTH}',
            'unknown':'- Delivery depth: fast, isolated reason.',
            'both':'- Delivery depth: checks-only (direct-PR), checks + AI review (no-mistakes)',
            'duplicate':'- Delivery depth: checks-only (direct-PR), isolated reason.\n- Delivery depth: checks-only (direct-PR), isolated reason.',
            'conflicting':'- Delivery depth: checks-only (direct-PR), isolated reason.\n- Delivery depth: checks + AI review (no-mistakes), shared reason.',
            'reasonless':'- Delivery depth: checks-only (direct-PR),',
            'placeholder-reason':'- Delivery depth: checks-only (direct-PR), {REASON}',
            'na':'- Delivery depth: n/a: isolated reason.',
            'na-reason':'- Delivery depth: checks-only (direct-PR), n/a: isolated reason.',
            'continuation':'- Delivery depth: checks-only (direct-PR),\n  this next line cannot supply the reason.',
            'fenced':'```\n- Delivery depth: checks-only (direct-PR), isolated reason.\n```',
            'indented':'\n    - Delivery depth: checks-only (direct-PR), isolated reason.',
            'comment-only':'<!-- - Delivery depth: checks-only (direct-PR), isolated reason. -->'}
        set_brief_mode(id, 'direct-PR')
        for name, replacement in variants.items():
            prep.write_text(re.sub(r'^- Delivery depth:.*$', lambda m:replacement, baseline, flags=re.M))
            p=lib('fm_prep_unfilled_reason', prep)
            assert p.returncode == 0 and 'Delivery depth' in p.stdout, (name,p.stdout)
            p=spawn(id,'direct-PR')
            assert p.returncode != 0 and 'Delivery depth' in p.stdout, (name,p.stdout)
            no_alloc(id)
            record(fmt+' '+name+' depth refuses', p, 'Library reason/raw exit 0 and executable refusal both name Delivery depth; no allocation artifacts.')
        for mode in ['direct-PR','no-mistakes']:
            opposite='no-mistakes' if mode=='direct-PR' else 'direct-PR'
            oldchoice='checks-only (direct-PR)' if opposite=='direct-PR' else 'checks + AI review (no-mistakes)'
            old='<!-- Retired record example\n## Tier\n'+('- Preparation format: surgical\n' if fmt=='surgical' else '')+'- Q1 does this change alter what a user sees or can do: no\nReason: old confined example.\n- Q2 does this change touch a shared module or a contract: no\nReason: old isolated example.\n- UI wiring: no, retired example.\n- Delivery depth: '+oldchoice+', retired example.\n-->\n'
            active=depth(baseline,mode)
            prep.write_text(old+active)
            (EVIDENCE / ('commented-old-tier-'+fmt+'-'+mode+'.md')).write_text(prep.read_text())
            p=lib('fm_prep_delivery_mode',prep)
            assert p.returncode == 0 and p.stdout.strip() == mode, p.stdout
            p=lib('fm_prep_unfilled_reason',prep)
            assert p.returncode == 1 and not p.stdout, p.stdout
            set_brief_mode(id,opposite)
            p=spawn(id,opposite)
            assert p.returncode != 0 and '--mode '+opposite in p.stdout, p.stdout
            no_alloc(id)
            record(fmt+' retired '+opposite+' Tier cannot override active '+mode, p, 'Whole-document comment context selects the live declaration and refuses its contradictory flag without allocation.')
            matched(id,mode,fmt+' retired Tier matching active '+mode+' admits')
            matched(id,'local-only',fmt+' retired Tier local-only with '+mode+' admits')
            for name,replacement in [('missing',''),('malformed','- Delivery depth: unknown, active invalid answer.')]:
                prep.write_text(old+re.sub(r'^- Delivery depth:.*$',replacement,active,flags=re.M))
                p=lib('fm_prep_unfilled_reason',prep)
                assert p.returncode == 0 and 'Delivery depth' in p.stdout, p.stdout
                p=spawn(id,mode)
                assert p.returncode != 0 and 'Delivery depth' in p.stdout
                no_alloc(id)
                record(fmt+' retired Tier cannot rescue '+name+' active '+mode, p, 'Commented canonical answer cannot certify missing or malformed active depth.')
        prep.write_text(depth(baseline,'direct-PR'))
        (EVIDENCE / ('filled-'+fmt+'-prep.md')).write_text(prep.read_text())
    print('Live CLI depth scenarios completed:', len(records))
except Exception as exc:
    log.write('\nDRIVER FAILURE: '+repr(exc)+'\n')
    print(repr(exc),file=sys.stderr)
    raise
finally:
    (EVIDENCE / 'live-depth-results.json').write_text(json.dumps(records,indent=2)+'\n')
    shutil.rmtree(LAB)
    log.write('\nCLEANUP: disposable marked home and project removed.\n')
    log.close()
