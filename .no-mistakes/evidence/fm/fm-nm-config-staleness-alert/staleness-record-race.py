import collections,json,os,signal,subprocess as sp,threading,time
from pathlib import Path
root=Path.cwd(); home=root/'.sl/w'; home.mkdir(); p=sp.Popen(['no-mistakes','daemon','run','--root',str(home)],stdout=sp.DEVNULL,stderr=sp.DEVNULL,start_new_session=True); thread=None; running=False
try:
 for _ in range(200):
  if (home/'socket').exists(): break
  time.sleep(.05)
 path=home/'daemon.pid'; good=path.read_bytes(); a=json.loads(good); b=dict(a,started_at=a['started_at'].replace('Z','.000000001Z')); values=(json.dumps(a).encode(),json.dumps(b).encode())
 def swap():
  i=0
  while running:
   tmp=home/'record-next'; tmp.write_bytes(values[i%2]); os.replace(tmp,path); i+=1
 running=True; thread=threading.Thread(target=swap); thread.start(); observations=[]
 for _ in range(40):
  r=sp.run([str(root/'bin/fm-nm-config-staleness-check.sh'),str(home),'pc'],text=True,capture_output=True,check=True); observations.append(json.loads(r.stdout))
 running=False; thread.join(); path.write_bytes(good)
 counts=collections.Counter(r['status'] for r in observations); assert counts['unavailable']>0
 print('Two valid PID/start records for the same actual daemon were atomically alternated during real procfs sampling.',flush=True)
 print('Observed statuses:',dict(counts),flush=True)
 print('Detected changing record:',next(r for r in observations if r['status']=='unavailable'),flush=True)
 print('PASS changing identity record remains unavailable; no fake procfs or process seam used',flush=True)
finally:
 running=False
 if thread: thread.join()
 if p.poll() is None: os.killpg(p.pid,signal.SIGTERM); p.wait(timeout=5)
