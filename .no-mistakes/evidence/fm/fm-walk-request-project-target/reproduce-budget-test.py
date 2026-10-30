#!/usr/bin/env python3
"""Execute the existing slow-delivery behavior test against base and current checker."""
import os, subprocess
from pathlib import Path
root=Path.cwd()
base=root/'bin/.fm-walk-request-check-base-validation.sh'
focused=root/'tests/.walk-route-fair-validation.sh'
assert not base.exists() and not focused.exists(), 'previous disposable validation files exist'
env=dict(os.environ);env.pop('TMPDIR',None)
try:
    base.write_bytes(subprocess.check_output(['git','show','2bafe15f26658147adf097c4f0dbef263761c814:bin/fm-walk-request-check.sh']))
    base.chmod(0o700)
    suite=(root/'tests/fm-walk-request.test.sh').read_text()
    definitions=suite[:suite.index('\ntest_interrupted_launch_does_not_consume_recovery\n')]
    focused.write_text(definitions+'\nCHECK=${FM_VALIDATION_CHECK:-$CHECK}\ntest_slow_deliveries_are_bounded_and_fair\n')
    for label,checker in [('base',base),('target',root/'bin/fm-walk-request-check.sh')]:
        print(label,flush=True)
        p=subprocess.run(['bash',str(focused)],env=dict(env,FM_VALIDATION_CHECK=str(checker)))
        print(label+' exit='+str(p.returncode),flush=True)
finally:
    base.unlink(missing_ok=True);focused.unlink(missing_ok=True)
