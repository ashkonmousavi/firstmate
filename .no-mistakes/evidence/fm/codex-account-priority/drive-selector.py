"""Repeatable selector verification; no operator credentials or fleet state.
Run from the gate worktree: python3 <this-file> <workspace-local-scratch>.
Native Codex is real. Measured-quota cases use an explicit external-tool adapter;
these do not establish native quota accuracy or actual ChatGPT account use.
"""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

repo = Path.cwd()
root = Path(sys.argv[1]).absolute()
assert root.is_relative_to(repo) and not root.exists()
root.mkdir()
config = root / 'config'
config.mkdir()
preferred, fallback = root / 'z-preferred', root / 'a-fallback'
for i, folder in enumerate((preferred, fallback)):
    (folder / 'rules').mkdir(parents=True)
    (folder / 'auth.json').write_text(json.dumps({'OPENAI_API_KEY': 'sk-synthetic-local-only-' + str(i) * (i + 1)}))
    (folder / 'config.toml').write_text('cli_auth_credentials_store="file"\nmodel="gpt-5.4"\n[features]\nplugins=false\napps=false\n')
    (folder / 'AGENTS.md').write_text('Disposable selector verification.\n')
    (folder / 'rules' / 'default.rules').write_text('prefix_rule(pattern=["echo"],decision="allow")\n')
(config / 'codex-accounts').write_text(f'{preferred}\n{fallback}\n')
(config / 'claude-account').write_text('ordinary\n')
(config / 'pi-account').write_text('ordinary\nopenai\n')
(root / 'home').mkdir()
(root / 'tmp').mkdir()
env = {k: os.environ[k] for k in ('PATH', 'USER', 'LOGNAME') if k in os.environ}
env.update(HOME=str(root / 'home'), TMPDIR=str(root / 'tmp'))
basepath = env['PATH']
helper = [sys.executable, str(repo / 'bin/fm-codex-accounts.py')]
records = []

