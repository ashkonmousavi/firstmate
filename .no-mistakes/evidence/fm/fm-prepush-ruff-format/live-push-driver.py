"""Exercise installed Firstmate hooks through real Git pushes and real Ruff.

Oracle: accepted task decisions plus https://docs.astral.sh/ruff/formatter/
and https://docs.astral.sh/ruff/configuration/. Rejected pushes must leave
remote refs unchanged; successful recovery must persist the exact commit.
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

ROOT = Path.cwd()
SCRATCH = ROOT / '.test-live-ruff' / 'manual'
EVIDENCE = Path('~/.no-mistakes/evidence/01M67T3AATP6AT5EK7H7JK51FF')
SCRATCH.mkdir()
ENV = os.environ.copy()
for key in list(ENV):
    if key.startswith(('GIT_', 'FM_')) or key in ('RUFF_OUTPUT_FORMAT',):
        ENV.pop(key)
ENV.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Live test', GIT_COMMITTER_NAME='Live test',
           GIT_AUTHOR_EMAIL='live@example.invalid', GIT_COMMITTER_EMAIL='live@example.invalid',
           TMPDIR=str(ROOT / '.test-live-ruff' / 'tmp'),
           UV_CACHE_DIR=str(SCRATCH / 'uv-cache'), UV_PYTHON_DOWNLOADS='never')
RUFF = shutil.which('ruff')
RESULTS = []
LOG = None

def run(args, cwd=ROOT, env=None, expected=0):
    print('$ ' + shlex.join(map(str, args)), file=LOG, flush=True)
    result = subprocess.run(list(map(str, args)), cwd=cwd, env=env or ENV,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=180)
    print(result.stdout, end='', file=LOG)
    print(f'[exit {result.returncode}]', file=LOG, flush=True)
    if expected is not None:
        assert result.returncode == expected, result.stdout
    return result

class Repo:
    def __init__(self, name, declaration=True, keep=False, runner='path'):
        self.root = SCRATCH / name
        self.wt = self.root / 'project'
        self.remote = self.root / 'origin.git'
        self.hooks = self.root / 'task.git-hooks'
        self.wt.mkdir(parents=True)
        run(['git', 'init', '-q', '-b', 'main', self.wt])
        run(['git', 'init', '-q', '--bare', self.remote])
        self.env = ENV.copy()
        self.commit({'README.md': 'Live test fixture\n'}, 'base')
        run(['git', 'remote', 'add', 'origin', 'file://' + str(self.remote)], self.wt)
        run(['git', 'push', '-q', 'origin', 'main'], self.wt)
        run(['git', 'checkout', '-q', '-b', 'NOT_Q/live'], self.wt)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('git', 'bash', 'env', 'sort', 'cat', 'sed', 'sh', 'dirname', 'basename',
                     'uname', 'mktemp', 'rm', 'tr', 'mkdir', 'grep'):
            (self.bin / name).symlink_to(shutil.which(name))
        if runner == 'path':
            (self.bin / 'ruff').symlink_to(RUFF)
        elif runner in ('.venv', 'venv'):
            target = self.wt / runner / 'bin'
            target.mkdir(parents=True)
            (target / 'ruff').symlink_to(RUFF)
        elif runner in ('uvx', 'uv'):
            (self.bin / runner).symlink_to(shutil.which(runner))
        self.env['PATH'] = str(self.bin)
        if declaration:
            self.commit({'requirements-dev.txt': 'ruff==0.12.7\n'}, 'declare Ruff')
        args = [ROOT / 'bin/fm-git-strip-ai-trailers.sh', 'install']
        if keep:
            args.append('--no-strip')
        run(args + [self.hooks, self.wt])
        envfile = self.root / 'git-env.sh'
        emitted = run([ROOT / 'bin/fm-git-strip-ai-trailers.sh', 'env-file', self.hooks, envfile])
        # Consume the emitted launch environment with a real shell, as workers do.
        captured = subprocess.check_output(['/bin/bash', '-c', '. "$1"; env -0', '_', str(envfile)], env=self.env)
        self.env = dict(item.decode().split('=', 1) for item in captured.split(b'\0') if item)

    def commit(self, files, message='scenario change'):
        for name, data in files.items():
            path = self.wt / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data)
            run(['git', 'add', '-f', '--', name], self.wt, ENV)
        run(['git', 'commit', '-q', '--allow-empty', '-m', message], self.wt, ENV)
        return self.oid()

    def oid(self):
        return subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.wt, env=ENV, text=True).strip()

    def ref(self, ref='NOT_Q/live'):
        p = run(['git', '--git-dir', self.remote, 'rev-parse', '--verify', 'refs/heads/' + ref], expected=None)
        return p.stdout.strip() if p.returncode == 0 else None

    def push(self, good, refs=None, text=None):
        before = self.ref()
        p = run(['git', 'push', 'origin'] + (refs or ['HEAD:refs/heads/NOT_Q/live']), self.wt, self.env, expected=None)
        assert (p.returncode == 0) == good, p.stdout
        if text:
            assert text in p.stdout, p.stdout
        if refs is None:
            assert self.ref() == (self.oid() if good else before)
        return p.stdout

    def fix(self, output):
        fixes = [line.removeprefix('Fix: ') for line in output.splitlines() if line.startswith('Fix: ')]
        assert fixes, output
        for fix in fixes:
            run(['/bin/bash', '-c', fix], self.wt, self.env)
        run(['git', 'add', '-u'], self.wt, ENV)
        run(['git', 'commit', '-q', '-m', 'apply displayed fix'], self.wt, ENV)

def scenario(name, function):
    global LOG
    label = name.replace(' ', '-')
    path = EVIDENCE / (label + '.log')
    with path.open('w') as LOG:
        try:
            function()
            result = 'pass'
            reason = ''
        except Exception as exc:
            result = 'fail'
            reason = repr(exc)
            print('SCENARIO FAILURE: ' + reason, file=LOG)
        RESULTS.append(dict(name=name, result=result, live=True, evidence=str(path), reason=reason))
    print(name + ': ' + result, flush=True)

def recovery():
    for runner in ('path', '.venv', 'venv', 'uvx', 'uv'):
        repo = Repo('recovery-' + runner + ' with spaces', keep=True, runner=runner)
        repo.commit({'a file.py': 'x=1\n', "quote'file.pyi": 'y=2\n', '-leading.py': 'z=3\n'})
        output = repo.push(False, text='Fix: ')
        repo.fix(output)
        repo.push(True)

def configuration():
    repo = Repo('configuration')
    repo.commit({'ruff.toml': '[format]\nquote-style = "double"\n', 'pkg/a.py': "x = 'a'\n"})
    (repo.wt / 'ruff.toml').write_text('[format]\nquote-style = "single"\n')
    status = run(['git', 'status', '--porcelain'], repo.wt).stdout
    repo.push(False, text='  pkg/a.py')
    assert status == run(['git', 'status', '--porcelain'], repo.wt).stdout
    repo.commit({'pkg/a.py': 'x = "a"\n'})
    repo.push(True)
    double = repo.oid()
    single = repo.commit({'ruff.toml': '[format]\nquote-style = "single"\n', 'pkg/a.py': "x = 'b'\n"})
    repo.push(True, [f'{double}:refs/heads/double', f'{single}:refs/heads/single'])
    assert repo.ref('double') == double and repo.ref('single') == single

def supported():
    repo = Repo('supported')
    nb = json.dumps(dict(cells=[dict(cell_type='code', execution_count=None, metadata={}, outputs=[], source=['x=1\n'])], metadata={}, nbformat=4, nbformat_minor=5))
    repo.commit({'api.pyi': 'x=1\n', 'book.ipynb': nb})
    output = repo.push(False, text='  book.ipynb')
    assert '  api.pyi' in output
    repo.fix(output)
    repo.push(True)
    repo.commit({'ruff.toml': '[format]\nexclude = ["large.py", "large.pyi", "large.ipynb"]\n',
                 **{f'large.{suffix}': 'bad invalid source=1\n' * 200000 for suffix in ('py', 'pyi', 'ipynb')}})
    repo.push(True)
    repo.commit({'included.py': 'x=2\n'})
    repo.push(False, text='  included.py')

def missing_and_errors():
    repo = Repo('no-runner', runner='missing')
    repo.commit({'a.py': 'x=1\n'})
    repo.push(False, text='Install: python3 -m pip install ruff==0.12.7')
    (repo.bin / 'uvx').symlink_to(shutil.which('uvx'))
    repo.commit({'requirements-dev.txt': 'ruff>=0.12\n'})
    repo.push(False, text='Ruff was not found')
    (repo.bin / 'ruff').symlink_to(RUFF)
    repo.commit({'ruff.toml': 'not-a-valid-toml = [\n'})
    repo.push(False, text='Ruff could not check a.py')
    repo.commit({'ruff.toml': '', 'a.py': 'if broken syntax\n'})
    repo.push(False, text='Ruff could not check a.py')

def selection():
    repo = Repo('selection')
    repo.commit({'old.py': 'x=1\n'})
    # Seed historical code in the default branch without the task environment.
    run(['git', 'branch', '-f', 'main', 'HEAD'], repo.wt, ENV)
    run(['git', 'push', '-q', 'origin', 'main'], repo.wt, ENV)
    repo.commit({'new.py': 'y = 2\n'})
    repo.push(True)
    repo.commit({'old.py': 'x=2\n'})
    repo.push(False, text='  old.py')
    run(['git', 'branch', '-D', 'main'], repo.wt, ENV)
    run(['git', 'update-ref', '-d', 'refs/remotes/origin/main'], repo.wt, ENV)
    repo.push(False, ['HEAD:refs/heads/no-base'], text='  old.py')
    assert repo.ref('no-base') is None

def chaining():
    repo = Repo('chaining', keep=True)
    ownhooks = repo.wt / '.project-hooks'
    ownhooks.mkdir()
    marker = repo.root / 'project-hook-refs'
    (ownhooks / 'pre-push').write_text('#!/bin/bash\ncat > ' + shlex.quote(str(marker)) + '\n[ ! -f ' + shlex.quote(str(repo.root / 'block')) + ' ]\n')
    (ownhooks / 'pre-push').chmod(0o755)
    run(['git', 'config', 'core.hooksPath', ownhooks], repo.wt, ENV)
    repo.commit({'a.py': 'x=1\n'})
    output = repo.push(False)
    assert not marker.exists()
    repo.fix(output)
    repo.push(True, ['HEAD:refs/heads/NOT_Q/live', 'HEAD:refs/heads/second'])
    assert len(marker.read_text().splitlines()) == 2
    repo.push(True)
    assert marker.read_bytes() == b''
    (repo.root / 'block').touch()
    repo.commit({'a.py': 'x = 2\n'})
    repo.push(False)
    assert marker.read_bytes()
    (repo.root / 'block').unlink()
    guard = repo.root / 'guard'
    run([ROOT / 'bin/fm-git-push-guard.sh', 'write', guard, repo.wt, 'NOT_Q/live', 'NOT_Q/'])
    run([ROOT / 'bin/fm-git-strip-ai-trailers.sh', 'install', '--push-guard', guard, repo.hooks, repo.wt])
    repo.commit({'a.py': 'x=3\n'})
    marker.unlink()
    output = repo.push(False, text='fm-git-push-guard: refused:')
    assert 'fm-ruff-format: refused:' in output and not marker.exists()

def symlinks():
    repo = Repo('symlinks')
    repo.commit({'module.txt': 'x = 1\n'})
    (repo.wt / 'a.py').symlink_to('module.txt')
    run(['git', 'add', 'a.py'], repo.wt, ENV)
    repo.commit({})
    repo.push(False, text='cannot format-check symlink or non-regular committed file a.py')
    (repo.wt / 'a.py').unlink()
    repo.commit({'a.py': 'x=1\n'})
    output = repo.push(False, text='  a.py')
    repo.fix(output)
    repo.push(True)

def declarations():
    for name, config, body in (('undeclared', None, ''), ('toml', 'ruff.toml', ''),
                              ('dot-toml', '.ruff.toml', ''), ('pyproject', 'pyproject.toml', '[tool.ruff]\n'),
                              ('nested', 'pkg/ruff.toml', ''), ('requirements', 'requirements-dev.txt', 'ruff\n')):
        repo = Repo('declaration-' + name, declaration=False)
        files = {'a.py': 'x=1\n'}
        if config:
            files[config] = body
        repo.commit(files)
        repo.push(config is None, text=None if config is None else 'fm-ruff-format: refused:')

for name, function in [('push-refusal-and-executable-runner-fixes', recovery),
                       ('committed-and-per-ref-settings', configuration),
                       ('stubs-notebooks-and-large-exclusions', supported),
                       ('missing-unpinned-and-broken-formatters-refuse', missing_and_errors),
                       ('changed-files-and-missing-base', selection),
                       ('project-hook-chaining-and-independent-guards', chaining),
                       ('symlink-refusal-and-regular-transition', symlinks),
                       ('automatic-declarations-and-undeclared-projects', declarations)]:
    scenario(name, function)
(EVIDENCE / 'live-results.json').write_text(json.dumps(RESULTS, indent=2) + '\n')
sys.exit(any(item['result'] != 'pass' for item in RESULTS))
