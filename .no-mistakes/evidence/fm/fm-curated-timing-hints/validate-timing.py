#!/usr/bin/env python3
"""Run from the gate worktree. Executes the runner; never executes fixture suites.
Oracle: docs/fm-test-portable-shards.md requires a disjoint complete nine-shard
partition, <=15% unhinted serial members and a <=1,200,000 ms packed shard.
The base runner must reproduce the intent's 39/255 failure. A disabled coverage
guard, dropped/duplicated suite, or ignored new weight must fail this validation.
"""
import collections
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
evidence = Path('~/.no-mistakes/evidence/01M6AMK9V9D6VRPCG9W8S1NJBG')
runner = root / 'bin/fm-test-run.sh'
work = root / '.validation-timing'
env = dict(os.environ, TMPDIR=str(work / 'tmp'))
transcript = []

def call(executable, *args, expected=0, record=True):
    p = subprocess.run([str(executable), *args], cwd=root, env=env,
                       text=True, capture_output=True, timeout=120)
    if record:
        transcript.append('$ ' + str(executable.relative_to(root)) + ' ' + ' '.join(args))
        transcript.append(p.stdout + p.stderr)
        transcript.append(f'exit={p.returncode}\n')
    assert p.returncode == expected, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout + p.stderr

try:
    current = call(runner, '--check-coverage')
    assert 'FM_TEST_COVERAGE ok ' in current
    fields = dict(token.split('=', 1) for token in current.split() if '=' in token)
    assert int(fields['serial']) == 255
    assert int(fields['serial_unhinted']) == 0
    assert int(fields['serial_max_ms']) <= 1200000
    inventory = call(runner, '--list', '--all', record=False).splitlines()
    fixture = Path(tempfile.mkdtemp(prefix='inventory-', dir=work))
    (fixture / 'bin').mkdir()
    (fixture / 'tests').mkdir()
    for script in inventory:
        (fixture / script).touch()
    fixture_runner = fixture / 'bin/fm-test-run.sh'
    base = subprocess.run(['git', 'show', 'ee1fcd6f14c2df2be31bc119171bc3f7c6014f3f:bin/fm-test-run.sh'],
                          check=True, text=True, capture_output=True).stdout
    fixture_runner.write_text(base)
    fixture_runner.chmod(0o755)
    before = call(fixture_runner, '--check-coverage', expected=1)
    assert '39 of 255 portable serial scripts have no measured duration hint (max 15%)' in before
    shutil.copy2(runner, fixture_runner)
    after = call(fixture_runner, '--check-coverage')
    assert after == current

    lanes = call(runner, '--list-lanes', record=False).splitlines()
    serial_lanes = [lane for lane in lanes if lane.startswith('portable-serial-')]
    assert serial_lanes == [f'portable-serial-{i}of9' for i in range(1, 10)]
    serial = call(runner, '--list', '--lane', 'portable-serial', record=False).splitlines()
    packed = []
    memberships = {}
    for lane in serial_lanes:
        listing = call(runner, '--list', '--lane', lane, record=False).splitlines()
        again = call(runner, '--list', '--lane', lane, record=False).splitlines()
        assert listing and listing == again
        memberships[lane] = listing
        packed += listing
    assert collections.Counter(packed) == collections.Counter(serial)
    assert len(packed) == len(set(packed)) == 255
    evidence.joinpath('serial-shard-membership.json').write_text(json.dumps(memberships, indent=2) + '\n')
    transcript.append('Nine non-empty deterministic serial shards contain all 255 serial scripts exactly once. Full CLI output: serial-shard-membership.json\n')

    schedule = call(runner, '--list-scheduled', 'tests/fm-backlog-atomicity.test.sh', 'tests/fm-lane-release.test.sh')
    assert schedule.splitlines() == ['tests/fm-lane-release.test.sh', 'tests/fm-backlog-atomicity.test.sh']
    transcript.append('Worked-example oracle: added 235129ms lane-release weight exceeds existing 219379ms backlog-atomicity weight; longest-first scheduling must place lane-release first.\n')

    # Add genuinely unhinted inventory through the public discovery interface.
    # 46 / (255 + 46) = 15.282%, so the unchanged 15% guard must refuse.
    for i in range(46):
        (fixture / 'tests' / f'validation-unhinted-{i:03}.test.sh').touch()
    refused = call(fixture_runner, '--check-coverage', expected=1)
    assert '46 of 301 portable serial scripts have no measured duration hint (max 15%)' in refused
    assert 'FM_TEST_COVERAGE ok' not in refused
    transcript.append('All live runner scenarios passed; inventory fixtures were inspected, never executed.\n')
finally:
    evidence.joinpath('live-timing-validation.log').write_text('\n'.join(transcript))
    if 'fixture' in locals():
        shutil.rmtree(fixture)
