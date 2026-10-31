#!/usr/bin/env python3
"""Execute the pre-change and target helper against fresh disposable homes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path.cwd()
evidence = Path(__file__).resolve().parent
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE', 'TMUX')}
transcript = []
old_path = None
try:
    old = subprocess.run(['git', 'show', 'baae6e980da1cc4a9ab7d49dcf9d4837f6c92cd2:bin/fm-captain-hold.sh'], cwd=root, capture_output=True, check=True).stdout
    # Keeping the historical entrypoint beside its actual sibling libraries
    # preserves its normal SCRIPT_DIR addressing; remove it in finally.
    fd, filename = tempfile.mkstemp(prefix='.fm-hold-before-', suffix='.sh', dir=root / 'bin')
    old_path = Path(filename)
    with os.fdopen(fd, 'wb') as handle:
        handle.write(old)
    old_path.chmod(0o700)
    for label, executable in [('before', old_path), ('after', root / 'bin/fm-captain-hold.sh')]:
        with tempfile.TemporaryDirectory(prefix='.fm-lab-regression-', dir=root) as temp:
            home = Path(temp)
            subprocess.run([str(root / 'bin/fm-lab-home.sh'), 'create', str(home)], cwd=root, env=env, check=True, capture_output=True)
            (home / 'tmp').mkdir()
            (home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 100\n')
            backlog = home / 'data/backlog.md'
            backlog.write_text('## In flight\n\n## Queued\n\n## Done\n')
            original = backlog.read_bytes()
            command = [str(executable), 'hold', 'freeze-wait', '--title', 'Freeze wait', '--reason', 'wait until freeze ends']
            callenv = dict(env, FM_HOME=str(home), TMPDIR=str(home / 'tmp'))
            p = subprocess.run(command, cwd=root, env=callenv, capture_output=True, text=True, timeout=45)
            transcript.append({'version': label, 'command': command, 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr, 'backlog_after': backlog.read_text()})
            if label == 'before':
                assert p.returncode == 0, transcript[-1]
                shown = subprocess.run([str(root / 'bin/fm-tasks-axi.sh'), 'show', 'freeze-wait', '--full'], cwd=root, env=callenv, capture_output=True, text=True, check=True, timeout=30)
                transcript.append({'version': label, 'show': shown.stdout})
                assert 'hold_kind: captain' in shown.stdout, shown.stdout
            else:
                assert p.returncode != 0, transcript[-1]
                assert "a wait that is firstmate's own is not a captain call" in p.stderr, transcript[-1]
                assert backlog.read_bytes() == original, transcript[-1]
finally:
    if old_path is not None:
        old_path.unlink(missing_ok=True)
    (evidence / 'before-after.json').write_text(json.dumps(transcript, indent=2) + '\n')
print('Historical helper created an unsourced captain hold; target refused the same request without backlog mutation. Both disposable homes and the historical entrypoint were removed.')
