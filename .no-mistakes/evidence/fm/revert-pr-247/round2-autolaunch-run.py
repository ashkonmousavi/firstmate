#!/usr/bin/env python3
"""Run the unmodified scheduler subject; retain state from its flaky case."""
import hashlib, json, os, pathlib, shutil, subprocess, tempfile, time
root=pathlib.Path.cwd()
out=pathlib.Path('~/.no-mistakes/evidence/01M6QG4GJ98YRTXTMHF63ZZK56')
tmp=pathlib.Path(tempfile.mkdtemp(prefix='round2-toolchain-temp-',dir=out))
env=os.environ|{'TMPDIR':str(tmp),'GIT_CEILING_DIRECTORIES':str(tmp)}
argv=['bin/fm-test-run.sh','--jobs','1','--per-script-timeout-secs','2100','--json',str(out/'round2-recheck-timing.json'),'tests/fm-autolaunch.test.sh','tests/fm-backlog-atomicity.test.sh']
with (out/'round2-recheck.log').open('w') as log, (out/'round2-retry-state.jsonl').open('w') as states:
    p=subprocess.Popen(argv,env=env,stdout=log,stderr=subprocess.STDOUT)
    prior=None
    while p.poll() is None:
        for case in tmp.glob('fm-autolaunch.*/k1-busy-receipts'):
            snapshot={}
            for sub in ('home/state','fake'):
                for path in (case/sub).rglob('*'):
                    try:
                        if path.is_symlink() or not path.is_file() or path.stat().st_size>131072: continue
                        snapshot[str(path.relative_to(case))]=path.read_text(errors='replace')
                    except (FileNotFoundError, PermissionError, OSError): pass
            digest=hashlib.sha256(json.dumps(snapshot,sort_keys=True).encode()).hexdigest()
            if snapshot and digest != prior:
                states.write(json.dumps({'wall_time':time.time(),'files':snapshot})+'\n');states.flush();prior=digest
        time.sleep(.1)
    rc=p.wait()
(out/'round2-recheck-exit.json').write_text(json.dumps({'argv':argv,'environment':{'TMPDIR':str(tmp),'GIT_CEILING_DIRECTORIES':str(tmp)},'exit':rc})+'\n')
shutil.rmtree(tmp)
raise SystemExit(rc)
