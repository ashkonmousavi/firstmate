#!/usr/bin/env python3
"""Disposable focused execution and behavioral negative controls; no tracked edits."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

EVIDENCE = Path('/home/tegris/.no-mistakes/evidence/01M43JPN5CQXVHJPWPJ4KJAKEC')
ROOT = Path.cwd()
TARGET = 'test_arm_plumbs_a_configured_budget_into_the_check_shim'

if len(sys.argv) > 1 and sys.argv[1] == 'capture':
    temp_root, label = Path(sys.argv[2]), sys.argv[3]
    captured = []
    for home in sorted(temp_root.glob('arm-budget-*')):
        def read(relative):
            p = home / relative
            return p.read_text() if p.exists() else None
        prior = read('prior.json')
        current = read('data/delivery/contributions.json')
        captured.append({
            'mode': home.name.removeprefix('arm-budget-'),
            'clock_trace': read('forge/clock-trace'),
            'calls': read('forge/calls'),
            'generated_check': read('state/contributions.check.sh'),
            'prior_record': json.loads(prior) if prior else None,
            'current_record': json.loads(current) if current else None,
            'prior_record_byte_identical': prior == current,
            'durable_wake': read('state/.wake-queue'),
        })
    (EVIDENCE / f'{label}-state.json').write_text(json.dumps(captured, indent=2) + '\n')
    sys.exit(0)

source = (ROOT / 'tests/fm-contributions.test.sh').read_text()
base = subprocess.check_output(['git', 'show', '5e21b96150e4e834254a6a5c6f8ce1b3a7fb05fb:tests/fm-contributions.test.sh'], text=True)

instrumentation = r'''
eval "$(declare -f wrap_forge | sed '1s/wrap_forge/original_wrap_forge/')"
wrap_forge() {
  original_wrap_forge "$1"
  cat > "$1/fakebin/date" <<'CLOCK'
#!/usr/bin/env bash
if [ "$*" != +%s ]; then exec /bin/date "$@"; fi
if [ -f "$FORGE/clock" ]; then
  value=$(cat "$FORGE/clock")
  printf 'pinned %s\n' "$value" >> "$FORGE/clock-trace"
else
  value=$(cat "$FORGE/fallback-clock" 2>/dev/null || printf 1800000000)
  value=$((value + 1))
  printf '%s\n' "$value" > "$FORGE/fallback-clock"
  printf 'ticking-fallback %s\n' "$value" >> "$FORGE/clock-trace"
fi
printf '%s\n' "$value"
CLOCK
  chmod +x "$1/fakebin/date"
  if [ "${SUPPRESS_READ_LOG:-0}" = 1 ]; then
    sed '/^printf .* >> "\$FORGE\/calls"$/d' "$1/fakebin/gh" > "$1/fakebin/gh-without-log"
    mv "$1/fakebin/gh-without-log" "$1/fakebin/gh"
    chmod +x "$1/fakebin/gh"
  fi
}
'''
script = ROOT / 'tests/.nm-contribution-focus.sh'
workspace = ROOT / '.nm-contribution-validation'
workspace.mkdir()
results = []

def execute(label, content, *, tick=False, mode=None, remove_pin=False, suppress_log=False):
    definitions = content.split('\nfailures=0\n')[0]
    if mode is not None or remove_pin:
        start = definitions.index(TARGET + '() {')
        end = definitions.index('\n}\n', start) + 3
        function = definitions[start:end]
        if mode:
            function = function.replace('for mode in configured inherited; do', f'for mode in {mode}; do')
        if remove_pin:
            function = function.replace('    /bin/date +%s > "$home/forge/clock"\n', '')
        definitions = definitions[:start] + function + definitions[end:]
    tail = instrumentation if tick else ''
    tail += '\ntrap \'python3 "$CAPTURE_DRIVER" capture "$TMP_ROOT" "$RUN_LABEL"; fm_test_cleanup\' EXIT\n'
    tail += TARGET + '\n'
    script.write_text(definitions + tail)
    env = os.environ.copy()
    env.update(TMPDIR=str(workspace), CAPTURE_DRIVER=str(EVIDENCE / 'contribution-check-driver.py'),
               RUN_LABEL=label, SUPPRESS_READ_LOG=str(int(suppress_log)))
    started = time.monotonic()
    completed = subprocess.run(['bash', str(script)], env=env, text=True, capture_output=True, timeout=25)
    elapsed = round(time.monotonic() - started, 3)
    (EVIDENCE / f'{label}.log').write_text(completed.stdout + completed.stderr)
    state = json.loads((EVIDENCE / f'{label}-state.json').read_text())
    result = {'label': label, 'exit_code': completed.returncode, 'elapsed_seconds': elapsed,
              'stdout': completed.stdout, 'stderr': completed.stderr, 'state': state}
    results.append(result)
    print(json.dumps({k: result[k] for k in ('label','exit_code','elapsed_seconds','stdout','stderr')}), flush=True)
    return result

try:
    regular = execute('target-baseline', source)
    assert regular['exit_code'] == 0
    for number in range(1, 6):
        result = execute(f'target-ticking-{number}', source, tick=True)
        assert result['exit_code'] == 0
        assert len(result['state']) == 2
        for state in result['state']:
            assert state['calls'] == 'api repos/o/r/pulls/8\n'
            assert state['prior_record_byte_identical']
            assert not state['durable_wake']
            assert state['clock_trace'] and 'ticking-fallback' not in state['clock_trace']
    for mode in ('configured', 'inherited'):
        result = execute(f'base-ticking-{mode}', base, tick=True, mode=mode)
        assert result['exit_code'] == 1
        assert 'generated check did not attempt a read' in result['stderr']
        assert result['state'][0]['calls'] is None
        assert 'ticking-fallback' in result['state'][0]['clock_trace']
        result = execute(f'target-unpinned-{mode}', source, tick=True, mode=mode, remove_pin=True)
        assert result['exit_code'] == 1
        assert result['stderr'] == 'not ok - generated check did not attempt a read\n'
        assert result['state'][0]['calls'] is None
        result = execute(f'target-unlogged-{mode}', source, tick=True, mode=mode, suppress_log=True)
        assert result['exit_code'] == 1
        assert result['stderr'] == 'not ok - generated check did not attempt a read\n'
        assert result['state'][0]['calls'] is None
        assert result['elapsed_seconds'] < 4
finally:
    (EVIDENCE / 'contribution-check-results.json').write_text(json.dumps(results, indent=2) + '\n')
    script.unlink(missing_ok=True)
    shutil.rmtree(workspace)
