#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
tmp=$(fm_test_tmproot fm-capacity-reader)
python3 -B - "$ROOT" "$tmp" <<'PY'
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

root, tmp = map(Path, sys.argv[1:])
home, mate = (tmp / name for name in ('home', 'mate'))
for base in (home, mate):
    for name in ('config', 'data', 'state'):
        (base / name).mkdir(parents=True)
(home / 'config/lane-capacity').write_text('10 4\n')
policy = home / 'config/machine-admission.json'
policy.write_text(json.dumps({
    'schema': 'fm-machine-admission.v1', 'memory_floor_gib': 3,
    'memory_full_avg60_max': 5, 'disk_floor_gib': 0, 'disk_paths': [str(tmp)]}))
(home / 'data/secondmates.md').write_text(
    f'- mate - local (home: {mate}; scope: tests; projects: a; added 2026-09-01)\n')
(mate / '.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={home}\n')
mem, pressure = tmp / 'memory', tmp / 'pressure'
mem.write_text('MemAvailable: 16777216 kB\n')
pressure.write_text('full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n')
for index in range(8):
    base = home if index < 4 else mate
    worktree = tmp / f'worker-{index % 3}'
    worktree.mkdir(exist_ok=True)
    (base / f'state/worker-{index}.meta').write_text(f'kind=ship\nworktree={worktree}\n')
for base in (home, mate):
    (base / 'state/supervisor.meta').write_text('kind=secondmate\n')
user_home = tmp / 'user-home'
activity = user_home / '.config/skills-master/.agents/skills/activity/activity.sh'
activity.parent.mkdir(parents=True)
activity.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$2" > "$FM_ACTIVITY_HOME_LOG"
printf '%s\\n' "${3:-}" > "$FM_ACTIVITY_EXCLUDE_LOG"
[ "$1" = --machine-json ] && [ "$2" = "$FM_EXPECTED_ACTIVITY_HOME" ] && [ -d "$2" ] || exit 75
cat "$FM_ACTIVITY_FACTS"
''')
facts_file = tmp / 'activity.json'
facts_file.write_text(json.dumps({'readable': True, 'lanes': 3, 'target': 10, 'free_lanes': 7}))
env = dict(os.environ, FM_HOME=str(home), HOME=str(user_home),
           FM_CAPACITY_MEMINFO=str(mem), FM_CAPACITY_PRESSURE_FILE=str(pressure),
           FM_RESOURCE_CGROUP_FILE='/dev/null', FM_EXPECTED_ACTIVITY_HOME=str(home),
           FM_ACTIVITY_FACTS=str(facts_file), FM_ACTIVITY_HOME_LOG=str(tmp / 'activity-home'),
           FM_ACTIVITY_EXCLUDE_LOG=str(tmp / 'activity-exclude'))
env.pop('FM_ACTIVITY_READER', None)

def run(script, *args, expected=0, extra=None):
    result = subprocess.run(['bash', str(root / 'bin' / script), *args],
                            env={**env, **(extra or {})}, text=True, capture_output=True)
    assert result.returncode == expected, (script, args, result.stdout, result.stderr)
    return result.stdout

for script, args in [('fm-capacity.sh', ('--json',)),
                     ('fm-fleet-ledger.sh', ('capacity', '--json'))]:
    facts = json.loads(run(script, *args))
    assert (facts['lanes'], facts['free_lanes'], facts['secondmates']) == (3, 7, 2), facts
for script, args in [('fm-capacity.sh', ()), ('fm-fleet-view.sh', ('--capacity',))]:
    text = run(script, *args)
    assert 'lanes=3 target=10' in text and 'secondmates=2' in text, text
run('fm-capacity.sh', '--publish')
assert json.loads((home / 'state/lane-capacity.json').read_text())['secondmates'] == 2
run('fm-capacity.sh', '--admit')
print('ok - public consumers use the published activity JSON rather than eight retained worker records')
custom = tmp / 'custom-policy'
custom.mkdir()
(custom / 'lane-capacity').write_text('10 5\n')
shutil.copyfile(policy, custom / 'machine-admission.json')
facts = json.loads(run('fm-capacity.sh', '--json', extra={'FM_CONFIG_OVERRIDE': str(custom)}))
assert facts['config_file'] == str(custom / 'lane-capacity') and facts['reserve_kb'] == 5 * 1048576, facts
assert Path(env['FM_ACTIVITY_HOME_LOG']).read_text().strip() == str(home)
facts = json.loads(run('fm-capacity.sh', '--json', extra={'FM_HOME': str(mate), 'FM_CONFIG_OVERRIDE': str(custom)}))
assert facts['config_file'] == str(home / 'config/lane-capacity') and facts['secondmates'] == 2, facts
print('ok - arbitrary config overrides and child homes preserve the machine-home reader argument')
replacement = '''
for library in fm-wake-lib.sh fm-backend.sh fm-secondmate-registry-lib.sh fm-project-capacity-lib.sh fm-capacity-lib.sh; do
  source "$1/bin/$library"
