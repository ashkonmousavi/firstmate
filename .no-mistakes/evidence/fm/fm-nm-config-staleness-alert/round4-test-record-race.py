import datetime as dt, json, os, signal, subprocess as sp, threading, time
from pathlib import Path
root=Path.cwd(); h=root/'.staleness-lab/round4-race'; h.mkdir(); helper=root/'bin/fm-nm-config-staleness-check.sh'
env=dict(os.environ)
env.pop('FM_TEST_SEAM',None); env.pop('FM_NM_PROC_ROOT',None)
p=sp.Popen(['no-mistakes','daemon','run','--root',str(h)],env=env,stdout=sp.DEVNULL,stderr=sp.DEVNULL,start_new_session=True)
try:
 for _ in range(200):
  if (h/'socket').exists(): break
  time.sleep(.03)
 good=(h/'daemon.pid').read_bytes(); r=json.loads(good); ticks=Path(f'/proc/{r["pid"]}/stat').read_text().rsplit(') ',1)[1].split()[19]
 start=dt.datetime.fromisoformat(r['started_at'].replace('Z','+00:00')); later=dict(r,started_at=(start+dt.timedelta(seconds=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))
 os.utime(h/'config.yaml',ns=((int(start.timestamp())+5)*10**9,)*2)
 stop=threading.Event()
 def mutate():
  path=h/'daemon.pid'; tmp=h/'record.tmp'
  while not stop.is_set():
   for b in (good,json.dumps(later).encode()): tmp.write_bytes(b); os.replace(tmp,path)
 t=threading.Thread(target=mutate); t.start()
 try:
  samples=[]
  for _ in range(30):
   out=sp.check_output([str(helper),str(h),'pc'],env=env,text=True); print(out.strip(),flush=True); samples.append(json.loads(out)['status'])
 finally: stop.set(); t.join(); (h/'daemon.pid').write_bytes(good)
 assert 'unavailable' in samples and Path(f'/proc/{r["pid"]}/stat').read_text().rsplit(') ',1)[1].split()[19]==ticks
 print('PASS changing valid PID records become unavailable with fixed real process identity',flush=True)
finally:
 os.killpg(p.pid,signal.SIGTERM); p.wait(timeout=4)
