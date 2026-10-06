from pathlib import Path
import os, subprocess, shutil, time, shlex, json
ROOT=Path.cwd()
E=Path('/home/tegris/.no-mistakes/evidence/01M49EBAM259QST2W72QEEJVGG')
log=(E/'r2-live-product.log').open('w',buffering=1)
env=os.environ.copy()
for k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX','TMUX_PANE','HERDR_ENV','HERDR_PANE_ID','CLAUDECODE'):
    env.pop(k,None)
env['FM_BOOTSTRAP_NETWORK']='skip'
homes=[]
labenv=None
results=[]
def check(name,ok):
    results.append({'check':name,'pass':bool(ok)})
    log.write(('PASS ' if ok else 'FAIL ')+name+'\n')
    assert ok,name

def run(args,ev,name,allowed=(0,)):
    r=subprocess.run(args,cwd=ROOT,env=ev,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
    (E/(name+'.txt')).write_text(r.stdout)
    log.write('$ '+shlex.join(args)+'\n'+r.stdout+'\nexit='+str(r.returncode)+'\n')
    assert r.returncode in allowed,(name,r.returncode)
    return r.stdout

def home(n):
    p=E/n
    assert not p.exists(),str(p)
    run(['bin/fm-lab-home.sh','create',str(p)],env,'r2-lab-create-'+n)
    homes.append(p)
    return p

try:
    primary=home('.lp'); secondary=home('.ls'); fresh=home('.lt')
    ev=dict(env,FM_HOME=str(primary))
    out=run(['bin/fm-bootstrap.sh'],ev,'r2-fresh-bootstrap')
    check('Fresh primary creates no retired setting and emits no retired diagnostic',not (primary/'config/startup-memory-budget').exists() and 'STARTUP_MEMORY_BUDGET' not in out)
    (primary/'config/startup-memory-budget').write_text('invalid-legacy-setting\n')
    out=run(['bin/fm-bootstrap.sh'],ev,'r2-legacy-bootstrap')
    check('Invalid legacy setting is ignored and preserved', (primary/'config/startup-memory-budget').read_text()=='invalid-legacy-setting\n' and 'STARTUP_MEMORY_BUDGET' not in out)
    out=run(['bin/fm-session-start.sh'],ev,'r2-legacy-session-start')
    check('Restart digest has no retired diagnostic and preserves invalid legacy file','CONTEXT' in out and 'STARTUP_MEMORY_BUDGET' not in out and (primary/'config/startup-memory-budget').read_text()=='invalid-legacy-setting\n')
    for ident,h in [('local-old',secondary),('local-fresh',fresh)]:
        (h/'bin').mkdir()
        shutil.copyfile(ROOT/'AGENTS.md',h/'AGENTS.md')
        (h/'.fm-secondmate-home').write_text(ident+'\n')
        (primary/('state/'+ident+'.meta')).write_text('kind=secondmate\nhome='+str(h)+'\nharness=claude\nbackend=tmux\n')
    (secondary/'config/startup-memory-budget').write_text('1\n')
    out=run(['bin/fm-config-push.sh'],ev,'r2-config-push')
    check('Config push neither lists nor creates the retired item; old secondary file untouched', 'startup-memory-budget' not in out and not (fresh/'config/startup-memory-budget').exists() and (secondary/'config/startup-memory-budget').read_text()=='1\n')
    reg=''.join('- '+ident+' - lab (home: '+str(h)+'; scope: testing; projects: alpha; added 2026-10-06)\n' for ident,h in [('local-old',secondary),('local-fresh',fresh)])
    (primary/'data/secondmates.md').write_text(reg)
    out=run(['bin/fm-stow-cascade.sh'],ev,'r2-local-cascade')
    check('Local cascade reports both homes and direct transports without budget_report',out.count('transport=direct')==2 and out.count('placement=local')==2 and 'budget_report=' not in out)
    remote='- remote-old - lab (host: fm-lab-uncontacted; root: /disposable/root; home: /disposable/old; scope: testing; projects: alpha; added 2026-10-06)\n'
    (primary/'data/secondmates.md').write_text(reg+remote)
    out=run(['bin/fm-stow-cascade.sh'],ev,'r2-deferred-cascade',(3,))
    check('Unupdated remote without endpoint is deferred and does not prevent local resolution','transport=deferred' in out and 'secondmates=3' in out and 'budget_report=' not in out)
    today=time.strftime('%Y-%m-%d')
    pointer='<!-- memory tiers: see the stow skill -->\n'
    current='Fleet-wide dispatch must resolve the registered home before selecting its transport.'
    stale='Completed lab release 0.0.1 used the superseded path /disposable/obsolete.'
    expired='Temporary compatibility workaround for closed lab ticket LAB-OLD was retired when that ticket closed.'
    conditional='When debugging LAB-CALIBRATION batch traces, preserve the local batch identifier before replay, compare the stored sampling interval with the trace header, and inspect the recorded sequence before deciding whether to rebuild the lab sample. These checks belong to the calibration investigation only and are irrelevant to dispatch, session recovery, and every other fleet task.'
    (primary/'data/captain.md').write_text('# Captain\n'+pointer+'- Never discard unlanded work without explicit authority.\n')
    (primary/'data/captain-shared.md').write_text('# Shared captain\n'+pointer+'- Report observed outcomes faithfully and disclose remaining gaps.\n')
    (primary/'data/learnings.md').write_text('# Learnings\n'+pointer+'- '+current+' <!--a:'+today+'-->\n- '+current+' <!--a:'+today+'-->\n- '+stale+' <!--a:2026-01-01-->\n- '+expired+' <!--p:2026-01-01-->\n- '+conditional+' <!--a:'+today+'-->\n')
    (primary/'data/lab-calibration.md').write_text('# Lab calibration owner\nRead only when debugging LAB-CALIBRATION batch traces.\n')
    (secondary/'data/learnings.md').write_text('# Learnings\n'+pointer+'- Finished secondary incident used the superseded lab path /disposable/old-secondary. <!--a:2026-01-01-->\n')
    (secondary/'data/captain-shared.md').write_text('# Shared captain\n'+pointer+'- Keep unresolved authority boundaries explicit.\n')
    shared=(secondary/'data/captain-shared.md').read_bytes()
    # Only populated local secondary and unreachable remote in the stow cascade.
    (primary/'data/secondmates.md').write_text(reg.splitlines(True)[0]+remote)
    for p in (primary/'state').glob('*.meta'): p.unlink()
    (primary/'config/startup-memory-budget').write_text('1\n')
    (primary/'config/supervision-host-off').touch()
    (primary/'tmux').mkdir()
    labenv=dict(ev,TMUX_TMPDIR=str(primary/'tmux'),CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false')
    for role,h in [('primary',primary),('secondary',secondary)]: shutil.copytree(h/'data',E/('r2-stow-before-'+role))
    prompt='/stow This is a disposable lab primary with FM_HOME='+str(primary)+'. Curate only this home and its registered disposable local secondmate '+str(secondary)+'. Use the tracked internal stow skill and its normal cascade. The existing private note data/lab-calibration.md already owns the LAB-CALIBRATION batch-trace investigation trigger; consider that live owner in your retention plan. LAB-OLD is closed. No independent current-session evidence confirms the completed old primary release or secondary incident. There are no open work records or uncaptured durable findings. Do not modify tracked source, any other home, credential stores, or tool configuration. Do not create/control pipelines, launch workers, or contact external services other than this harness model call. The registered remote has no endpoint and must stay untouched. All primary data lives under FM_HOME, not cwd data. Produce the normal completion receipt and finish.'
    (E/'r2-stow-prompt.txt').write_text(prompt)
    args=['claude','-p','--permission-mode','auto','--no-session-persistence','--setting-sources','project','--strict-mcp-config','--disallowedTools','Agent,Task,TaskCreate,TaskUpdate,TaskList,TaskGet','--add-dir',str(primary),'--add-dir',str(secondary),'--verbose','--output-format','stream-json',prompt]
    cli=shlex.join(args)+' > '+shlex.quote(str(E/'r2-stow-native.jsonl'))+' 2> '+shlex.quote(str(E/'r2-stow-native.stderr'))
    run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',str(ROOT),'-e','FM_HOME='+str(primary),cli],labenv,'r2-native-launch')
    deadline=time.monotonic()+480
    while time.monotonic()<deadline:
        r=subprocess.run(['tmux','-L','fm-lab','has-session','-t','primary'],env=labenv,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if r.returncode:break
        time.sleep(3)
    else:
        run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary'],labenv,'r2-timeout-pane')
        raise AssertionError('Native primary timed out after 480s')
    for role,h in [('primary',primary),('secondary',secondary)]: shutil.copytree(h/'data',E/('r2-stow-after-'+role))
    records=[json.loads(s) for s in (E/'r2-stow-native.jsonl').read_text().splitlines() if s.strip()]
    receipts=[r for r in records if r.get('type')=='result']
    check('Normal signed-in Claude primary completes stow',bool(receipts) and not receipts[-1].get('is_error'))
    receipt=receipts[-1].get('result','')
    (E/'r2-stow-receipt.md').write_text(receipt)
    before=(E/'r2-stow-before-primary/learnings.md').read_text()
    after=(primary/'data/learnings.md').read_text()
    archive=(primary/'data/memory-archive.md').read_text()
    check('Stale aging and expired perishable entries recoverable with provenance',stale not in after and expired not in after and stale in archive and expired in archive and 'learnings.md' in archive and '2026-01-01' in archive)
    check('Current fleet rule survives and duplicate is consolidated despite size limit 1',after.count(current)==1)
    note=(primary/'data/lab-calibration.md').read_text()
    check('Current conditional material relocates to existing private triggered owner','preserve the local batch identifier' in note.lower() and 'sampling interval' in note and 'recorded sequence' in note and conditional not in after)
    secondary_after=(secondary/'data/learnings.md').read_text()
    secondary_archive=(secondary/'data/memory-archive.md').read_text()
    check('Direct secondary cascade archives old ruling in its own cold tier','/disposable/old-secondary' not in secondary_after and '/disposable/old-secondary' in secondary_archive)
    check('Secondary shared input remains byte-identical',(secondary/'data/captain-shared.md').read_bytes()==shared)
    check('Stow ignores legacy settings without changing either file',(primary/'config/startup-memory-budget').read_text()=='1\n' and (secondary/'config/startup-memory-budget').read_text()=='1\n')
    (E/'r2-stow-state-files.json').write_text(json.dumps(sorted(str(p.relative_to(primary)) for p in (primary/'state').rglob('*') if p.is_file()),indent=2))
finally:
    if labenv:subprocess.run(['tmux','-L','fm-lab','kill-server'],env=labenv,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    for h in homes:shutil.rmtree(h)
    log.write('Disposable homes and private tmux server removed.\n')
    (E/'r2-behavior-checks.json').write_text(json.dumps(results,indent=2))
    log.close()
