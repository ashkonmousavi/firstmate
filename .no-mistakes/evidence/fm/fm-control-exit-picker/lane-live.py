import sys,time,json,subprocess,os
sys.path.insert(0,'~/.no-mistakes/evidence/01M6B62AEYX0JQH5T01JDP149M');from importlib import import_module
d=import_module('drive-picker');lab=d.LAB;ev=d.EV
pid=d.restart()
(lab/'data/backlog.md').write_text('## In flight\n- [ ] test - Awaiting acceptance proof (repo: lab) (kind: ship)\n\n## Queued\n\n## Done\n')
before=(lab/'data/backlog.md').read_bytes()
gen=f's{int(time.time())-1000}.1.1'
with (lab/'state/test.meta').open('a') as f:f.write(f'spawn_gen={gen}\npr=https://github.com/lab/disposable/pull/7\n')
(lab/'config/lane-release').write_text('on\n')
env=d.ENV.copy();env['TMUX']=d.tm('display-message','-p','#{socket_path},#{pid},0').strip();env.update(FM_CONTROL_POLL='0.2',FM_CONTROL_EXIT_WAIT='10')
def run(name,args,check=True):
 p=subprocess.run(args,env=env,capture_output=True,text=True,timeout=100)
 (ev/(name+'.log')).write_text('$ '+' '.join(args)+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
 print(name,p.returncode,p.stdout,p.stderr,flush=True)
 if check:assert p.returncode==0,p.stdout+p.stderr
 return p
busy=run('lane-arm-idle',['bin/fm-busy-event.sh','arm',str(lab/'state'),'test','--state','idle','--source','claude-hook','--event','stop']).stdout.strip()
time.sleep(1)
run('lane-record-disposable-landing',['bash','-c','. bin/fm-pr-lib.sh; fm_pr_poll_merge_mark_notified "$FM_HOME/state" test github github.com lab/disposable 7'])
anchor=int((lab/'state/test.pr-poll-merge-notified').stat().st_mtime)
# A disposable record at the documented exit-worker boundary. Real validation,
# busy/composer reads, key delivery, Claude, and stopped-seat proof follow.
(lab/'state/test.released').write_text(f'fm-lane-release-v1\ntask=test\nspawn_gen={gen}\nreleased_at={int(time.time())}\nanchor={anchor}\nclass=merged-ship\nresult=releasing\nbusy_seq={busy}:1\n')
run('lane-validate-real-predicates',['bin/fm-lane-release.sh','validate-exit','test',gen])
d.save('lane-before')
run('lane-exit-worker',['bin/fm-lane-release.sh','exit-worker','test',gen])
log=(lab/'state/test.release.log').read_text();(ev/'lane-exit-result.log').write_text(log);print(log,flush=True)
assert 'rc=0\n' in log and 'stopped test' in log,log
assert d.dead(pid),'background sleep still alive'
assert (lab/'data/backlog.md').read_bytes()==before,'acceptance changed'
d.save('lane-after')
seat=run('lane-seat-proof',['bash','-c','. bin/fm-project-capacity-lib.sh; . bin/fm-backend.sh; . bin/fm-agent-process-lib.sh; rc=0; fm_task_record_holds_seat "$FM_HOME/state/test.meta" "$(cat "$FM_HOME/state/test.meta")" "$FM_HOME/state" || rc=$?; printf "holds_seat=%s known=%s\\n" "$rc" "$FM_TASK_RECORD_SEAT_KNOWN"; [ "$rc" = 1 ] && [ "$FM_TASK_RECORD_SEAT_KNOWN" = 1 ]'])
results=json.loads((ev/'live-results.json').read_text());results['validated-nondone-lane-release']={'result':'pass','background_pid':pid,'backlog_unchanged':True,'seat_free':True};(ev/'live-results.json').write_text(json.dumps(results,indent=2))
