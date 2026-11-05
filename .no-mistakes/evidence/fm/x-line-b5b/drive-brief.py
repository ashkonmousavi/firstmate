import json, os, pathlib, shutil, subprocess

ROOT = pathlib.Path('~/.no-mistakes/worktrees/049a88734b0e/01M6N37SCY6ZV4A7184ZE4DQW8')
EVIDENCE = pathlib.Path('~/.no-mistakes/evidence/01M6N37SCY6ZV4A7184ZE4DQW8')
LAB = ROOT / '.test-b5b-tmp' / 'native-backlog'
LAB.mkdir(parents=True)
HOME_DIR = LAB / 'home'
(HOME_DIR / 'config').mkdir(parents=True)
(HOME_DIR / 'data').mkdir()
(HOME_DIR / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n')
(HOME_DIR / 'config/brief-include.md').write_text('Keep the home additions last.\n')
env = os.environ.copy()
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
    env.pop(key, None)
env.update(FM_HOME=str(HOME_DIR), TMPDIR=str(ROOT / '.test-b5b-tmp'), TASKS_AXI_BACKEND='markdown', TASKS_AXI_FILE=str(HOME_DIR / 'data/backlog.md'))

def run(args):
    return subprocess.run([str(a) for a in args], cwd=HOME_DIR, env=env, text=True, capture_output=True, timeout=45)

def checked(args):
    p=run(args)
    if p.returncode:
        raise RuntimeError(f'{args}: exit={p.returncode}\n{p.stdout}\n{p.stderr}')
    return p

identity='main/main-model | First chat | role=owner'
real='SLICE: '+identity
cases=[
    ('stamped', '```text\nSLICE: ignored/example | Example | role=owner\n```\n'+real+'\nRULES: owner\nSCOPE: First chat\nORACLE: brief-slice\nSLICE: ignored/later | Later | role=owner', real),
    ('missing', 'Firstmate keeps its own intent words here.', None),
    ('fenced-only', '```text\n'+real+'\n```\n~~~markdown\n'+real+'\n~~~', None),
    ('unclosed', '````markdown\n```\n'+real, None),
    ('wrong-marker', '~~~markdown\n```\nSLICE: ignored/example | Example | role=owner\n~~~\n'+real, real),
    ('suffix-not-close', '```text\n```example\nSLICE: ignored/example | Example | role=owner\n```\n'+real, real),
    ('short-not-close', '````text\n```\nSLICE: ignored/example | Example | role=owner\n`````\n'+real, real),
]
labels=['SLICE','# SLICE','## SLICE','### SLICE','#### SLICE','##### SLICE','###### SLICE','- SLICE','* SLICE','**SLICE**','# - **SLICE**','###### * **SLICE**']
for i,label in enumerate(labels):
    declaration=label+': '+identity
    cases.append((f'form-{i+1}', '~~~markdown\n```text\nSLICE: ignored/example | Example | role=owner\n~~~\n'+declaration+'\nSLICE: ignored/later | Later | role=owner', declaration))
records=[]
for name,body,expected in cases:
    for mode in ['no-mistakes','direct-PR','local-only','scout']:
        task=f'b5b-{name}-{mode.lower()}'
        added=checked(['tasks-axi','add',task,'Disposable B5b task','--kind','scout' if mode=='scout' else 'ship','--repo','sample','--body',body,'--json'])
        shown=checked([ROOT/'bin/fm-tasks-axi.sh','show',task,'--full'])
        args=[ROOT/'bin/fm-brief.sh',task,'sample']+(['--scout'] if mode=='scout' else ['--mode',mode])
        p=checked(args)
        brief=(HOME_DIR/'data'/task/'brief.md').read_text()
        assert "## Captain's intent\n{TASK}\n\n## Firstmate spec" in brief, task+' intent changed'
        assert brief.count('# Home brief additions\n') == 1
        assert brief.rstrip().endswith('Keep the home additions last.')
        if expected:
            assert brief.count('\n# Slice\n') == 1, task+' missing/duplicate Slice'
            emitted=brief.split('\n# Slice\n',1)[1].split('\n# Home brief additions',1)[0]
            assert emitted == expected+'\n', (task,emitted)
            assert p.stderr == '', (task,p.stderr)
        else:
            emitted=None
            assert '\n# Slice\n' not in brief, task+' invented Slice'
            assert p.stderr == f"note: no SLICE line in {task}'s task body\n", (task,p.stderr)
        assert 'ignored/example' not in brief and 'ignored/later' not in brief
        record={'task':task,'mode':mode,'input_body':body,'native_show':shown.stdout,'command':' '.join(map(str,args)),'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'slice_section':emitted,'intent_section':"## Captain's intent\n{TASK}\n\n## Firstmate spec",'result':'pass'}
        records.append(record)
        if (name,mode) in [('stamped','no-mistakes'),('stamped','scout'),('missing','no-mistakes'),('form-12','scout')]:
            (EVIDENCE/f'{task}-brief.md').write_text(brief)
        print(f'{task}: exit={p.returncode}; Slice={expected!r}; stderr={p.stderr!r}',flush=True)
# Reproduce the pre-change failure using the actual baseline brief CLI, same task store.
baseline=LAB/'baseline-bin'
baseline.mkdir()
for source in (ROOT/'bin').glob('*.sh'):
    (baseline/source.name).symlink_to(source)
(baseline/'fm-brief.sh').unlink()
p=subprocess.run(['git','show','214912ce94d9e057a6a0b7341535501464afd606:bin/fm-brief.sh'],cwd=ROOT,capture_output=True,text=True,check=True)
(baseline/'fm-brief.sh').write_text(p.stdout)
task='b5b-before'
checked(['tasks-axi','add',task,'Disposable baseline task','--kind','ship','--repo','sample','--body',real,'--json'])
p=checked(['bash',baseline/'fm-brief.sh',task,'sample','--mode','no-mistakes'])
before=(HOME_DIR/'data'/task/'brief.md').read_text()
assert '\n# Slice\n' not in before
(EVIDENCE/'native-brief-results.json').write_text(json.dumps({'oracle':'Authoritative B5b intent and recorded decision retaining heading/bullet/bold forms. First unfenced declaration only; no declaration means one note and no section; intent placeholder preserved.','cases':records,'baseline':{'exit':p.returncode,'slice_present':False,'stdout':p.stdout,'result':'missing-slice reproduced'}},indent=2))
print('Baseline: stamped native task produces no Slice section; target produces the expected Slice section.',flush=True)
print(f'Completed {len(records)} live native-backlog brief generations.',flush=True)
shutil.rmtree(LAB)
