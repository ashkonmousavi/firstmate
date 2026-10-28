from pathlib import Path
P=Path('~/.no-mistakes/evidence/01M623WEVE8Z0BJ53B6V14ECWW')
E=P/'round2'
old=(P/'live-conflict.py').read_text()
prefix=old.split("\ntry:\n    note('Production")[0]
prefix=prefix.replace("E=pathlib.Path('~/.no-mistakes/evidence/01M623WEVE8Z0BJ53B6V14ECWW')", "E=pathlib.Path('~/.no-mistakes/evidence/01M623WEVE8Z0BJ53B6V14ECWW/round2')")
prefix=prefix.replace("LAB=pathlib.Path((E/'lab-path.txt').read_text().strip())", "LAB=E.parent/'r2'")
prefix=prefix.replace("log=(E/'live-conflict.log').open('w')", "log=(E/'live.log').open('w')")
body=old.split("\ntry:\n",1)[1].split('\nexcept Exception:',1)[0]
body=body.replace("    meta(); forge(); arm()", """    tmux('rename-window','-t','primary:','fm-lane')
    tmux('set-window-option','-t','primary:fm-lane','automatic-rename','off')
    deadline=time.monotonic()+20
    while 'OpenAI Codex' not in tmux('capture-pane','-p','-t','primary:fm-lane').stdout:
        assert time.monotonic()<deadline, 'Real Codex did not render'
        time.sleep(.1)
    tmux('send-keys','-t','primary:fm-lane','-l','Isolated validation: leave this draft unsubmitted.')
    time.sleep(.3)
    meta(); forge(); arm()""")
