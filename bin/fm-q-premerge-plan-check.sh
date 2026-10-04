#!/usr/bin/env bash
# Usage: fm-q-premerge-plan-check.sh <Q-clone-path> <positive-PR-number>
# Read origin/main and the PR into private /tmp scratch; validate the simulated
# merge with BASE-owned Q tools. Requires Git with merge-tree --write-tree and
# Python 3.12+ (safe archive extraction). Each external command is bounded at
# 180 seconds. Exit 0: fresh with actual base/head/tree; 1: conflict or rejected
# plan; 2: unavailable/unverifiable. Diagnostics never expose transport output.
# Manual-install warnings do not affect acceptance. Recheck if either ref moves;
# this checks only, and never replaces fm-pr-merge.sh or its merge authority.
set -euo pipefail
if [ "${1:-}" = --help ]; then
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
exec python3 - "$@" <<'PY'
import fnmatch
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile

class Refused(Exception):
    def __init__(self, stage, code=2):
        self.stage, self.code = stage, code

stage = 'input'
try:
    if len(sys.argv) != 3 or not re.fullmatch(r'[0-9]+', sys.argv[2]) or int(sys.argv[2]) < 1:
        raise Refused(stage)
    source, pr = Path(sys.argv[1]).resolve(strict=True), sys.argv[2]
    # Do not inherit Git redirection or candidate Python module search paths.
    env = {k: v for k, v in os.environ.items()
           if k not in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
                        'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES',
                        'PYTHONPATH', 'PYTHONHOME', 'Q_PLAN_TOOL_ROOT')}
    limit = 180
    if env.get('FM_TEST_SEAM') == '1':
        limit = float(env.get('FM_Q_PREMERGE_TIMEOUT', '180'))
        if limit <= 0:
            raise Refused(stage)
    def run(*args, cwd=None):
        return subprocess.run(args, cwd=cwd, env=env, capture_output=True, timeout=limit)
    def checked(*args, cwd=None):
        result = run(*args, cwd=cwd)
        if result.returncode:
            raise Refused(stage)
        return result.stdout
    origin = checked('git', '-C', str(source), 'remote', 'get-url', 'origin').decode().strip()
    if not origin:
        raise Refused(stage)
    # Resolve relative local remotes relative to the source, not scratch.
    if ':' not in origin and not Path(origin).is_absolute():
        origin = str((source / origin).resolve())
    with tempfile.TemporaryDirectory(prefix='fm-q-premerge-', dir='/tmp') as temporary:
        scratch = Path(temporary)
        stage = 'scratch'
        if run('git', '-C', str(scratch), 'rev-parse', '--show-toplevel').returncode == 0:
            raise Refused(stage)
        repo = scratch / 'merge'
        checked('git', 'init', '-q', str(repo))
        # Preserve the clone's supported transport authentication/config without
        # copying hooks, extensions, remote push settings or writing source refs.
        config = run('git', '-C', str(source), 'config', '--null', '--get-regexp',
                     r'^(credential\.|http\.|url\.|core\.sshcommand$)')
        if config.returncode not in (0, 1):
            raise Refused(stage)
        for entry in config.stdout.split(b'\0'):
            if entry:
                key, value = entry.decode().split('\n', 1)
                checked('git', '-C', str(repo), 'config', '--add', key, value)
        def git(*args):
            return checked('git', '-C', str(repo), *args)
        stage = 'fetch'
        git('fetch', '-q', '--no-tags', '--', origin,
            '+refs/heads/main:refs/heads/base', f'+refs/pull/{pr}/head:refs/heads/pr')
        base = git('rev-parse', '--verify', 'refs/heads/base^{commit}').decode().strip()
        head = git('rev-parse', '--verify', 'refs/heads/pr^{commit}').decode().strip()
        stage = 'merge-tree'
        merged = run('git', '-C', str(repo), 'merge-tree', '--write-tree', base, head)
        if merged.returncode:
            raise Refused(stage, 1 if merged.returncode == 1 else 2)
        tree = merged.stdout.decode().splitlines()[0]
        if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', tree):
            raise Refused(stage)
        env.update(GIT_AUTHOR_NAME='Plan check', GIT_COMMITTER_NAME='Plan check',
                   GIT_AUTHOR_EMAIL='plan-check@localhost', GIT_COMMITTER_EMAIL='plan-check@localhost')
        merge = git('commit-tree', tree, '-p', base, '-p', head, '-m', 'Scratch plan check').decode().strip()
        git('update-ref', 'HEAD', merge)
        def snapshot(ref, target):
            target.mkdir(parents=True, exist_ok=True)
            data = git('archive', '--format=tar', ref)
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                archive.extractall(target, filter='data')
            return target
        stage = 'snapshot'
        snapshot(merge, repo)
        base_tree = snapshot(base, scratch / 'base')
        ancestor = git('merge-base', base, merge).decode().strip()
        ancestor_tree = base_tree if ancestor == base else snapshot(ancestor, scratch / 'ancestor')
        package = 'docs/ssot/q-v2'
        checker_path = f'{package}/tools/check_plan.py'
        closure_path = f'{package}/tools/tool-closure.json'
        tools = scratch / 'tools'
        stage = 'BASE tool closure'
        declared = git('ls-tree', base, '--', closure_path)
        if declared:
            body = json.loads(git('show', f'{base}:{closure_path}'))
            members = body.get('members') if isinstance(body, dict) and body.get('schema') == 'q-plan-tool-closure/1' else None
            required = {checker_path, f'{package}/tools/build_plan_views.py',
                        f'{package}/tools/build_current_baseline.py',
                        'ops/bin/q-v2-tool-scopes', 'ops/lib/q-v2/q_agent_api.py'}
            if (not isinstance(members, list) or not members
                    or any(not isinstance(p, str) for p in members)
                    or len(set(members)) != len(members) or not required <= set(members)):
                raise Refused(stage)
        else:
            members = [checker_path]
        for name in members:
            path = Path(name)
            if not name or path.is_absolute() or path.as_posix() != name or any(p in ('', '.', '..') for p in path.parts):
                raise Refused(stage)
            destination = tools / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(git('show', f'{base}:{name}'))
        env['Q_PLAN_TOOL_ROOT'] = str(tools)
        checker = str(tools / checker_path)
        def plan_command(label, *args):
            global stage
            stage = label
            result = run(sys.executable, '-I', checker, *args, cwd=repo)
            if result.returncode not in (0, 1, 2):
                raise Refused(stage)
            value = json.loads(result.stdout)
            if not isinstance(value, dict) or type(value.get('fresh')) is not bool:
                raise Refused(stage)
            if not value['fresh']:
                raise Refused(stage, 1)
            if result.returncode:
                raise Refused(stage)
        plan_command('freshness', 'check', '--root', str(repo / package), '--repo', str(repo))
        plan_command('union', 'check-union', '--base-repo', str(base_tree), '--head-repo', str(repo),
                     '--ancestor-repo', str(ancestor_tree), '--history-repo', str(repo),
                     '--base-ref', base, '--head-ref', merge)
        if declared:
            stage = 'views'
            result = run(sys.executable, '-I', str(tools / package / 'tools/build_plan_views.py'),
                         'check', '--repo', str(repo), cwd=repo)
            if result.returncode:
                raise Refused(stage, 1 if result.returncode in (1, 2) and result.stdout else 2)
        stage = 'manual-install warning'
        deploy = repo / 'ops/lib/q-v2/deploy.json'
        if deploy.is_file():
            try:
                config = json.loads(deploy.read_text())
                changed = git('diff', '--name-only', '-z', base, merge).decode().split('\0')
                hits = [p for p in changed if p and (p in config['backup_library'] or
                        any(fnmatch.fnmatch(p, g.replace('**', '*')) for g in config['manual_only']))]
                if hits:
                    print('MANUAL INSTALL after merge (pre-authorize fleet-ops root step): ' + ', '.join(hits))
            except (OSError, ValueError, TypeError, KeyError, AttributeError, Refused):
                print('MANUAL INSTALL warning unavailable', file=sys.stderr)
        print(f'fresh base={base} head={head} tree={tree}')
except Refused as exc:
    print(f'plan check refused: {exc.stage}', file=sys.stderr)
    sys.exit(exc.code)
except (OSError, ValueError, TypeError, KeyError, IndexError, UnicodeError,
        tarfile.TarError, subprocess.TimeoutExpired):
    print(f'plan check unavailable: {stage}', file=sys.stderr)
    sys.exit(2)
PY
