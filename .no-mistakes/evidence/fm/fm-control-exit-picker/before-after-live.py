import sys,importlib,subprocess,json,time
sys.path.insert(0,'~/.no-mistakes/evidence/01M6B62AEYX0JQH5T01JDP149M');d=importlib.import_module('drive-picker')
pid=d.restart();(d.LAB/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n- [x] test - Finished (repo: lab) (kind: ship)\n')
d.send('/exit');d.wait(lambda s:'Background work is running' in s,15);d.save('regression-picker-before')
base=d.ROOT/'bin/.fm-control-before-live.sh'
try:
 raw=subprocess.run(['git','show','22e62abe5e435f9d087230b3ac856d2cc5e4d005:bin/fm-control.sh'],capture_output=True,check=True).stdout;base.write_bytes(raw)
 env=d.ENV.copy();env['TMUX']=d.tm('display-message','-p','#{socket_path},#{pid},0').strip();env.update(FM_CONTROL_EXIT_WAIT='3',FM_CONTROL_POLL='0.2')
 p=subprocess.run(['bash',str(base),'test','exit'],env=env,capture_output=True,text=True,timeout=90)
 (d.EV/'base-real-picker-refusal.log').write_text('base=22e62abe5e435f9d087230b3ac856d2cc5e4d005\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
 assert p.returncode==1 and 'Claude background-task exit picker' in p.stderr,p.stdout+p.stderr
 assert not d.dead(pid),'base somehow stopped the shell'
 assert 'Background work is running' in d.save('regression-base-left-picker')
 # Even Done must not let an unattended release answer an already-open picker.
 p=subprocess.run(['bin/fm-busy-event.sh','arm',str(d.LAB/'state'),'test','--state','idle','--source','claude-hook','--event','stop'],env=env,capture_output=True,text=True,check=True)
 p=d.control('unattended-presubmit-refusal','--if-idle','--expect-spawn-gen','s1000.1.1',extra={'FM_CONTROL_LANE_RELEASE':'1'})
 # Meta's existing generation differs, so only exercise the picker guard with its actual generation.
 gen=[s.split('=',1)[1] for s in (d.LAB/'state/test.meta').read_text().splitlines() if s.startswith('spawn_gen=')][-1]
 p=d.control('unattended-open-refusal','--if-idle','--expect-spawn-gen',gen,extra={'FM_CONTROL_LANE_RELEASE':'1'})
 assert p.returncode==1 and 'Claude background-task exit picker' in p.stderr,p.stdout+p.stderr
 assert not d.dead(pid)
 p=d.control('target-real-picker-success',extra={'FM_CONTROL_EXIT_WAIT':'10','FM_CONTROL_POLL':'0.2'});assert p.returncode==0 and d.dead(pid),p.stdout+p.stderr
 d.save('regression-target-after')
 results=json.loads((d.EV/'live-results.json').read_text());results['before-after']={'base_refused_done_picker':True,'target_stopped_same_session':True,'unattended_already_open_refused':True};(d.EV/'live-results.json').write_text(json.dumps(results,indent=2))
 print('Same real picker: base refused, target stopped; unattended pre-submit guard held.',flush=True)
finally:base.unlink(missing_ok=True)
