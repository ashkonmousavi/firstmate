#!/usr/bin/env bash
# Usage: fm-q-premerge-plan-check.sh <Q-clone-path> <positive-PR-number>
# Read origin/main and the PR into private /tmp scratch; validate the simulated
# merge with BASE-owned Q tools. Requires Git with merge-tree --write-tree and
# Python 3.9+. HTTPS github.com uses gh login; SSH uses transport environment.
# Source cookie/custom Git config is not copied. Commands are bounded at
# 180 seconds. Exit 0: fresh with actual base/head/tree; 1: conflict or rejected
# plan; 2: unavailable/unverifiable. Diagnostics never expose transport output.
# Manual-install warnings do not affect acceptance. Recheck if either ref moves;
# this checks only, and never replaces fm-pr-merge.sh or its merge authority.
set -euo pipefail
if [ "${1:-}" = --help ]; then
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'plan check unavailable: python3\n' >&2
  exit 2
fi
exec python3 -I - "$@" <<'PY'
import fnmatch
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

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
        with subprocess.Popen(args, cwd=cwd, env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, start_new_session=True) as process:
            try:
                stdout, stderr = process.communicate(timeout=limit)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()
                raise
            return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    def checked(*args, cwd=None):
        result = run(*args, cwd=cwd)
        if result.returncode:
            raise Refused(stage)
        return result.stdout
    origin = checked('git', '-C', str(source), 'ls-remote', '--get-url', 'origin').decode().rstrip('\n')
    if not origin:
        raise Refused(stage)
    # Resolve relative local remotes relative to the source, not scratch.
    if ':' not in origin and not Path(origin).is_absolute():
        origin = str((source / origin).resolve())
    env = {key: value for key, value in env.items()
           if key not in ('GIT_CONFIG', 'GIT_ASKPASS', 'SSH_ASKPASS', 'SSH_ASKPASS_REQUIRE')
           and not key.startswith('GIT_CONFIG_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT='0')
    with tempfile.TemporaryDirectory(prefix='fm-q-premerge-', dir='/tmp') as temporary:
        scratch = Path(temporary)
        stage = 'scratch'
        if run('git', '-C', str(scratch), 'rev-parse', '--show-toplevel').returncode == 0:
            raise Refused(stage)
        repo = scratch / 'merge'
        checked('git', 'init', '-q', '--template=', str(repo))
        destination = urlsplit(origin)
        if destination.scheme == 'https' and destination.hostname == 'github.com':
            askpass = scratch / 'askpass'
            askpass.write_text(f'''#!/bin/sh
exec {shlex.quote(sys.executable)} -I - "$@" <<'ASKPASS'
import os, re, sys
from urllib.parse import urlsplit
match = re.fullmatch(r"(Username|Password) for '([^']+)': ?", sys.argv[1]) if len(sys.argv) == 2 else None
if not match:
    sys.exit(1)
try:
    destination = urlsplit(match[2])
    if destination.scheme != 'https' or destination.hostname != 'github.com':
        sys.exit(1)
except ValueError:
    sys.exit(1)
if match[1] == 'Username':
    print('x-access-token')
else:
    os.execvp('gh', ('gh', 'auth', 'token', '--hostname', 'github.com'))
ASKPASS
''')
            askpass.chmod(0o700)
            env['GIT_ASKPASS'] = str(askpass)
        def git(*args):
            return checked('git', '-C', str(repo), *args)
        stage = 'fetch'
        git('-c', 'credential.helper=', '-c', 'http.saveCookies=false',
            'fetch', '-q', '--no-tags', '--', origin,
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
        identities = git('show', '-s', '--format=%an%x00%ae%x00%cn%x00%ce', base).decode().rstrip('\n').split('\0')
        if len(identities) != 4 or any(not value.strip() or '\n' in value or '\r' in value for value in identities):
            raise Refused(stage)
        env.update(zip(('GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL'), identities))
        merge = git('commit-tree', tree, '-p', base, '-p', head, '-m', 'Scratch plan check').decode().strip()
        git('update-ref', 'HEAD', merge)
        def snapshot(ref, target):
            target.mkdir(parents=True, exist_ok=True)
            links = []
            for entry in git('ls-tree', '-rz', '--full-tree', ref).split(b'\0'):
                if not entry:
                    continue
                header, name = entry.split(b'\t', 1)
                mode, kind, oid = header.split()
                path = Path(os.fsdecode(name))
                if (path.is_absolute() or path.as_posix() != os.fsdecode(name)
                        or any(p in ('', '.', '..') or p.casefold() == '.git' for p in path.parts)
                        or kind != b'blob' or mode not in (b'100644', b'100755', b'120000')):
                    raise Refused(stage)
                destination = target / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                data = git('cat-file', 'blob', oid.decode('ascii'))
                if mode == b'120000':
                    links.append((destination, os.fsdecode(data)))
                else:
                    destination.write_bytes(data)
                    destination.chmod(0o755 if mode == b'100755' else 0o644)
            for destination, link in links:
                if Path(link).is_absolute():
                    raise Refused(stage)
                destination.symlink_to(link)
            for destination, _ in links:
                try:
                    resolved = destination.resolve()
                    if (not resolved.is_relative_to(target)
                            or any(p.casefold() == '.git' for p in resolved.relative_to(target).parts)):
                        raise Refused(stage)
                except RuntimeError:
                    raise Refused(stage)
            return target
        stage = 'snapshot'
        snapshot(merge, repo)
        base_tree = snapshot(base, scratch / 'base')
        ancestor = git('merge-base', base, merge).decode().strip()
        if ancestor != base:
            raise Refused(stage)
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
                     '--ancestor-repo', str(base_tree), '--history-repo', str(repo),
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
                changed = git('diff', '--no-renames', '--name-only', '-z', base, merge).decode().split('\0')
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
        subprocess.TimeoutExpired):
    print(f'plan check unavailable: {stage}', file=sys.stderr)
    sys.exit(2)
PY
