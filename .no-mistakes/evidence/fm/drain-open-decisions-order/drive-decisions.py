#!/usr/bin/env python3
"""Run real drain commands over disposable status records; retain public output."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path('~/.no-mistakes/worktrees/049a88734b0e/01M6JWPS49Z5JGRXZ55JC2AV4X')
EVIDENCE = Path('~/.no-mistakes/evidence/01M6JWPS49Z5JGRXZ55JC2AV4X')
WORK = ROOT / '.test-disposable' / 'manual'
WORK.mkdir(parents=True, exist_ok=True)
results = {}

def environment(home):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('FM_', 'HERDR_', 'REX_', 'TASKS_AXI_'))
           and k not in ('TMUX', 'TERM_PROGRAM', 'STATE', 'CONFIG', 'GIT_DIR', 'GIT_WORK_TREE')}
    env.update(FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home),
               FM_STATE_OVERRIDE=str(home / 'state'), FM_CONFIG_OVERRIDE=str(home / 'config'),
               FM_DATA_OVERRIDE=str(home / 'data'), FM_PROJECTS_OVERRIDE=str(home / 'projects'),
               TMPDIR=str(ROOT / '.test-disposable' / 'tmp'))
    return env

def home(name):
    h = WORK / name
    for part in ('state', 'config', 'data', 'projects'):
        (h / part).mkdir(parents=True, exist_ok=True)
    return h

def drain(h, name, binary=ROOT / 'bin' / 'fm-wake-drain.sh'):
    result = subprocess.run([str(binary)], env=environment(h), cwd=ROOT,
                            capture_output=True, text=True, timeout=120)
    (EVIDENCE / (name + '.stdout.txt')).write_text(result.stdout)
    (EVIDENCE / (name + '.stderr.txt')).write_text(result.stderr)
    assert result.returncode == 0, (name, result.returncode, result.stderr)
    return result.stdout

def rows(out):
    if 'OPEN DECISIONS (' not in out:
        return []
    return out.split('OPEN DECISIONS (', 1)[1].split('\n', 1)[1].split('OPEN DECISIONS:', 1)[0].splitlines()

def account(out, total):
    shown = rows(out)
    omitted = re.search(r'^OPEN DECISIONS: (\d+) more omitted', out, re.M)
    n = int(omitted[1]) if omitted else 0
    assert len(shown) + n == total, (len(shown), n, total)
    assert len(('\n'.join(shown) + '\n').encode()) <= 4000
    assert all(len(x.encode()) + 1 <= 220 for x in shown)
    return {'shown': len(shown), 'omitted': n, 'total': total}

try:
    h = home('stale-tail')
    old = h / 'state' / 'a-old.status'
    old.write_text(''.join(f'needs-decision [key=old-{i}] [at=1793770000]: old unresolved decision {i}\n' for i in range(250)))
    digest = hashlib.sha256(old.read_bytes()).hexdigest()
    drain(h, '01-warm-old-cursor')
    fresh = h / 'state' / 'x-line-plan.status'
    fresh.write_text('needs-decision [key=plan-boundaries] [at=1793775437] [corr=50be5d80888f8495]: choose the plan boundary\n')
    wanted = 'x-line-plan [key=plan-boundaries] needs-decision: choose the plan boundary'
    for label in ('02-fresh-after-250-old', '03-repeat-with-no-new-wake'):
        out = drain(h, label)
        assert rows(out)[0] == wanted, rows(out)[:2]
        results[label] = account(out, 251)

    # Exercise a queued drain via the real durable queue writer, with no backend.
    command = '. "$1"; fm_wake_append check unrelated "working: unrelated queue record"'
    queued = subprocess.run(['bash', '-c', command, '_', str(ROOT / 'bin' / 'fm-wake-lib.sh')],
                            env=environment(h), capture_output=True, text=True, timeout=30)
    assert queued.returncode == 0, queued.stderr
    out = drain(h, '04-unrelated-queued-wake')
    assert '\tcheck\tunrelated\tworking: unrelated queue record' in out
    assert rows(out)[0] == wanted
    results['04-unrelated-queued-wake'] = account(out, 251)
    assert hashlib.sha256(old.read_bytes()).hexdigest() == digest
    results['old-records'] = {'sha256_before_and_after': digest, 'records_unchanged': 250}

    # Matching resolution removes only that decision; a new keyless event must win.
    with fresh.open('a') as f:
        f.write('resolved [key=plan-boundaries] [at=1793775438]: answered\n')
        f.write('blocked [at=1793775439]: latest keyless decision\n')
    out = drain(h, '05-resolution-and-keyless-arrival')
    assert rows(out)[0] == 'x-line-plan blocked: latest keyless decision'
    assert all('[key=plan-boundaries]' not in line for line in rows(out))
    results['05-resolution-and-keyless-arrival'] = account(out, 251)
    with fresh.open('a') as f:
        f.write('needs-decision [key=plan-boundaries] [at=1793775440]: reopened plan boundary\n')
    out = drain(h, '06-reopened-decision')
    assert rows(out)[:2] == ['x-line-plan [key=plan-boundaries] needs-decision: reopened plan boundary',
                             'x-line-plan blocked: latest keyless decision']
    results['06-reopened-decision'] = account(out, 252)
    assert hashlib.sha256(old.read_bytes()).hexdigest() == digest

    n = home('numeric-keyless-legacy')
    (n / 'state' / 'z.status').write_text('needs-decision [key=legacy]: unstamped legacy\nneeds-decision [key=older] [at=999]: numeric older\nneeds-decision [key=newer] [at=10000]: numeric newer\nblocked [at=10001]: newest keyless\n')
    (n / 'state' / 'a.status').write_text('needs-decision [key=b] [at=10000]: tie second key\nneeds-decision [key=a] [at=10000]: tie first key\n')
    expected = ['z blocked: newest keyless', 'a [key=a] needs-decision: tie first key',
                'a [key=b] needs-decision: tie second key', 'z [key=newer] needs-decision: numeric newer',
                'z [key=older] needs-decision: numeric older', 'z [key=legacy] needs-decision: unstamped legacy']
    out = drain(n, '07-numeric-keyless-legacy-ties')
    assert rows(out) == expected, rows(out)
    results['07-numeric-keyless-legacy-ties'] = account(out, 6)

    # A long newest note must be admitted first and clearly marked as truncated.
    (h / 'state' / 'zz-long.status').write_text('needs-decision [key=long] [at=1793775441]: latest long note ' + 'detail ' * 100 + '\n')
    out = drain(h, '08-newest-long-note-cap')
    assert rows(out)[0].startswith('zz-long [key=long] needs-decision: latest long note ')
    assert rows(out)[0].endswith(' [truncated]')
    results['08-newest-long-note-cap'] = account(out, 253)
    assert hashlib.sha256(old.read_bytes()).hexdigest() == digest

    # Replay the same adversarial input against the actual base production files.
    base = WORK / 'base-bin'
    base.mkdir()
    changed = {'fm-wake-drain.sh', 'fm-classify-lib.sh'}
    for source in (ROOT / 'bin').iterdir():
        if source.name not in changed:
            (base / source.name).symlink_to(source)
    for name in changed:
        content = subprocess.run(['git', 'show', '5c4cea93cfd9e70c662d8847ad4a9cc0d22218f5:bin/' + name],
                                 cwd=ROOT, capture_output=True, check=True).stdout
        (base / name).write_bytes(content)
        (base / name).chmod(0o755)
    red = home('pre-fix-red')
    shutil.copyfile(old, red / 'state' / 'a-old.status')
    drain(red, '09-base-warm-old-cursor', base / 'fm-wake-drain.sh')
    (red / 'state' / 'x-line-plan.status').write_text('needs-decision [key=plan-boundaries] [at=1793775437] [corr=50be5d80888f8495]: choose the plan boundary\n')
    out = drain(red, '10-base-reproduces-starvation', base / 'fm-wake-drain.sh')
    assert wanted not in rows(out), 'base did not reproduce the reported regression'
    results['10-base-reproduces-starvation'] = {'fresh_missing_from_open_decisions': True, **account(out, 251)}
    (EVIDENCE / 'manual-results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))
finally:
    shutil.rmtree(WORK)
