import json, os, signal, subprocess as sp, time
from pathlib import Path
root=Path.cwd(); home=root/'.round4-clock-lab'; home.mkdir(mode=0o700)
helper=root/'bin/fm-nm-config-staleness-check.sh'
env=dict(os.environ)
for k in ('FM_TEST_SEAM','FM_NM_PROC_ROOT'): env.pop(k,None)
proc=sp.Popen(['no-mistakes','daemon','run','--root',str(home)],stdout=sp.DEVNULL,stderr=sp.DEVNULL,start_new_session=True,env=env)
try:
 for _ in range(200):
  if (home/'daemon.pid').exists() and (home/'config.yaml').exists(): break
  if proc.poll() is not None: raise RuntimeError('disposable daemon failed')
  time.sleep(.05)
 raw=(home/'daemon.pid').read_bytes(); record=json.loads(raw); pid=record['pid']
 ticks=int(Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()[19])
 def boot(): return int(next(l.split()[1] for l in Path('/proc/stat').read_text().splitlines() if l.startswith('btime ')))
 initial_boot=boot(); derived=initial_boot*10**9+ticks*10**9//os.sysconf('SC_CLK_TCK')
 mtime=derived+100*10**9; os.utime(home/'config.yaml',ns=(mtime,)*2)
 marker=home/'episode'; digests=[]; boots=set()
 for i in range(65):
  b=boot(); boots.add(b)
  r=json.loads(sp.check_output([str(helper),str(home),'pc'],text=True,env=env))
  assert (home/'daemon.pid').read_bytes()==raw and (home/'config.yaml').stat().st_mtime_ns==mtime
  assert int(Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()[19])==ticks
  assert r['status']=='stale' and r['pid']==pid and r['process_start_ticks']==ticks,r
  observations=json.dumps(r)+'\n'+''.join(json.dumps(dict(schema='fm-nm-config-age/1',machine=m,status='unavailable'))+'\n' for m in ('server','zenbook'))
  out=sp.check_output([str(helper),'--episode',str(marker)],input=observations,text=True,env=env)
  warning='server-idle-watch: no-mistakes config newer than running daemon on: pc'
  assert (warning in out)==(i==0),out
  digests.append(marker.read_bytes()); assert all(d==digests[0] for d in digests)
  print('sample',i,'wall',time.time(),'btime',b,'pid',pid,'ticks',ticks,'fixed_record_config',True,'status',r['status'],'unchanged_episode',i>0,flush=True)
  if i<64: time.sleep(1)
 fresh=home/'fresh'; out=sp.check_output([str(helper),'--episode',str(fresh)],input=observations,text=True,env=env)
 assert warning in out
 print('FRESH EPISODE AFTER CLOCK OBSERVATIONS\n'+out,flush=True)
 print('PASS unchanged real daemon remains stale and deduplicated; observed btime values',sorted(boots),flush=True)
 if len(boots)==1: print('LIMITATION natural clock movement not observed; deterministic forward/backward regression supplies clock-step proof',flush=True)
finally:
 if proc.poll() is None: os.killpg(proc.pid,signal.SIGTERM)
 try: proc.wait(timeout=5)
 except sp.TimeoutExpired: os.killpg(proc.pid,signal.SIGKILL); proc.wait()
