from pathlib import Path
import os, subprocess, tempfile, shutil, time, shlex, json
ROOT = Path.cwd()
E = Path('/home/tegris/.no-mistakes/evidence/01M49EBAM259QST2W72QEEJVGG')
log = (E/'live-product.log').open('w', buffering=1)
base_env = os.environ.copy()
for key in ('NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_TASK_ID', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'TMUX', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'CLAUDECODE'):
    base_env.pop(key, None)
base_env['FM_BOOTSTRAP_NETWORK'] = 'skip'
homes = []
lab_env = None

def command(argv, env, name, accepted=(0,)):
    out = subprocess.run(argv, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    (E/(name+'.txt')).write_text(out.stdout)
    log.write('$ '+shlex.join(map(str, argv))+'\n'+out.stdout+'\nexit='+str(out.returncode)+'\n')
    assert out.returncode in accepted, (name, out.returncode)
    return out.stdout

def home():
    path = Path(tempfile.mkdtemp(prefix='lab.', dir=E))
    homes.append(path)
    command(['bin/fm-lab-home.sh', 'create', str(path)], base_env, 'lab-create-'+str(len(homes)))
    return path

try:
    primary = home()
    env = dict(base_env, FM_HOME=str(primary))
    out = command(['bin/fm-bootstrap.sh'], env, 'fresh-bootstrap')
    assert not (primary/'config/startup-memory-budget').exists()
    assert 'STARTUP_MEMORY_BUDGET' not in out
    log.write('Fresh primary: retired setting absent; no retired diagnostic.\n')
    retired = primary/'config/startup-memory-budget'
    retired.write_text('invalid-legacy-setting\n')
    out = command(['bin/fm-bootstrap.sh'], env, 'legacy-bootstrap')
    assert retired.read_text() == 'invalid-legacy-setting\n'
    assert 'STARTUP_MEMORY_BUDGET' not in out
    log.write('Existing invalid legacy setting ignored and byte-preserved.\n')
    out = command(['bin/fm-session-start.sh'], env, 'legacy-session-start')
    assert 'STARTUP_MEMORY_BUDGET' not in out
    assert retired.read_text() == 'invalid-legacy-setting\n'
    assert 'CONTEXT' in out
    log.write('Session start emits its digest with the legacy setting untouched.\n')
    seconds = []
    for id in ('fresh-secondary', 'old-secondary'):
        h = home()
        seconds.append(h)
        for folder in ('bin',):
            (h/folder).mkdir()
        shutil.copyfile(ROOT/'AGENTS.md', h/'AGENTS.md')
        (h/'.fm-secondmate-home').write_text(id+'\n')
        (primary/('state/'+id+'.meta')).write_text('kind=secondmate\nhome='+str(h)+'\nharness=claude\nbackend=tmux\n')
    old = seconds[1]/'config/startup-memory-budget'
    old.write_text('1\n')
    out = command(['bin/fm-config-push.sh'], env, 'config-push')
    assert 'startup-memory-budget' not in out
    assert not (seconds[0]/'config/startup-memory-budget').exists()
    assert old.read_text() == '1\n'
    log.write('Config push: no retired item in receipt, fresh secondary has no setting, old secondary keeps its ignored setting.\n')
    (primary/'data/secondmates.md').write_text(''.join('- '+id+' - lab (home: '+str(h)+'; scope: test; projects: alpha; added 2026-10-06)\n' for id,h in zip(('fresh-secondary','old-secondary'),seconds)))
    out = command(['bin/fm-stow-cascade.sh'], env, 'direct-cascade')
    assert out.count('transport=direct') == 2
    assert 'budget_report=' not in out and 'total_estimated_tokens=' not in out
    assert old.read_text() == '1\n'
    log.write('Cascade resolves both secondary homes without size accounting.\n')
    with (primary/'data/secondmates.md').open('a') as f:
        f.write('- remote-old - lab (host: fm-lab-uncontacted; root: /disposable/root; home: /disposable/old; scope: test; projects: alpha; added 2026-10-06)\n')
    out = command(['bin/fm-stow-cascade.sh'], env, 'remote-deferred-cascade', (3,))
    assert 'transport=deferred' in out and 'budget_report=' not in out
    assert 'secondmates=3' in out
    log.write('Unavailable remote without an endpoint is deferred and local homes still resolve; no obsolete report requested.\n')
    (primary/'data/secondmates.md').unlink()
    for meta in (primary/'state').glob('*.meta'):
        meta.unlink()
    today = time.strftime('%Y-%m-%d')
    (primary/'data/captain.md').write_text('# Captain\n- Never discard unlanded work without explicit captain authority.\n')
    (primary/'data/captain-shared.md').write_text('# Shared captain\n- Report observed outcomes faithfully and disclose remaining gaps.\n')
    (primary/'data/learnings.md').write_text('# Learnings\n- Fleet-wide dispatch must resolve the registered home before selecting its transport. <!--a:'+today+'-->\n- Completed lab release 0.0.1 used the superseded path /disposable/obsolete. <!--a:2026-01-01-->\n- Temporary compatibility workaround for completed lab ticket LAB-OLD was retired after that ticket closed. <!--p:2026-01-01-->\n')
    shutil.copytree(primary/'data', E/'stow-before')
    (primary/'tmux').mkdir()
    (primary/'config/supervision-host-off').touch()
    lab_env = dict(env, TMUX_TMPDIR=str(primary/'tmux'), CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false')
    prompt = '/stow This is a disposable lab primary with FM_HOME='+str(primary)+'. Curate only its private memory files and produce the normal stow receipt. No other files or homes are in scope. The completed lab ticket LAB-OLD is resolved; no fresh evidence confirms either old entry, and no open work records or uncaptured durable findings exist in this session. Use the tracked internal stow skill. Do not change tracked source, do not launch or control any pipeline, do not contact other services, and do not modify any external home or tool configuration. The session-start digest has already been emitted by bin/fm-session-start.sh for this home; hooks in the gate stand down. Read FM_HOME data instead of cwd-relative data. Finish after the receipt.'
    (E/'stow-prompt.txt').write_text(prompt)
    args = ['claude', '-p', '--permission-mode', 'auto', '--no-session-persistence', '--setting-sources', 'project', '--strict-mcp-config', '--disallowedTools', 'Agent,Task,TaskCreate,TaskUpdate,TaskList,TaskGet', '--add-dir', str(primary), '--verbose', '--output-format', 'stream-json', prompt]
    cli = shlex.join(args)+' > '+shlex.quote(str(E/'stow-native.jsonl'))+' 2> '+shlex.quote(str(E/'stow-native.stderr'))
    log.write('Native primary CLI: '+shlex.join(args[:-1])+' <stow-prompt.txt>\n')
    command(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',str(ROOT),'-e','FM_HOME='+str(primary),cli], lab_env, 'native-launch')
    deadline = time.monotonic()+420
    while time.monotonic()<deadline:
        check = subprocess.run(['tmux','-L','fm-lab','has-session','-t','primary'],env=lab_env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if check.returncode:
            break
        time.sleep(3)
    else:
        command(['tmux','-L','fm-lab','capture-pane','-p','-t','primary'],lab_env,'native-timeout-pane')
        log.write('Native harness timed out after 420s.\n')
    shutil.copytree(primary/'data', E/'stow-after')
    (E/'stow-state-files.json').write_text(json.dumps(sorted(str(f.relative_to(primary)) for f in (primary/'state').rglob('*') if f.is_file()),indent=2))
    assert retired.read_text() == 'invalid-legacy-setting\n'
    log.write('Native stow ended; persisted memory and receipt retained for inspection.\n')
finally:
    if lab_env:
        subprocess.run(['tmux','-L','fm-lab','kill-server'],env=lab_env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    for h in homes:
        shutil.rmtree(h)
    log.write('All disposable homes and private tmux server torn down.\n')
    log.close()
