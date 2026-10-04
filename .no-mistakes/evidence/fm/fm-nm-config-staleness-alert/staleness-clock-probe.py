import datetime as dt,json,os,signal,subprocess as sp,time
from pathlib import Path
root=Path.cwd(); home=root/'.sl/r'; home.mkdir(exist_ok=True); proc=sp.Popen(['no-mistakes','daemon','run','--root',str(home)],stdout=sp.DEVNULL,stderr=sp.DEVNULL,start_new_session=True)
try:
 for _ in range(200):
  if (home/'socket').exists(): break
  time.sleep(.05)
 record=json.loads((home/'daemon.pid').read_text()); start=int(dt.datetime.fromisoformat(record['started_at'].replace('Z','+00:00')).timestamp())*10**9
 os.utime(home/'config.yaml',ns=(start+1,)*2)
 original_record=(home/'daemon.pid').read_bytes(); original_mtime=(home/'config.yaml').stat().st_mtime_ns; original_ticks=None; first_unknown=False
 for i in range(65):
  out=sp.run([str(root/'bin/fm-nm-config-staleness-check.sh'),str(home),'pc'],capture_output=True,text=True,check=True)
  fields=Path(f'/proc/{record["pid"]}/stat').read_text().rsplit(') ',1)[1].split(); boot=int(next(line.split()[1] for line in Path('/proc/stat').read_text().splitlines() if line.startswith('btime '))); birth=boot*10**9+int(fields[19])*10**9//os.sysconf('SC_CLK_TCK')
  if original_ticks is None: original_ticks=fields[19]
  assert (home/'daemon.pid').read_bytes()==original_record and (home/'config.yaml').stat().st_mtime_ns==original_mtime and fields[19]==original_ticks
  status=json.loads(out.stdout)['status']
  if i==0 or (status=='unavailable' and not first_unknown):
   marker=home/f'fresh-episode-{i}'; marker.unlink(missing_ok=True)
   observations=out.stdout+''.join(json.dumps(dict(schema='fm-nm-config-age/1',machine=m,status='unavailable'))+'\n' for m in ('server','zenbook'))
   episode=sp.run([str(root/'bin/fm-nm-config-staleness-check.sh'),'--episode',str(marker)],input=observations,capture_output=True,text=True,check=True)
   print('FRESH EPISODE',i,'\n'+episode.stdout,flush=True)
   if status=='unavailable': first_unknown=True
  print('sample',i,'wall',time.time(),'monotonic',time.monotonic(),'btime',boot,'record_start',record['started_at'],'birth_ns',birth,'delta_ns',start-birth,'comm',Path(f'/proc/{record["pid"]}/comm').read_text().strip(),'status',json.loads(out.stdout)['status'],flush=True)
  if first_unknown:
   print('FAIL unchanged live daemon lost stale classification after clock/btime movement; PID record, kernel start ticks and config mtime all stayed fixed',flush=True)
   break
  time.sleep(1)
finally:
 os.killpg(proc.pid,signal.SIGTERM); proc.wait(timeout=5)
