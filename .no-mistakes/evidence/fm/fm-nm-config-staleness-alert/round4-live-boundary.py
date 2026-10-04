import json, os, signal, subprocess as sp, time
from pathlib import Path
root=Path.cwd(); h=root/'.b4'; h.mkdir(); helper=root/'bin/fm-nm-config-staleness-check.sh'
env=dict(os.environ); env.pop('FM_TEST_SEAM',None); env.pop('FM_NM_PROC_ROOT',None)
p=sp.Popen(['no-mistakes','daemon','run','--root',str(h)],env=env,stdout=sp.DEVNULL,stderr=sp.DEVNULL,start_new_session=True)
def boot(): return int(next(l.split()[1] for l in Path('/proc/stat').read_text().splitlines() if l.startswith('btime ')))
try:
 for _ in range(200):
  if (h/'socket').exists(): break
  if p.poll() is not None: raise RuntimeError('disposable daemon failed')
  time.sleep(.03)
 raw=(h/'daemon.pid').read_bytes(); pid=json.loads(raw)['pid']; ticks=int(Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()[19])
 for delta,expected in ((-1,'current'),(0,'current'),(1,'current'),(10**10-1,'current'),(10**10,'current'),(10**10+1,'stale')):
  for attempt in range(20):
   b=boot(); birth=b*10**9+ticks*10**9//os.sysconf('SC_CLK_TCK'); os.utime(h/'config.yaml',ns=(birth+delta,)*2)
   r=json.loads(sp.check_output([str(helper),str(h),'pc'],env=env,text=True))
   if boot()==b: break
  else: raise RuntimeError('btime never stable across a single observation')
  assert r['status']==expected,r
  assert r['pid']==pid and r['process_start_ticks']==ticks and (h/'daemon.pid').read_bytes()==raw
  print('LIVE BOUNDARY delta_ns=',delta,' btime=',b,' observation=',json.dumps(r),flush=True)
 print('PASS actual daemon older/equal/within tolerance/exact 10 seconds/+1ns boundaries',flush=True)
finally:
 if p.poll() is None: os.killpg(p.pid,signal.SIGTERM)
 p.wait(timeout=5)
