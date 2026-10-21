from pathlib import Path
import os,subprocess,json,time
root=Path.cwd(); base=root/'.validation'; local=base/'local'; remote=base/'remote'; state=local/'state'
env=dict(os.environ,FM_HOME=str(local),FM_SSH_BIN=str(base/'ssh/ssh'),HERDR_SESSION='fm-lab-gate-backstop',XDG_CONFIG_HOME=str(base/'herdr/config'),XDG_DATA_HOME=str(base/'herdr/data'),XDG_STATE_HOME=str(base/'herdr/state'),XDG_CACHE_HOME=str(base/'herdr/cache'))
for k in ('FM_ROOT_OVERRIDE','FM_DATA_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE'): env.pop(k,None)
(state/'.afk').touch()
mirror=state/'.remote-reply-mirrored-lab'; log=remote/'state/parent-replies.status'; journal=state/'.main-backstop.json'
def memory(): return json.loads(journal.read_text()) if journal.exists() else {}
def drive(label):
 p=subprocess.run(['python3','bin/fm-main-backstop.py','--home',str(local),'--code-root',str(root),'--mate','lab'],env=env,text=True,capture_output=True,timeout=120)
 assert p.returncode==0,(p.stdout,p.stderr)
 m=memory(); print(label+': '+p.stdout.strip().replace('\n',' | '),flush=True)
 print('  episodes='+json.dumps(m.get('episodes',{}))+' pending='+json.dumps(m.get('readers',{}).get('lab',{}).get('pending_at'))+' read_fails='+json.dumps(list(m.get('read_fails',{}))),flush=True)
 return m
mirror.write_text('done [at=1000]: reproduced case at=9000;\n')
log.write_text('done [at=1060]: oldest pending; body [at=999999999999]\n')
m=drive('whole-file: report-body tokens must not hide 1060'); assert m['readers']['lab']['pending_at']==[1060] and m['lag_oldest']['lab']==1060
incident=m['episodes']['lag-lab']
with log.open('a') as f:f.write('done [at=1200]: delta reply at=999999999999;\n')
m=drive('delta append: both replies remain outstanding'); assert m['readers']['lab']['pending_at']==[1060,1200] and m['episodes']['lag-lab']==incident
mirror.write_text('done [at=1000]: misleading [at=999999999999]\n')
log.write_text('done [at=1300]: replacement log body at=999999999999;\n')
m=drive('replacement: preserve outstanding oldest and incident'); assert m['readers']['lab']['pending_at']==[1060,1200,1300] and m['episodes']['lag-lab']==incident
mirror.write_text('done [at=1300]: all delivered\n')
m=drive('mirror catches up: clear lag incident'); assert 'lag-lab' not in m['episodes'] and not m['readers']['lab']['pending_at']
log.write_text('done [at=%d]: first fresh reply after silence\n'%int(time.time()))
m=drive('fresh reply: no immediate lag alarm'); assert 'lag-lab' not in m['episodes']
for label,line in [('body-only','done: at=1060;'),('duplicate','done [at=1060] [at=9000]: duplicate'),('leading-zero','done [at=01060]: bad'),('over-bound','done [at=1000000000000]: bad')]:
 journal.unlink(missing_ok=True); log.write_text(line+'\n'); mirror.write_text('done [at=1000]: mirror\n')
 drive(label+' first read: unknown time'); m=drive(label+' repeated read: durable unverified alarm'); assert 'read-lab' in m['episodes'] and 'lab' not in m.get('readers',{})
journal.unlink(); log.write_text(('done [at=1000]: '+ 'x'*60000+'\n')*18+'done [at=1060]: oversized tail at=999999999999;\n'); mirror.write_text('done [at=1000]: at=9000;\n')
for i in range(7):
 m=drive('oversized bounded scan pass '+str(i+1))
 if 'lab' not in m.get('read_fails',{}):break
assert m['readers']['lab']['pending_at']==[1060] and m['lag_oldest']['lab']==1060 and 'read-lab' not in m['episodes']
print('PASS: real loopback SSH, remote worker, file/delta readers, canonical timestamps, durable inbox alarms and incident clearing.',flush=True)
# Real worker-facing status executable, with persisted output and no shell evaluation.
status=local/'state/literal.status'; marker=base/'should-not-exist'; payload=f'`touch {marker}` $(touch {marker}) $HOME quoted\nsecond line'
p=subprocess.run(['bin/fm-status-append.sh',str(status),'done'],input=payload,text=True,capture_output=True,env=env,check=True)
text=status.read_text(); assert not marker.exists() and len(text.splitlines())==1 and '$HOME' in text and '`touch ' in text and 'second line' in text
print('LITERAL STATUS OUTPUT: '+text.strip()); print('PASS: substitutions were stored literally; no marker created and one line persisted.',flush=True)