done
fm_capacity_read "$FM_HOME" "$FM_HOME/config" "$FM_HOME/state" worker-0
fm_capacity_json
'''
result = subprocess.run(['bash', '-c', replacement, 'replace', str(root)], env=env, text=True, capture_output=True)
assert result.returncode == 0, (result.stdout, result.stderr)
assert Path(env['FM_ACTIVITY_EXCLUDE_LOG']).read_text().strip() == str(home / 'state/worker-0.meta')
print('ok - replacement admission forwards exactly its own task metadata path')

for mode in ('reserve', 'pressure', 'disk', 'full', 'reader', 'target', 'unsafe', 'config'):
    mem.write_text('MemAvailable: 2097152 kB\n' if mode == 'reserve' else 'MemAvailable: 16777216 kB\n')
    pressure.write_text('full avg10=0.00 avg60=6.00 avg300=0.00 total=0\n' if mode in ('reserve', 'pressure') else 'full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n')
    rules = json.loads(policy.read_text())
    rules['disk_floor_gib'] = 999999 if mode == 'disk' else 0
    policy.write_text(json.dumps(rules))
    facts_file.write_text(json.dumps({'readable': True, 'lanes': 10 if mode == 'full' else 3,
                                      'target': 11 if mode == 'target' else 10, 'free_lanes': 0 if mode == 'full' else 7}))
    if mode == 'unsafe': (mate / 'state/unsafe.meta').symlink_to(tmp / 'absent')
    extra = {'FM_ACTIVITY_READER': str(tmp / 'absent')} if mode == 'reader' else {}
    if mode == 'config': (home / 'config/lane-capacity').write_text('broken\n')
    result = subprocess.run(['bash', str(root / 'bin/fm-capacity.sh'), '--admit'], env={**env, **extra}, text=True, capture_output=True)
    assert result.returncode == 75, (mode, result.stdout, result.stderr)
    for field in ('available_kb=', 'pressure_full_avg60=', 'floor_kb=', 'reserve_kb=', 'pressure_limit='):
        assert field in result.stderr, (mode, field, result.stderr)
    if mode == 'reserve':
        for field in ('available_kb=2097152', 'pressure_full_avg60=6', 'floor_kb=3145728', 'reserve_kb=4194304', 'pressure_limit=5', 'memory PSI full avg60 refuses'):
            assert field in result.stderr, (field, result.stderr)
    if mode == 'unsafe': (mate / 'state/unsafe.meta').unlink()
(home / 'config/lane-capacity').write_text('10 4\n')
print('ok - every refusal path includes measured inputs or explicit unknowns; low reserve preserves simultaneous floor and pressure reasons')

transcript = tmp / 'transcript.jsonl'
user = {'type': 'user', 'message': {'role': 'user', 'content': 'Report current state.'}}

def guard(message, commands=(), expected=0, active=False, execute=False):
    rows = [user]
    for index, command in enumerate(commands):
        ident = str(index)
        result = subprocess.run(['bash', '-c', command], env=env, text=True, capture_output=True) if execute else None
        rows += [
            {'type': 'assistant', 'message': {'content': [
                {'type': 'tool_use', 'id': ident, 'name': 'Bash', 'input': {'command': command}}]}},
            {'type': 'user', 'message': {'content': [
                {'type': 'tool_result', 'tool_use_id': ident, 'content': result.stdout if result else 'OK',
                 'is_error': result.returncode != 0 if result else False}]}}]
    transcript.write_text(''.join(json.dumps(row) + '\n' for row in rows))
    result = subprocess.run([sys.executable, str(root / 'bin/fm-state-claim-guard.py')],
                            input=json.dumps({'hook_event_name': 'Stop', 'session_id': 'fixture',
                                              'stop_hook_active': active, 'transcript_path': str(transcript),
                                              'last_assistant_message': message}),
                            text=True, capture_output=True, env=env)
    assert result.returncode == expected, (message, commands, result.stdout, result.stderr)
    if expected == 2:
        assert '(capacity)' in result.stderr, result.stderr

read = f'bash {shlex.quote(str(activity))} --machine-json {shlex.quote(str(home))}'
for machine in ('MAIN', 'PC', 'server', 'laptop', 'zenbook', 'q-crew', 'zb-crew'):
    guard(f'{machine} merged PR #219.', ['gh pr view 219'])
    guard(f'The {machine} deployment is live.', ['curl https://service.example/health'])
    for measurement in ('3 working, 7 available', '3 of 10 occupied', '3/10 live', 'not full'):
        message = f'{machine}: {measurement}.'
        guard(message, expected=2)
        guard(message, expected=2, active=True)
        guard(message, [read], execute=True)
    guard(f'3 occupied on {machine}.', expected=2)
for message in ('Lane alpha is running.', 'There are 3 live lanes.', 'The server is full.',
                'The server has 2 free slots.', 'Capacity is 8.', 'Seats: 3 occupied.',
                'Laptop 8 live of 8, admission no.', '3 free', 'No room.', 'Lanes are not available.'):
    guard(message, expected=2)
    guard(message, expected=2, active=True)
    guard(message, [read, 'bash bin/fm-crew-state.sh alpha'])
failed = f'bash {shlex.quote(str(activity))} --machine-json /missing-home'
for command in (failed, f'{failed}; printf done', f'{failed}\nprintf done',
                f'{failed} | cat', f'{failed} || true', f'{failed} && printf done',
                f'printf done; {failed}', f'printf done | {failed}'):
    guard('PC: 3 working, 7 available.', [command], expected=2, execute=True)
for command in (read, f'\n {read}\n', f'FM_EXTRA=1 env {read}', f'{read} > {shlex.quote(str(tmp / "reading"))}'):
    guard('PC: 3 working, 7 available.', [command], execute=True)
guard('PC: 3 working, 7 available.', [f'{failed} || true', read], execute=True)
for command in ('gh pr view 219; printf done', 'gh pr view 219 | cat', 'gh pr view 219 || true'):
    guard('MAIN merged PR #219.', [command])
print('ok - machine measurements block without a successful standalone activity read while PR and deployment semantics remain intact')
PY
