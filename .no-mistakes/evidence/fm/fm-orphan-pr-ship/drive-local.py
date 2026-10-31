import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path.cwd()
evidence = Path('~/.no-mistakes/evidence/01M68VGPZW3GD9GEZK61YV377K')
labs = root / '.test-phase' / 'labs'
labs.mkdir()
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'GH_', 'GITHUB_', 'TASKS_AXI_', 'GIT_CONFIG_')) or key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE'):
        env.pop(key)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GH_CONFIG_DIR=str(labs / 'gh-config'), GH_PROMPT_DISABLED='1', GH_PAGER='cat', TMPDIR=str(root / '.test-phase' / 'tmp'))
(labs / 'gh-config').mkdir()
transcript = []
results = []

def run(args, home=None):
    call_env = env.copy()
    if home:
        call_env['FM_HOME'] = str(home)
    p = subprocess.run(args, env=call_env, cwd=root, capture_output=True, text=True, timeout=40)
    transcript.append({'command': args, 'home': str(home) if home else None, 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr})
    return p

def home_for(name, annotation, remote):
    home = labs / name
    assert run(['bin/fm-lab-home.sh', 'create', str(home)]).returncode == 0
    (home / 'data' / 'projects.md').write_text(f'- sample [{annotation}] - disposable validation project\n')
    clone = home / 'projects' / 'sample'
    assert run(['git', 'init', '-q', '-b', 'main', str(clone)]).returncode == 0
    if remote:
        assert run(['git', '-C', str(clone), 'remote', 'add', 'origin', remote]).returncode == 0
    return home

try:
    # Oracle: accepted scope excludes local-only, forge-bound and non-GitHub
    # projects. The actual executable must neither query nor queue a wake.
    for name, annotation, remote in [
        ('local-only', 'local-only', 'https://github.com/cli/cli.git'),
        ('external', 'direct-PR forge=external', 'https://github.com/cli/cli.git'),
        ('gerrit', 'direct-PR forge=gerrit', 'https://github.com/cli/cli.git'),
        ('forgejo', 'direct-PR forge=forgejo', 'https://github.com/cli/cli.git'),
        ('gitlab', 'direct-PR', 'https://gitlab.com/example/repo.git'),
        ('malformed-target', 'direct-PR', 'https://github.com/example/repo/extra.git'),
        ('no-remote', 'direct-PR', None),
    ]:
        home = home_for(name, annotation, remote)
        p = run(['bin/fm-pr-orphan-sweep.sh'], home)
        state_files = sorted(str(x.relative_to(home)) for x in (home / 'state').rglob('*'))
        assert p.returncode == 0 and not p.stdout and not p.stderr and not state_files, (name, p, state_files)
        results.append({'scenario': name, 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr, 'state_files': state_files})

    # Oracle: the explicitly removed --report mode and all arguments are refused.
    home = labs / 'local-only'
    for arg in ['--report', '--bogus']:
        p = run(['bin/fm-pr-orphan-sweep.sh', arg], home)
        assert p.returncode == 2 and not p.stdout and p.stderr == 'usage: fm-pr-orphan-sweep.sh\n'
        results.append({'scenario': arg, 'exit': p.returncode, 'stderr': p.stderr})

    # Use the genuine gh binary and isolated empty config: never consult the
    # operator's authentication or pretend a recording gh is the live forge.
    p = run(['gh', 'pr', 'list', '-R', 'cli/cli', '--state', 'open', '--label', 'conflict', '--limit', '200', '--json', 'number,headRefName'])
    assert p.returncode != 0 and 'GH_TOKEN' in p.stderr, p
    home = home_for('real-cli-no-auth', 'direct-PR', 'https://github.com/cli/cli.git')
    p = run(['bin/fm-pr-orphan-sweep.sh'], home)
    state_files = sorted(str(x.relative_to(home)) for x in (home / 'state').rglob('*'))
    assert p.returncode == 0 and not p.stdout and 'could not list conflicted pull requests' in p.stderr and not state_files, (p, state_files)
    results.append({'scenario': 'unauthenticated forge diagnostic without false wake', 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr, 'state_files': state_files})
    p = run(['bin/fm-pr-poll.sh', '--validated', 'github', 'https://github.com/cli/cli/pull/1', 'github.com', 'cli/cli', '1'], home)
    assert p.returncode != 0 and 'GH_TOKEN' in p.stderr and not p.stdout, p
finally:
    (evidence / 'local-product-transcript.json').write_text(json.dumps({'calls': transcript, 'observations': results}, indent=2) + '\n')
    shutil.rmtree(labs)

print(json.dumps(results, indent=2))
