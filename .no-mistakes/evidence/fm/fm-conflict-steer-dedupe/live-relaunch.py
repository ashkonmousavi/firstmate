from pathlib import Path
E=Path('~/.no-mistakes/evidence/01M623WEVE8Z0BJ53B6V14ECWW')
prefix=(E/'live-conflict.py').read_text().split("\ntry:\n    note('Production")[0]
# Reuse the retained driver definitions without replaying its scenarios.
prefix=prefix.replace("log=(E/'live-conflict.log').open('w')", "log=(E/'live-relaunch.log').open('w')")
exec(prefix)
try:
    shutil.rmtree(S); S.mkdir()
    project=W/'project'; project.mkdir()
    ENV.update(GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',FM_CONTROL_LAUNCH_WAIT='15',FM_CONTROL_POLL='0.1')
    run(['git','init','-q','-b','main',str(project)])
    (project/'README.md').write_text('Disposable conflict recovery validation.\n')
    run(['git','-C',str(project),'add','README.md'])
    run(['git','-C',str(project),'commit','-qm','Initial disposable fixture'])
    tmux('rename-window','-t','primary:fm-lane','primary-ui')
    tmux('rename-window','-t','primary:keeper','fm-lane')
    tmux('set-window-option','-t','primary:fm-lane','automatic-rename','off')
    tmux('send-keys','-t','primary:fm-lane','cd '+str(project),'Enter')
    time.sleep(.3)
    meta(kind='scout')
    with (S/'lane.meta').open('a') as f:
        f.write('endpoint_task_id=lane\nproject='+str(project)+'\nworktree='+str(project)+'\nmodel=default\neffort=default\n')
    # Minimal structured brief accepted by the public launch renderer.
    data=LAB/'data'/'lane'; data.mkdir(exist_ok=True)
    (data/'brief.md').write_text('# Task\n\n## Captain\'s intent\n\nValidate an isolated replacement agent launch.\n\n## Firstmate spec\n\nThis is a disposable live validation. Remain idle. Do not access the network, edit files, dispatch agents, or run a pipeline. No investigation is needed.\n')
    forge(); arm()
    note('Before recovery: '+shell('. bin/fm-backend.sh; fm_backend_agent_state tmux primary:fm-lane').stdout)
    cycle('19-real-relaunch')
    note('Control journal:\n'+(S/'lane.control-relaunch').read_text() if (S/'lane.control-relaunch').exists() else 'No control journal')
    note('Endpoint after recovery: '+shell('. bin/fm-backend.sh; fm_backend_agent_state tmux primary:fm-lane').stdout)
    note('Pane after recovery:\n'+tmux('capture-pane','-p','-t','primary:fm-lane').stdout)
    marker=S/'lane.pr-conflict-relaunched'
    assert marker.exists(), 'No durable relaunch-attempt marker'
    assert not messages(), 'A dead endpoint received a steer'
    if (S/'lane.pr-conflict-episode').read_text().splitlines()[-1]=='action':
        assert not wakes(), 'Successful relaunch emitted a fallback wake'
        p=run(['bin/fm-control.sh','lane','exit']); note('Public lifecycle exit: '+p.stdout+p.stderr)
        cycle('20-replacement-exited')
        assert len(wakes())==1 and not messages()
        before=(S/'lane.control-relaunch').read_bytes()
        cycle('21-replacement-exited-repeat')
        assert len(wakes())==1 and (S/'lane.control-relaunch').read_bytes()==before
        results.append({'name':'Real replacement exits unresolved and yields exactly one fallback wake without relaunching again','result':'pass','live':True})
    else:
        assert len(wakes())==1, 'Failed recovery did not publish fallback wake'
        before=marker.read_bytes()
        cycle('20-failed-relaunch-repeat')
        assert len(wakes())==1 and marker.read_bytes()==before
        results.append({'name':'Real control-plane relaunch failure publishes one wake and preserves its attempt marker','result':'pass','live':True})
    (E/'relaunch-marker.txt').write_bytes(marker.read_bytes())
    (E/'relaunch-wake-queue.tsv').write_text((S/'.wake-queue').read_text())
except Exception:
    note(traceback.format_exc()); results.append({'name':'Real recovery control-plane exercise','result':'fail','live':True}); raise
finally:
    (E/'relaunch-results.json').write_text(json.dumps(results,indent=2))
    # Any agents are stopped by the enclosing private-server teardown before fixture deletion.
    log.close()
