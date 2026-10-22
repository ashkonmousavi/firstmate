from pathlib import Path
exec(Path('~/.no-mistakes/evidence/01M5GMD1NHC865MTNQ7BNSH88E/drive-worker.py').read_text().split("run('baseline',single,True)")[0])
l=Lab('slow-passes-do-not-hide-heartbeat-deaths')
try:
    os.killpg(l.p.pid,signal.SIGTERM); l.p.wait(timeout=8)
    shim=l.d/'fault-bin'; shim.mkdir()
    (shim/'sleep').write_text('''#!/bin/bash
heartbeat=$(ps -ax -o pid= -o ppid= -o args= | awk -v owner="$PPID" '$2 == owner && /fm-remote-job-worker[.]sh/ && !/--lane/ {print $1; exit}')
if [ -z "$heartbeat" ]; then exit 1; fi
kill -KILL "$heartbeat" || exit 1
printf '%s\\n' "$heartbeat" >> "$DEATH_LOG"
exec /bin/sleep 6
''')
    (shim/'sleep').chmod(0o755)
    l.env.update(PATH=str(shim)+':'+os.environ['PATH'],DEATH_LOG=str(l.d/'deaths'))
    l.p=sp.Popen([str(l.root/'bin/fm-remote-job-worker.sh'),'--serve'],env=l.env,stdout=l.log,stderr=l.log,start_new_session=True)
    code=l.p.wait(timeout=55)
    deaths=read(l.d/'deaths').splitlines()
    result=dict(name=l.name,worker_exit=code,heartbeat_deaths=len(deaths),serving_pass_delay_seconds=6,worker_log=(E/(l.name+'-worker.log')).read_text())
    print(json.dumps(result),flush=True)
    assert code==1 and len(deaths)==6 and 'readiness heartbeat process stopped' in result['worker_log'],result
    (E/'slow-pass-scenario.json').write_text(json.dumps(result,indent=2)+'\n')
finally:
    l.close()
