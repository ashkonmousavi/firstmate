#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
tmp=$(fm_test_tmproot fm-capacity-reader)
python3 -B - "$ROOT" "$tmp" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

root, tmp = map(Path, sys.argv[1:])
home, mate, proc = (tmp / name for name in ('home', 'mate', 'proc'))
for base in (home, mate):
    for name in ('config', 'data', 'state'):
        (base / name).mkdir(parents=True)
proc.mkdir()
(home / 'config/lane-capacity').write_text('10 4\n')
(home / 'config/machine-admission.json').write_text(json.dumps({
    'schema': 'fm-machine-admission.v1', 'memory_floor_gib': 3,
    'memory_full_avg60_max': 5, 'disk_floor_gib': 0, 'disk_paths': [str(tmp)]}))
(home / 'data/secondmates.md').write_text(
    f'- mate - local (home: {mate}; scope: tests; projects: a; added 2026-09-01)\n')
mem, pressure = tmp / 'memory', tmp / 'pressure'
mem.write_text('MemAvailable: 16777216 kB\n')
pressure.write_text('full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n')
for index in range(8):
    base = home if index < 4 else mate
    worktree = tmp / f'worker-{index}'
    worktree.mkdir()
    (base / f'state/worker-{index}.meta').write_text(f'kind=ship\nworktree={worktree}\n')
    if index in (0, 1, 4):
        process = proc / str(100 + index)
        process.mkdir()
        (process / 'comm').write_text('codex\n')
        (process / 'cmdline').write_bytes(b'codex\0')
        (process / 'cwd').symlink_to(worktree)
for base in (home, mate):
    (base / 'state/supervisor.meta').write_text('kind=secondmate\n')
env = dict(os.environ, FM_HOME=str(home), HOME=str(tmp / 'empty-user-home'),
           FM_ACTIVITY_PROC_ROOT=str(proc), FM_CAPACITY_MEMINFO=str(mem),
           FM_CAPACITY_PRESSURE_FILE=str(pressure), FM_CAPACITY_CGROUP_FILE='/dev/null')

def run(script, *args, expected=0, extra=None):
    result = subprocess.run(['bash', str(root / 'bin' / script), *args],
                            env={**env, **(extra or {})}, text=True, capture_output=True)
    assert result.returncode == expected, (script, args, result.stdout, result.stderr)
    return result.stdout

facts = json.loads(run('activity.sh', '--machine-json', str(home)))
assert (facts['lanes'], facts['target'], facts['free_lanes'], facts['secondmates']) == (3, 10, 7, 2), facts
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
print('ok - stock reader and public capacity consumers report three live workers, seven free seats and two secondmates')
facts = json.loads(run('activity.sh', '--machine-json', str(home), str(mate / 'state/worker-4.meta')))
assert (facts['lanes'], facts['secondmates']) == (2, 2), facts
print('ok - replacement excludes only its task across local homes')
run('fm-capacity.sh', '--admit', expected=75, extra={'FM_ACTIVITY_PROC_ROOT': str(tmp / 'absent')})
(mate / 'state/unsafe.meta').symlink_to(tmp / 'absent')
run('activity.sh', '--machine-json', str(home), expected=75)
(mate / 'state/unsafe.meta').unlink()
print('ok - unavailable process inventory and unsafe records refuse admission')

transcript = tmp / 'transcript.jsonl'
user = {'type': 'user', 'message': {'role': 'user', 'content': 'Report current state.'}}

def guard(message, commands=(), expected=0, active=False):
    rows = [user]
    for index, command in enumerate(commands):
        ident = str(index)
        rows += [
            {'type': 'assistant', 'message': {'content': [
                {'type': 'tool_use', 'id': ident, 'name': 'Bash', 'input': {'command': command}}]}},
            {'type': 'user', 'message': {'content': [
                {'type': 'tool_result', 'tool_use_id': ident, 'content': 'OK'}]}}]
    transcript.write_text(''.join(json.dumps(row) + '\n' for row in rows))
    result = subprocess.run([sys.executable, str(root / 'bin/fm-state-claim-guard.py')],
                            input=json.dumps({'hook_event_name': 'Stop', 'session_id': 'fixture',
                                              'stop_hook_active': active, 'transcript_path': str(transcript),
                                              'last_assistant_message': message}),
                            text=True, capture_output=True, env=env)
    assert result.returncode == expected, (message, result.stdout, result.stderr)
    if expected == 2:
        assert '(capacity)' in result.stderr, result.stderr

for machine in ('MAIN', 'PC', 'server', 'laptop', 'zenbook', 'q-crew', 'zb-crew'):
    guard(f'{machine} merged PR #219.', ['gh pr view 219'])
    guard(f'The {machine} deployment is live.', ['curl https://service.example/health'])
for message in ('Lane alpha is running.', 'There are 3 live lanes.', 'The server is full.',
                'The server has 2 free slots.', 'Capacity is 8.', 'Seats: 3 occupied.',
                'Laptop 8 live of 8, admission no.', '3 free', 'No room.'):
    guard(message, expected=2)
    guard(message, expected=2, active=True)
    guard(message, [f'bash {root}/bin/activity.sh --machine-json {home}',
                    'bash bin/fm-crew-state.sh alpha'])
guard('MAIN merged PR #219.', ['gh pr view 219'], active=True)
guard('The server deployment is live.', ['curl https://service.example/health'], active=True)
print('ok - only capacity assertions require activity, including repeated unsupported incident replies')
PY