def emit(name, command, expected_root=None, refusal=False, gate=False):
    args = helper + command + ['--config', str(config / 'codex-accounts'), '--cwd', str(root)]
    result = subprocess.run(args, env=env, text=True, capture_output=True, timeout=90)
    selected = None
    if result.returncode == 0:
        selected = json.loads(result.stdout)['selectedRoot'] if command[0] == 'quota' else result.stdout.split('\t')[0]
    record = {'scenario': name, 'command': ['python3', 'bin/fm-codex-accounts.py'] + command,
              'quota_source': 'native quota-axi with synthetic API caches' if env['PATH'] == basepath else 'controlled external quota adapter',
              'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}
    print(json.dumps(record), flush=True)
    records.append(record)
    if refusal:
        assert result.returncode == 1 and 'repair' in result.stderr, record
    else:
        assert result.returncode == 0, record
        if expected_root is not None:
            assert selected == str(expected_root), record
        if gate:
            payload = json.loads(result.stdout)
            assert payload['selectedModel'] == 'gpt-5.4' and len(payload['providers']) == 1, record

protected = [config / p for p in ('codex-accounts', 'claude-account', 'pi-account')] + [p / 'auth.json' for p in (preferred, fallback)]
before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in protected}
try:
    print(json.dumps({'codex': subprocess.check_output(['codex', '--version'], env=env, text=True).strip(),
                      'quota-axi': subprocess.check_output(['quota-axi', '--version'], env=env, text=True).strip()}), flush=True)
    emit('native unknown quota retains configured preference and reads concrete default model', ['select', '--model', 'default'], preferred)
    emit('native exact-folder quota handoff retains preferred account', ['quota', '--gate', '--model', 'default'], preferred, gate=True)
    saved = (preferred / 'auth.json').read_bytes()
    (preferred / 'auth.json').unlink()
    emit('native signed-out preferred with unknown quota refuses account switch', ['select', '--model', 'gpt-5.4'], refusal=True)
    emit('explicit fallback cannot bypass native preferred repair', ['select', '--folder', str(fallback), '--model', 'gpt-5.4'], refusal=True)
    (preferred / 'auth.json').write_bytes(saved)
    saved_config = (preferred / 'config.toml').read_bytes()
    (preferred / 'config.toml').unlink()
    emit('native missing preferred configuration with unknown quota refuses', ['select', '--model', 'gpt-5.4'], refusal=True)
    (preferred / 'config.toml').write_text('this is invalid TOML = [\n')
    status = subprocess.run(['codex', '-c', 'cli_auth_credentials_store="file"', 'login', 'status'],
        env=dict(env, CODEX_HOME=str(preferred)), text=True, capture_output=True, timeout=30)
    print(json.dumps({'scenario': 'native status command fails on malformed preferred configuration',
        'exit': status.returncode, 'stderr': status.stderr}), flush=True)
    assert status.returncode != 0
    emit('native failed preferred status read refuses switch', ['select', '--model', 'gpt-5.4'], refusal=True)
    (preferred / 'config.toml').write_bytes(saved_config)
    adapter = root / 'quota-adapter'
    adapter.mkdir()
    exe = adapter / 'quota-axi'
    exe.write_text('#!/usr/bin/env python3\nimport os,pathlib,sys\nsys.stdout.write((pathlib.Path(os.environ["CODEX_HOME"])/"quota-fixture.json").read_text())\n')
    exe.chmod(0o700)
    env['PATH'] = str(adapter) + os.pathsep + basepath
    def quota(folder, seconds=14400, state='projected_exhaustion', scope='all_models', percent=10, fresh=True, aged=0, absolute=None):
        clock = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=aged)
        runway = {'status': state, 'usableRunwaySeconds': seconds}
        if absolute is not None:
            runway['projectedExhaustedAt'] = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=absolute)).isoformat()
        payload = {'generatedAt': clock.isoformat(), 'providers': [{'provider': 'codex', 'state': {'status': 'fresh' if fresh else 'stale'},
            'windows': [{'id': 'weekly', 'kind': 'weekly', 'percentRemaining': percent}],
            'quotaSemantics': {'status': 'known', 'effectiveAvailability': [{'scope': scope, 'status': 'known',
                'effectivePercentRemaining': percent, 'runway': runway}]}}]}
        (folder / 'quota-fixture.json').write_text(json.dumps(payload))
    quota(fallback, percent=90)
    quota(preferred)
    emit('preferred lower credit wins with more than three hours runway', ['select', '--model', 'default'], preferred)
    quota(preferred, seconds=7200)
    emit('less than three hours authorizes fallback', ['select', '--model', 'default'], fallback)
    emit('quota gate returns the same concrete fallback model and account', ['quota', '--gate', '--model', 'default'], fallback, gate=True)
    quota(preferred, state='exhausted_now', percent=0)
    emit('known exhaustion authorizes fallback', ['select', '--model', 'gpt-5.4'], fallback)
    quota(preferred, seconds=14400, aged=7200)
    emit('aged relative runway is measured from reading time', ['select', '--model', 'gpt-5.4'], fallback)
    quota(preferred, seconds=14400, absolute=7200)
    emit('absolute short runway overrides longer relative runway', ['select', '--model', 'gpt-5.4'], fallback)
    quota(preferred, seconds=7200, scope='model:other')
    emit('unrelated model exhaustion cannot authorize fallback', ['select', '--model', 'gpt-5.4'], preferred)
    quota(preferred, seconds=0, state='through_reset')
    emit('through-reset reading preserves preference', ['select', '--model', 'gpt-5.4'], preferred)
    quota(preferred, seconds=0, state='exhausted_now', fresh=False)
    emit('stale exhaustion cannot authorize fallback', ['select', '--model', 'gpt-5.4'], preferred)
    quota(preferred, seconds=7200)
    (config / 'quota-gate').write_text('rank-only\n')
    emit('rank-only retains preferred below horizon with notice', ['select', '--model', 'gpt-5.4'], preferred)
    after = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in protected}
    assert before == after, 'credential files or account pins changed'
    print(json.dumps({'contract': 'disposable credential bytes and all account pins preserved', 'unchanged': True}), flush=True)
finally:
    shutil.rmtree(root)
    print(json.dumps({'cleanup': 'removed all disposable selector folders'}), flush=True)
