import sys,time,json,subprocess,os,signal
sys.path.insert(0,'~/.no-mistakes/evidence/01M6B62AEYX0JQH5T01JDP149M');from importlib import import_module
d=import_module('drive-picker');lab=d.LAB;ev=d.EV
pid=d.restart()
(lab/'state/test.released').unlink(missing_ok=True)
(lab/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n- [x] test - Finished (repo: lab) (kind: ship)\n')
d.send('/exit');d.wait(lambda s:'Background work is running' in s,15);d.save('unresponsive-picker-before')
# Freeze exactly the Claude child of this owned pane, never a fleet process.
parent=int(d.tm('display-message','-p','-t','primary','#{pane_pid}').strip())
rows=subprocess.run(['ps','--ppid',str(parent),'-o','pid=,comm='],capture_output=True,text=True,check=True).stdout.splitlines()
claude=[int(r.split()[0]) for r in rows if r.split()[1]=='claude']
assert len(claude)==1,rows
cpid=claude[0]
try:
 os.kill(cpid,signal.SIGSTOP)
 p=d.control('unresponsive-confirmation',extra={'FM_CONTROL_EXIT_WAIT':'2','FM_CONTROL_POLL':'0.2'})
 assert p.returncode==1,p.stdout+p.stderr
 assert 'did not stop within 2s' in p.stderr,p.stderr
 assert 'stopped test' not in p.stdout,p.stdout
 assert not d.dead(pid),'background task unexpectedly stopped'
 d.save('unresponsive-picker-after')
finally:
 os.kill(cpid,signal.SIGCONT)
time.sleep(2)
assert d.dead(pid),'queued exit did not stop background shell after resume'
r=json.loads((ev/'live-results.json').read_text());r['unresponsive-confirmation']={'result':'pass','injected_fault':'SIGSTOP owned Claude pid '+str(cpid),'observed':'exit=1; agent did not stop; no stopped claim','resumed_and_cleaned':True};(ev/'live-results.json').write_text(json.dumps(r,indent=2))
