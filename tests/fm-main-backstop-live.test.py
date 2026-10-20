"""Read-only guard against provisioned real Herdr agents and stale shell labels.

FM_MAIN_BACKSTOP_LIVE_HOMES is a JSON object mapping each installed supported
harness to its unique live home and "shell" to a home containing a bare shell
with a stale Claude/Codex label. No pane is created, modified, or sent input.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(os.environ['ROOT'])
spec = importlib.util.spec_from_file_location('backstop', ROOT / 'bin/fm-main-backstop.py')
backstop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backstop)
homes = json.loads(os.environ.get('FM_MAIN_BACKSTOP_LIVE_HOMES', '{}'))
env = dict(os.environ)
checked = 0
failed = False

for harness in ('claude', 'codex'):
    if not shutil.which(harness):
        print('skip: %s absent' % harness)
        continue
    version = subprocess.run([harness, '--version'], capture_output=True,
                             text=True, timeout=15).stdout.strip()
    try:
        if harness not in homes:
            raise AssertionError('missing provisioned live home in FM_MAIN_BACKSTOP_LIVE_HOMES')
        home = Path(homes[harness])
        pane = backstop.live_primary(home, env)
        listing = json.loads(backstop.run(['herdr', 'pane', 'list'], env))
        actual = next(p for p in listing['result']['panes'] if p['pane_id'] == pane)
        assert actual['agent'] == harness, 'discovered another harness'
        try:
            backstop.live_primary(home / 'backstop-wrong-home', env)
        except backstop.ProbeError:
            pass
        else:
            raise AssertionError('accepted a different home')
        print('ok - %s (%s): exact-home discovery and wrong-home refusal' % (harness, version))
        checked += 1
    except Exception as error:
        print('not ok - %s (%s): %s' % (harness, version, error))
        failed = True

try:
    assert checked, 'no real harness checked'
    assert 'shell' in homes, 'missing provisioned stale-label shell home'
    home = Path(homes['shell'])
    listing = json.loads(backstop.run(['herdr', 'pane', 'list'], env))
    candidates = [p for p in listing['result']['panes']
                  if p.get('cwd') == str(home) and p.get('agent') in ('claude', 'codex')]
    assert candidates, 'shell case has no stale agent label'
    for pane in candidates:
        info = json.loads(backstop.run(['herdr', 'pane', 'process-info', '--pane', pane['pane_id']], env))
        processes = info['result']['process_info']['foreground_processes']
        assert processes and all(p.get('name') in ('bash', 'zsh', 'sh', 'fish')
                                 and p.get('pid', 0) > 0 for p in processes), 'case is not a live bare shell'
    try:
        backstop.live_primary(home, env)
    except backstop.ProbeError:
        pass
    else:
        raise AssertionError('accepted a bare shell with stale agent metadata')
    print('ok - Herdr: stale-label bare shells refused')
except Exception as error:
    print('not ok - Herdr shell refusal: %s' % error)
    failed = True
sys.exit(1 if failed else 0)