body=body.replace("    note('Final durable conflict wakes:", "    note('Initial durable conflict wakes:")
extra=r'''
    # Restore a live endpoint, then acknowledge real deliveries concurrently.
    for f in [S/'lane.status',S/'lane.pr-conflict-episode']:
        f.unlink(missing_ok=True)
    meta()
    handled=S/'lane.inbox'/'handled'; handled.mkdir(exist_ok=True)
    for f in messages(): f.rename(handled/f.name)
    def immediate_ack():
        import threading
        stop=threading.Event(); acks=[]
        def acknowledge():
            while not stop.is_set():
                for f in messages():
                    try: f.rename(handled/f.name); acks.append(f.name)
                    except FileNotFoundError: pass
                time.sleep(.001)
        thread=threading.Thread(target=acknowledge); thread.start()
        try:
            old=len(wakes())
            for i,date in enumerate(['2026-08-08T00:00:00Z','2026-09-09T00:00:00Z','2026-10-10T00:00:00Z']):
                forge(date); cycle('ack-'+str(i))
                assert not messages() and len(wakes())==old
                assert (S/'lane.pr-conflict-episode').read_text().splitlines()[-1]=='action'
            assert len(acks)==3
        finally:
            stop.set(); thread.join(timeout=5); assert not thread.is_alive()
        note('Real delivery acknowledgement records: '+repr(acks))
        (E/'ack-state.txt').write_text('Handled records: '+repr(sorted(f.name for f in handled.glob('*.msg')))+'\n'+(S/'lane.pr-conflict-steer').read_text())
    scenario('Concurrent acknowledgement of delivered steers does not emit false fallback wakes',immediate_ack)

    # Fresh isolated Git project and actual control/spawn replacement.
    shutil.rmtree(S); S.mkdir()
    ENV.update(GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',FM_CONTROL_LAUNCH_WAIT='15',FM_CONTROL_POLL='0.1')
    project=W/'project'; project.mkdir()
    worker=W/'worker'
    run(['git','init','-q','-b','main',str(project)])
    (project/'README.md').write_text('Disposable conflict recovery validation.\n')
    run(['git','-C',str(project),'add','README.md'])
    run(['git','-C',str(project),'commit','-qm','Initial disposable fixture'])
    run(['git','-C',str(project),'worktree','add','-q','-b','worker',str(worker)])
    tmux('rename-window','-t','primary:fm-lane','primary-ui')
    tmux('new-window','-d','-t','primary:','-n','fm-lane','-c',str(worker),'bash --noprofile --norc')
    tmux('set-window-option','-t','primary:fm-lane','automatic-rename','off')
    (LAB/'config'/'lane-capacity').write_text('2 0\n')
    (LAB/'config'/'machine-admission.json').write_text(json.dumps({'schema':'fm-machine-admission.v1','memory_floor_gib':0,'disk_floor_gib':0,'memory_full_avg60_max':100,'disk_paths':[str(W)]}))
    (S/'lane.meta').write_text('window=primary:fm-lane\nendpoint_task_id=lane\nworktree='+str(worker)+'\nproject='+str(project)+'\nharness=codex\nkind=scout\nmodel=default\neffort=default\npr='+URL+'\n')
    data=LAB/'data'/'lane'; data.mkdir(exist_ok=True)
    (data/'brief.md').write_text("# Task\n\n## Captain's intent\n\nValidate an isolated replacement launch.\n\n## Firstmate spec\n\nRemain idle. Do not access the network, edit files, dispatch agents, or run a pipeline. No investigation is needed.\n")
    forge(); arm()
    def recovery():
        note('Before actual recovery: '+shell('. bin/fm-backend.sh; fm_backend_agent_state tmux primary:fm-lane').stdout)
        cycle('real-relaunch')
        assert (S/'lane.pr-conflict-episode').read_text().splitlines()[-1]=='action'
        assert not wakes() and not messages()
        note('After actual recovery: '+shell('. bin/fm-backend.sh; fm_backend_agent_state tmux primary:fm-lane').stdout)
        (E/'replacement-pane.txt').write_text(tmux('capture-pane','-p','-t','primary:fm-lane').stdout)
        for src,dest in [('lane.meta','real-relaunch.meta'),('lane.control-relaunch','real-relaunch-journal.txt')]:
            (E/dest).write_bytes((S/src).read_bytes())
        p=run(['bin/fm-control.sh','lane','exit']); note('Actual replacement exit: '+p.stdout+p.stderr)
        before=(S/'lane.control-relaunch').read_bytes()
        cycle('replacement-exited')
        assert len(wakes())==1 and not messages(), 'Expected exactly one conflict wake after actual replacement exit'
        cycle('replacement-exited-repeat')
        assert len(wakes())==1 and (S/'lane.control-relaunch').read_bytes()==before
        (E/'replacement-wake-queue.tsv').write_text((S/'.wake-queue').read_text())
    scenario('A real relaunched replacement exits unresolved and receives one conflict wake without another relaunch',recovery)
    def marker_failure():
        forge(D)
        marker=S/'lane.pr-conflict-relaunched'; marker.unlink(); marker.mkdir()
        before=(S/'lane.control-relaunch').read_bytes(); old=len(wakes())
        cycle('attempt-marker-unwritable')
        assert len(wakes())==old+1 and (S/'lane.control-relaunch').read_bytes()==before and not messages()
        cycle('attempt-marker-unwritable-repeat'); assert len(wakes())==old+1
        marker.rmdir()
    scenario('Failed attempt persistence prevents relaunch and publishes one fallback wake',marker_failure)
    # Adjacent watcher producers, using the original live Codex pane.
    tmux('rename-window','-t','primary:fm-lane','ended-worker')
    tmux('rename-window','-t','primary:primary-ui','fm-lane')
    def adjacent():
        for case in ['ready','stale']:
            shutil.rmtree(S); S.mkdir()
            (S/'lane.meta').write_text('kind=ship\nharness=codex\nwindow=primary:fm-lane\n')
            out=E/(case+'-live.stdout'); err=E/(case+'-live.stderr')
            with out.open('w') as o,err.open('w') as e:
                p=subprocess.Popen(['bash','bin/fm-watch.sh'],cwd=ROOT,env=ENV,stdout=o,stderr=e,start_new_session=True)
                try:
                    if case=='ready':
                        end=time.monotonic()+10
                        while not (S/'.last-watcher-beat').exists() and p.poll() is None and time.monotonic()<end: time.sleep(.005)
                        (S/'lane.status').write_text('done: PR ready '+URL+'\n')
                    rc=p.wait(timeout=20)
                finally:
                    if p.poll() is None: p.terminate(); p.wait(timeout=10)
            note(case+' watcher exit='+str(rc)+'; stdout='+repr(out.read_text())+'; stderr='+repr(err.read_text()))
            assert rc==0 and (('signal:' in out.read_text()) if case=='ready' else ('stale: primary:fm-lane' in out.read_text()))
            assert not messages()
    scenario('Ready and stale events surface supervision without adding instruction records',adjacent)
'''
ending='''
except Exception:
    note(traceback.format_exc())
    raise
finally:
    (E/'results.json').write_text(json.dumps(results,indent=2))
    if (W/'forge-calls.log').exists(): shutil.copyfile(W/'forge-calls.log',E/'forge-boundary-calls.jsonl')
    stopped=tmux('kill-server',check=False)
    note('Private tmux teardown exit='+str(stopped.returncode))
    assert stopped.returncode==0
    shutil.rmtree(LAB)
    shutil.rmtree(W)
    note('Disposable lab and worktree fixtures removed.')
    log.close()
'''
(E/'live.py').write_text(prefix+'\ntry:\n'+body+extra+ending)
