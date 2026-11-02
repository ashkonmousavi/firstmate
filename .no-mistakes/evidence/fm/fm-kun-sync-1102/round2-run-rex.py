import os,subprocess,json
from pathlib import Path
root=Path.cwd(); evidence=Path('~/.no-mistakes/evidence/01M6EPD9Q923ZVBVRY6T3MMGP9')
fd=os.open(root/'.no-mistakes/retest',os.O_RDONLY)
env=os.environ.copy(); env.update(TMPDIR=str(root/'.no-mistakes/retest/tmp'), REX_BIN_DIR=str(root/'.no-mistakes/retest/rex'),TREEHOUSE_ROOT=str(root/'.no-mistakes/retest/treehouse-rex'))
results={}
for i,(script,name) in enumerate([
 ('.no-mistakes/retest/runtime/tests/fm-backend-rex-smoke.test.sh','smoke'),
 ('.no-mistakes/retest/replay-rex-recorded-server.sh','recorded-server'),
 ('.no-mistakes/retest/replay-rex-restart.sh','restart'),
 ('.no-mistakes/retest/replay-rex-codex-carrier.sh','codex-carrier')]):
 env['FM_TEST_REX_SOCKET']=f'unix:///proc/{os.getpid()}/fd/{fd}/rex-{i}.sock'
 with (evidence/f'round2-rex-{name}-live.log').open('w') as out:
  p=subprocess.run(['bash',script],env=env,stdout=out,stderr=subprocess.STDOUT)
 results[name]=p.returncode
 print(name,p.returncode,flush=True)
 (evidence/'round2-rex-exits.json').write_text(json.dumps(results,indent=2))
os.close(fd)
raise SystemExit(0 if all(v==0 for v in results.values()) else 1)
