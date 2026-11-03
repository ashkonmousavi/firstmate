import concurrent.futures, json, os, pathlib, subprocess, time
root=pathlib.Path.cwd(); home=root/'.validation/home'; inbox=home/'state/history.inbox'
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'HERDR_')) or k=='TMUX': env.pop(k,None)
env.update(FM_HOME=str(home),FM_GUARD_READ_ONLY='1',TMUX=subprocess.check_output(['tmux','-S','.validation/tmux.sock','display-message','-p','#{socket_path},#{pid},0'],text=True).strip())
def send(i):
    start=time.monotonic(); p=subprocess.run(['bin/fm-send.sh','history','--one-way',f'concurrent steer {i}'],env=env,text=True,capture_output=True,timeout=30)
    return dict(writer=i,exit=p.returncode,wall_seconds=time.monotonic()-start,stderr=p.stderr)
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool: results=list(pool.map(send,range(8)))
assert all(row['exit']==0 for row in results),results
records=sorted(inbox.glob('20[56][0-9].msg'))
assert [p.name for p in records]==[f'{n}.msg' for n in range(2059,2067)],[p.name for p in records]
bodies=[]
for rec in records:
    p=subprocess.run(['bash','-c','. "$1"; fm_task_inbox_body "$2"','_',str(root/'bin/fm-task-inbox-lib.sh'),str(rec)],env=env,capture_output=True,text=True,check=True)
    bodies.append(p.stdout)
assert set(bodies)=={f'concurrent steer {i}' for i in range(8)},bodies
print(json.dumps(dict(results=results,records=[p.name for p in records],bodies=bodies,no_clobber=True),indent=2))
