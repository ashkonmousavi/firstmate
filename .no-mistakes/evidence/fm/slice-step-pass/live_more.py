exec(open('.test-tmp/live_driver.py').read().split('results=[]')[0])
log.close();log=(E/'live-additional.log').open('w',buffering=1);results=[]
# Prove a real remote carrier accepts the pass's walk request without a private dispatcher.
M=R/'.test-tmp/carrier-lab';P=R/'.test-tmp/parent-lab'
cmd('bash',R/'bin/fm-lab-home.sh','create',M);cmd('bash',R/'bin/fm-lab-home.sh','create',P)
H=M;env['FM_HOME']=str(M);env.pop('TMUX',None)
w('.fm-secondmate-home','labmate\n');w('.fm-secondmate-parent',f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={P}\n')
(P/'state/labmate.meta').write_text(f'kind=secondmate\nhome={M}\n')
w('.tasks.toml','backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n')
w('data/backlog.md','## In flight\n- [ ] owner - Disposable walk (repo: proj) (kind: ship)\n  SLICE: labmate/demo | lab | role=owner\n  TESTER TASK: special-tester\n## Queued\n## Done\n')
w('config/autolaunch-steps','act owner\n');w('data/owner/prep.md','REVISION: r1\nCUT: 1\nWALK ID: demo\nWALK LIST: screen-a,screen-b\nWALK BRIEF: data/walk-briefs/demo.md\nWALK BOT: Walker\nWALK PROJECT: proj\nWALK TARGET: lab\n')
w('data/walk-briefs/demo.md','Disposable test of screen-a and screen-b.\n')
sha='0123456789abcdef0123456789abcdef01234567';now=int(time.time())
w('data/owner/slice-steps.log',json.dumps(dict(at=now-30,generation=1,owner='owner',step='deployed',trigger='deploy:lab1',receipt='completed',release=sha,deployed_at=now-30))+'\n')
w('data/x-board-summary.json',json.dumps(dict(written_at=now,interval_seconds=600,checkpoints=[dict(id='lab-daily',at=now-10,kind='daily')])))
step();rr=rows();r=rr[-1];log.write('REQUEST RECEIPT\n'+json.dumps(r,indent=2)+'\n');assert r['receipt']=='pending' and r['reason']=='walk-expect'
request=(P/'state/labmate.status').read_text();log.write('PARENT CHANNEL\n'+request+'\n');assert 'walk-request:' in request and 'attempt=' in request
step();assert (P/'state/labmate.status').read_text()==request
record('Checkpoint files one real remote walk request and waits for sent evidence','two passes produce one typed parent-channel request with fixed correlation and attempt=1; receipt remains pending walk-expect')
# An unavailable lane preserves the owner continuation for another pass.
H=R/'.test-tmp/capacity-lab';cmd('bash',R/'bin/fm-lab-home.sh','create',H);env['FM_HOME']=str(H)
w('.tasks.toml','backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n')
w('data/backlog.md','## In flight\n- [ ] owner - Lab owner (repo: proj) (kind: ship)\n  SLICE: main/demo | lab | role=owner\n## Queued\n## Done\n')
w('config/autolaunch-steps','act owner\n');w('config/lane-capacity','0 0\n')
w('config/machine-admission.json',json.dumps(dict(schema='fm-machine-admission.v1',memory_floor_gib=0,disk_floor_gib=0,memory_full_avg60_max=100,disk_paths=[str(H)])))
w('state/owner.meta',f'kind=ship\nharness=codex\nbackend=tmux\nmodel=gpt-6.1-sol\nspawn_gen=lab.1\nwindow=primary:fm-owner\nproject={H}/projects/proj\nworktree={H}/projects/proj\nbranch=fm/owner\nmode=direct-PR\n')
w('data/owner/prep.md','REVISION: r2\nCUT: 1\nWALK ID: demo\nWALK LIST: screen-a\n')
w('data/owner/slice-steps.log',json.dumps(dict(at=1,generation=1,owner='owner',step='build',trigger='tests-ready:none@r1',receipt='completed',revision='r1'))+'\n')
w('state/owner.status','working [at=3]: cut ready data/owner/prep.md r2 walk_changed=no risk_changed=no\n')
step();rr=rows();assert rr[-1]['receipt']=='pending' and rr[-1]['reason']=='relaunch-due';step();assert rows()==rr
log.write('CAPACITY WAIT\n'+json.dumps(rr[-1],indent=2)+'\n');record('An exited owner with no lane retains one retryable continuation','real machine admission with zero lanes leaves one pending relaunch-due receipt over repeated passes')
(E/'live-more-results.json').write_text(json.dumps(results,indent=2)+'\n');log.write('ALL ADDITIONAL LIVE CHECKS COMPLETED\n')
