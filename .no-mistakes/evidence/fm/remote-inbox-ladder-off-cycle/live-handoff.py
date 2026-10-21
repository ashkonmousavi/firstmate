import os,pathlib,tempfile,subprocess,signal,shutil,time
root=pathlib.Path.cwd(); ev=pathlib.Path('~/.no-mistakes/evidence/01M5EDB3MBWCZX063DZJ8QGKGJ'); lab=pathlib.Path(tempfile.mkdtemp(prefix='.handoff-live-',dir=root)); ps=[]
try:
 for d in ['data','state','config']: (lab/d).mkdir()
 (lab/'state/home-summary.json').write_text('{}')
 reason='stale: remote:rsm (remote record 001.msg still unhandled after 1 doorbell delivery attempts)'
 (lab/'state/.remote-inbox-wake').write_text(reason+'\n')
 env=os.environ.copy()
 for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']: env.pop(k,None)
 env.update(FM_HOME=str(lab),FM_POLL='1',FM_HOME_SUMMARY_INTERVAL='99999999',FM_HEARTBEAT='99999999')
 first=subprocess.Popen(['bash','bin/fm-watch.sh'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True); ps.append(first)
 out,_=first.communicate(timeout=35)
 print('Restart over durable handoff:',out.strip())
 assert reason in out and first.returncode==0
 assert not (lab/'state/.remote-inbox-wake').exists()
 second=subprocess.Popen(['bash','bin/fm-watch.sh'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True); ps.append(second)
 time.sleep(9)
 if second.poll() is None: os.killpg(second.pid,signal.SIGTERM)
 out,_=second.communicate(timeout=5)
 print('Next watcher output:',out.strip())
 assert reason not in out,'next watcher repeated consumed handoff'
 assert not (lab/'state/.remote-inbox-wake').exists()
 print('PASS: saved handoff consumed by real watcher and not repeated on next arm. Normal downtime recovery may separately resurface. Producer was not exercised by this scenario.')

finally:
 for p in ps:
  try: os.killpg(p.pid,signal.SIGKILL)
  except ProcessLookupError: pass
 shutil.rmtree(lab)
