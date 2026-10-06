from pathlib import Path
import os, subprocess, tempfile, shutil, time, shlex, json
ROOT = Path.cwd()
E = Path('/home/tegris/.no-mistakes/evidence/01M49EBAM259QST2W72QEEJVGG')
log = (E/'cascade-stow-live.log').open('w', buffering=1)
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
    secondary = home()
    (primary/'tmux').mkdir()
    (secondary/'bin').mkdir()
    shutil.copyfile(ROOT/'AGENTS.md', secondary/'AGENTS.md')
    (secondary/'.fm-secondmate-home').write_text('archive-secondary\n')
    today = time.strftime('%Y-%m-%d')
    current = '- Fleet-wide dispatch must resolve the registered home before selecting its transport. <!--a:'+today+'-->\n'
    (primary/'data/captain.md').write_text('# Captain\n- Never discard unlanded work without explicit authority.\n')
    (primary/'data/learnings.md').write_text('# Learnings\n'+current+current)
    (primary/'config/startup-memory-budget').write_text('1\n')
    (secondary/'config/startup-memory-budget').write_text('invalid\n')
    (secondary/'data/captain-shared.md').write_text('# Shared captain\n- Keep all unresolved authority boundaries explicit.\n')
    shared = (secondary/'data/captain-shared.md').read_bytes()
    (secondary/'data/learnings.md').write_text('# Learnings\n- Finished secondary incident used the superseded lab path /disposable/old-secondary. <!--a:2026-01-01-->\n')
    (primary/'data/secondmates.md').write_text('- archive-secondary - lab (home: '+str(secondary)+'; scope: testing; projects: alpha; added 2026-10-06)\n')
    (primary/'config/supervision-host-off').touch()
    lab_env = dict(base_env, FM_HOME=str(primary), TMUX_TMPDIR=str(primary/'tmux'), CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false')
    for role,h in [('primary',primary),('secondary',secondary)]:
        shutil.copytree(h/'data', E/('cascade-stow-before-'+role))
    prompt = '/stow This is a disposable lab primary with FM_HOME='+str(primary)+'. Curate only this home and its registered disposable secondmate '+str(secondary)+'. Use the tracked internal stow skill and its normal cascade. No independent session evidence confirms the old secondary incident, no open work records exist, and there are no uncaptured findings. Do not modify tracked source or external homes, do not create or control pipelines, do not launch any worker, and do not contact external services. Produce the normal completion receipt. Reads and writes for the primary belong under FM_HOME, not cwd data. Only registered lab homes may be touched; finish after the receipt.'
    (E/'cascade-stow-prompt.txt').write_text(prompt)
    args=['claude','-p','--permission-mode','auto','--no-session-persistence','--setting-sources','project','--strict-mcp-config','--disallowedTools','Agent,Task,TaskCreate,TaskUpdate,TaskList,TaskGet','--add-dir',str(primary),'--add-dir',str(secondary),'--verbose','--output-format','stream-json',prompt]
    cli=shlex.join(args)+' > '+shlex.quote(str(E/'cascade-stow-native.jsonl'))+' 2> '+shlex.quote(str(E/'cascade-stow-native.stderr'))
    command(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',str(ROOT),'-e','FM_HOME='+str(primary),cli],lab_env,'cascade-native-launch')
    deadline=time.monotonic()+420
    while time.monotonic()<deadline:
        check=subprocess.run(['tmux','-L','fm-lab','has-session','-t','primary'],env=lab_env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if check.returncode: break
        time.sleep(3)
    else:
        command(['tmux','-L','fm-lab','capture-pane','-p','-t','primary'],lab_env,'cascade-native-timeout')
    for role,h in [('primary',primary),('secondary',secondary)]:
        shutil.copytree(h/'data',E/('cascade-stow-after-'+role))
    assert (primary/'config/startup-memory-budget').read_text()=='1\n'
    assert (secondary/'config/startup-memory-budget').read_text()=='invalid\n'
    assert (secondary/'data/captain-shared.md').read_bytes()==shared
    log.write('Cascade native run ended; persisted data and shared-file preservation retained.\n')
finally:
    if lab_env:
        subprocess.run(['tmux','-L','fm-lab','kill-server'],env=lab_env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    for h in homes: shutil.rmtree(h)
    log.write('All disposable homes and private tmux server torn down.\n')
    log.close()
