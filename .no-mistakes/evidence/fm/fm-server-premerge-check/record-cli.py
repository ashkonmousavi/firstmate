#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(os.environ['FM_LIVE_WORKTREE'])
start=time.time()
r=subprocess.run(['bash',str(root/'bin/fm-q-premerge-plan-check.sh'),*sys.argv[1:]],capture_output=True)
entry={'clone':pathlib.Path(sys.argv[1]).name if len(sys.argv)>1 else '', 'pr':sys.argv[2:] ,'exit':r.returncode,'stdout':r.stdout.decode(errors='replace'),'stderr':r.stderr.decode(errors='replace'),'duration_seconds':round(time.time()-start,3),'transport_fixture':bool(os.environ.get('FM_FIXTURE_CALLBACK_MODE'))}
with open(os.environ['FM_LIVE_TRANSCRIPT'], 'a') as f:
    f.write(json.dumps(entry)+'\n')
sys.stdout.buffer.write(r.stdout)
sys.stderr.buffer.write(r.stderr)
sys.exit(r.returncode)
