from pathlib import Path
import os,json,subprocess
r=Path.cwd(); v=r/'.validation'; h=v/'local'; s=h/'state'; p=s/'procevent'; p.mkdir(exist_ok=True)
(v/'remote/state/parent-replies.status').write_text('done [at=1000]: delivered\n'); (s/'.remote-reply-mirrored-lab').write_text('done [at=1000]: mirrored\n'); (s/'.main-backstop.json').unlink()
(p/'remote-reply-lab.source').write_text('registered disposable source\n'); (p/'remote-reply-lab.runner').write_text('99999999\n')
env=dict(os.environ,FM_HOME=str(h),FM_SSH_BIN=str(v/'ssh/ssh'),HERDR_SESSION='fm-lab-gate-backstop',XDG_CONFIG_HOME=str(v/'herdr/config'),XDG_DATA_HOME=str(v/'herdr/data'),XDG_STATE_HOME=str(v/'herdr/state'),XDG_CACHE_HOME=str(v/'herdr/cache'))
for k in ('FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_ROOT_OVERRIDE'):env.pop(k,None)
for i in (1,2):
 out=subprocess.check_output(['python3','bin/fm-main-backstop.py','--home',str(h),'--code-root',str(r),'--mate','lab'],env=env,text=True,timeout=120)
 print('Pass '+str(i)+': '+out.strip(),flush=True); m=json.loads((s/'.main-backstop.json').read_text()); assert ('runner-lab' in m['episodes'])==(i==2)
print('PASS: a missing registered runner is tolerated once, then emits a durable RUNNER DOWN incident while away.',flush=True)
