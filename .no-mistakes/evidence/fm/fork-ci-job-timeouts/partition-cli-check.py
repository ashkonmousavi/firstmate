import collections
import json
import os
from pathlib import Path
import subprocess

EVIDENCE = Path('~/.no-mistakes/evidence/01M62DBVG9AV2AZY4J16W800MY')
records = []

def invoke(args, ci=False):
    env = dict(os.environ, CI='true' if ci else 'false', GITHUB_ACTIONS='false')
    proc = subprocess.run(['bin/fm-lint.sh', *args], env=env, text=True, capture_output=True, timeout=90)
    records.append(dict(command=['bin/fm-lint.sh', *args], CI=env['CI'], exit_status=proc.returncode, stdout=proc.stdout, stderr=proc.stderr))
    return proc

try:
    # Oracle: the documented canonical inventory is direct *.sh children of
    # bin/, bin/backends/, and tests/; no implementation-derived weighting rule.
    expected = sorted(str(p) for d in ['bin', 'bin/backends', 'tests'] for p in Path(d).glob('*.sh') if p.is_file())
    canonical = invoke(['--list-files'], ci=True)
    assert canonical.returncode == 0
    assert sorted(canonical.stdout.splitlines()) == expected
    summary = {'canonical_roots': len(expected), 'partitions': {}}
    for total in [4, 2]:
        union = []
        loads = []
        for index in range(1, total + 1):
            part = f'{index}of{total}'
            first = invoke(['--partition', part, '--list-files'])
            second = invoke([f'--partition={part}', '--list-files'], ci=True)
            assert first.returncode == second.returncode == 0, part
            assert first.stdout == second.stdout, f'{part}: spelling/environment changed selection'
            roots = first.stdout.splitlines()
            assert roots, part
            assert len(roots) == len(set(roots)), f'{part}: duplicate roots'
            union.extend(roots)
            size = sum(Path(p).stat().st_size for p in roots)
            loads.append(size)
            summary['partitions'][part] = {'roots': len(roots), 'bytes': size}
        assert collections.Counter(union) == collections.Counter(expected), f'{total}: lost/duplicated roots'
        # A conservative independent scheduling property, not a duplicate of
        # the greedy implementation: the spread cannot exceed one largest root.
        assert max(loads) - min(loads) <= max(Path(p).stat().st_size for p in expected)
    summary['invalid_options'] = []
    for invalid in ['0of2', '3of2', '1of1', '1of3', '1of5', '1of6', '1of7', '1of8', '1of9', '0of4', '5of4', '1of', '2of2x', 'abc', '']:
        for args in [['--partition', invalid, '--list-files'], [f'--partition={invalid}', '--list-files']]:
            result = invoke(args)
            assert result.returncode == 2 and not result.stdout and result.stderr, args
        summary['invalid_options'].append(invalid)
    missing = invoke(['--partition'])
    assert missing.returncode == 2 and missing.stderr and not missing.stdout
    summary['weakened_modes_rejected'] = []
    for part in ['1of2', '1of4', '4of4']:
        for extra in [['--fast', '--list-files'], ['--list-files', 'bin/fm-lint.sh']]:
            result = invoke(['--partition', part, *extra])
            assert result.returncode == 2 and not result.stdout
            assert 'full canonical lint' in result.stderr
            summary['weakened_modes_rejected'].append([part, *extra])
    summary['result'] = 'pass'
    print(json.dumps(summary, indent=2))
    (EVIDENCE / 'partition-cli-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
finally:
    (EVIDENCE / 'partition-cli-transcript.json').write_text(json.dumps(records, indent=2) + '\n')
