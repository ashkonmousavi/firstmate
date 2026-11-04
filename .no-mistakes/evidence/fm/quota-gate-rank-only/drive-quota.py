import copy, datetime, hashlib, json, os, pathlib, shutil, subprocess

ROOT = pathlib.Path('~/.no-mistakes/worktrees/049a88734b0e/01M6K2Y2DSAB6SW983JD0NTC91')
EVIDENCE = pathlib.Path('~/.no-mistakes/evidence/01M6K2Y2DSAB6SW983JD0NTC91')
LAB = ROOT / '.q'
log = (EVIDENCE / 'live-quota-transcript.txt').open('w')
results = []
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) or key in ('TMUX', 'TMUX_PANE', 'OPENAI_API_KEY', 'CODEX_API_KEY', 'CLAUDE_CONFIG_DIR', 'ANTHROPIC_API_KEY'):
        env.pop(key, None)
env.update(FM_HOME=str(LAB), TMPDIR=str(ROOT / '.quota-test-tmp'))

def run(args, label, updates=None):
    e = env | (updates or {})
    p = subprocess.run(args, cwd=ROOT, env=e, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    log.write('\n### '+label+'\n$ '+ ' '.join(args)+'\n'+p.stdout+'exit='+str(p.returncode)+'\n'); log.flush()
    return p

def expect(label, predicate):
    results.append(dict(name=label, passed=bool(predicate)))
    if not predicate: raise AssertionError(label)

def digest_home():
    return {str(p.relative_to(LAB)): hashlib.sha256(p.read_bytes()).hexdigest() for p in LAB.rglob('*') if p.is_file()}

try:
    assert not LAB.exists()
    p = run(['bash', 'bin/fm-lab-home.sh', 'create', str(LAB)], 'Create marked isolated home')
    expect('marked lab creation', p.returncode == 0)
    (LAB / 'user-home').mkdir()
    (LAB / 'projects/sample').mkdir(parents=True)
    (LAB / 'data/preview').mkdir()
    (LAB / 'config/backend').write_text('tmux\n')
    (LAB / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (LAB / 'data/backlog.md').write_text('## In flight\n## Queued\n- [ ] preview - preview quota selection (repo: sample) (kind: scout)\n## Done\n')
    (LAB / 'data/preview/brief.md').write_text('# Task\nObserve quota admission in this isolated preview.\n')
    (LAB / 'data/preview/prep.md').write_text('Prepared isolated quota preview.\n')
    (LAB / 'data/preview/autolaunch-prep').write_text('project=sample\nkind=scout\n')
    rules = LAB / 'config/crew-dispatch.json'
    rules.write_text(json.dumps({'default':[{'harness':'claude','model':'opus'}, {'harness':'codex','model':'gpt-5.5'}]}))
    baseline = json.loads((ROOT / 'tests/fixtures/quota-axi-healthy.json').read_text())
    baseline['generatedAt']=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    uncertain = copy.deepcopy(baseline)
    exhausted = copy.deepcopy(baseline)
    for row in uncertain['providers']:
        if row['provider'] == 'claude':
            for bound in row['quotaSemantics']['effectiveAvailability']:
                bound['runway']={'status':'projected_exhaustion','projectionConfidence':'established'}
                bound['selection']['spendPriority']=9
        elif row['provider']=='codex':
            for bound in row['quotaSemantics']['effectiveAvailability']: bound['selection']['spendPriority']=2
    for row in exhausted['providers']:
        for bound in row['quotaSemantics']['effectiveAvailability']:
            bound.update(effectivePercentRemaining=0, runway={'status':'exhausted_now'})
            bound['selection']['spendPriority']=9 if row['provider']=='codex' else 2
    uncertain_path=LAB/'uncertain.json'; uncertain_path.write_text(json.dumps(uncertain))
    exhausted_path=LAB/'exhausted.json'; exhausted_path.write_text(json.dumps(exhausted))
    setting=LAB/'config/quota-gate'
    for policy in ('absent','rank-only'):
        if policy=='rank-only': setting.write_text('rank-only\n')
        p=run(['bash','bin/fm-autolaunch.sh','--dry-run'], 'Preview: pass priority 2 before notice priority 9; policy='+policy,
            {'HOME':str(LAB/'user-home'),'FM_QUOTA_SNAPSHOT_FILE':str(uncertain_path)})
        expect('preview passing-first '+policy, p.returncode==0 and '--harness codex --model gpt-5.5' in p.stdout)
        if setting.exists(): setting.unlink()
    for policy in ('absent','rank-only'):
        if policy=='rank-only': setting.write_text('rank-only\n')
        p=run(['bash','bin/fm-autolaunch.sh','--dry-run'], 'Preview: all defaults exhausted; policy='+policy,
            {'HOME':str(LAB/'user-home'),'FM_QUOTA_SNAPSHOT_FILE':str(exhausted_path)})
        expect('preview all-exhausted '+policy, p.returncode==0 and (('--harness codex --model gpt-5.5' in p.stdout) if policy=='rank-only' else ('refused:quota:' in p.stdout and 'would-run:' not in p.stdout)))
        if setting.exists(): setting.unlink()
    for value in ('typo\n','', ' \n','rank-only\n\n', 'rank-only\r\n'):
        setting.write_bytes(value.encode())
        for attempt in range(2):
            before=digest_home()
            p=run(['bash','bin/fm-autolaunch.sh','--dry-run'], 'Preview invalid setting '+repr(value)+' attempt='+str(attempt+1),
                {'HOME':str(LAB/'user-home'),'FM_QUOTA_SNAPSHOT_FILE':str(exhausted_path)})
            expect('invalid preview diagnostic and no write '+repr(value)+' '+str(attempt), p.returncode==0 and 'expected rank-only' in p.stdout and 'refused:quota:' in p.stdout and before==digest_home())
    # Drive explicit spawn's real executable boundary. Deliberately leave
    # resource capacity unconfigured, so an admitted quota gate cannot launch
    # an unrequested native worker or access operator account data.
    (LAB/'data/explicit').mkdir()
    (LAB/'data/explicit/brief.md').write_text('# Task\n## Captain\'s intent\nObserve quota admission.\n## Firstmate spec\nNo source changes or network work.\n')
    short = copy.deepcopy(baseline)
    for row in short['providers']:
        if row['provider']=='claude':
            for bound in row['quotaSemantics']['effectiveAvailability']:
                bound['runway']={'status':'projected_exhaustion','projectionConfidence':'established','usableRunwaySeconds':7200}
    short_path=LAB/'short.json'; short_path.write_text(json.dumps(short))
    long = copy.deepcopy(short)
    for row in long['providers']:
        if row['provider']=='claude':
            for bound in row['quotaSemantics']['effectiveAvailability']: bound['runway']['usableRunwaySeconds']=14400
    long_path=LAB/'long.json'; long_path.write_text(json.dumps(long))
    for shape,snapshot in [('short',short_path),('exhausted',exhausted_path),('long',long_path)]:
        for policy in ('absent','rank-only'):
            if policy=='rank-only': setting.write_text('rank-only\n')
            elif setting.exists(): setting.unlink()
            p=run(['bash','bin/fm-spawn.sh','explicit',str(LAB/'projects/sample'),'--scout','--harness','claude','--model','opus','--backend','tmux'],
                'Explicit spawn '+shape+' quota; policy='+policy,
                {'HOME':str(LAB/'user-home'),'FM_QUOTA_SNAPSHOT_FILE':str(snapshot)})
            gate_ok = ('proceeding under config/quota-gate=rank-only' in p.stdout and 'refuses explicit harness' not in p.stdout) if policy=='rank-only' else 'refuses explicit harness claude' in p.stdout
            if shape=='long': gate_ok=('refuses explicit harness' not in p.stdout and 'within the 3h0m spawn horizon' not in p.stdout and 'deferred:' in p.stdout)
            expect('explicit quota boundary '+shape+' '+policy, gate_ok)
    setting.write_text('rank-only\n')
    account=LAB/'signed-out'; (account/'rules').mkdir(parents=True)
    (account/'config.toml').write_text('cli_auth_credentials_store="file"\nmodel="gpt-5.5"\n')
    (account/'AGENTS.md').write_text('')
    (account/'rules/default.rules').write_text('prefix_rule(pattern=["echo"],decision="allow")\n')
    (LAB/'config/codex-accounts').write_text(str(account)+'\n')
    p=run(['codex','-c','cli_auth_credentials_store="file"','login','status'], 'Real Codex signed-out status',
        {'HOME':str(LAB/'user-home'), 'CODEX_HOME':str(account)})
    expect('real Codex rejects signed-out local root', p.returncode!=0)
    for command in ('preflight','select'):
        p=run(['python3','bin/fm-codex-accounts.py',command,'--config',str(LAB/'config/codex-accounts'),'--model','gpt-5.5'],
            'Native account '+command+' retains authentication refusal under rank-only', {'HOME':str(LAB/'user-home')})
        expect('authentication refusal '+command, p.returncode==1 and 'no usable signed-in folder' in p.stdout)
    p=run(['python3','bin/fm-codex-accounts.py','select','--config',str(LAB/'config/codex-accounts'),'--folder',str(account),'--model','gpt-5.5'],
        'Preselected signed-out account remains refused', {'HOME':str(LAB/'user-home')})
    expect('preselected authentication refusal',p.returncode==1 and 'no longer usable' in p.stdout)
finally:
    shutil.rmtree(LAB, ignore_errors=True)
    log.write('\nDisposed isolated home. No native worker was launched by these preview/authentication scenarios.\n');log.close()
    (EVIDENCE/'live-quota-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
