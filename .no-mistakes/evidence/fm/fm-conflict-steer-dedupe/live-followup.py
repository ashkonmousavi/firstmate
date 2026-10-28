from pathlib import Path
E=Path('~/.no-mistakes/evidence/01M623WEVE8Z0BJ53B6V14ECWW')
prefix=(E/'live-conflict.py').read_text().split("\ntry:\n    note('Production")[0]
prefix=prefix.replace('W.mkdir(exist_ok=False)','W.mkdir(exist_ok=True)').replace("B=W/'bin'; B.mkdir()", "B=W/'bin'; B.mkdir(exist_ok=True)").replace("log=(E/'live-conflict.log').open('w')", "log=(E/'live-followup.log').open('w')")
exec(prefix)
try:
    note('Causal check: preserve the real relaunch output, then reorder only lab metadata to test why authentication rejects it.')
    m=S/'lane.meta'
    for src,dest in [('lane.meta','real-relaunch.meta'),('lane.control-relaunch','real-relaunch-journal.txt'),('lane.pr-conflict-episode','episode-after-replacement-exit.txt')]:
        (E/dest).write_bytes((S/src).read_bytes())
    p=shell('. bin/fm-pr-lib.sh; fm_pr_metadata_identity_parse "$FM_HOME/state/lane.meta"',check=False)
    note('Actual product-emitted metadata parser exit='+str(p.returncode)); assert p.returncode==1
    old=len(wakes())
    # Rearrange exactly one existing, producer-owned field in disposable fixture data.
    lines=m.read_text().splitlines()
    tx=[s for s in lines if s.startswith('control_relaunch_tx=')]
    m.write_text('\n'.join(tx+[s for s in lines if not s.startswith('control_relaunch_tx=')])+'\n')
    p=shell('. bin/fm-pr-lib.sh; fm_pr_metadata_identity_parse "$FM_HOME/state/lane.meta"',check=False)
    note('Same fields with control_relaunch_tx before pr: parser exit='+str(p.returncode)); assert p.returncode==0
    cycle('28-reordered-fixture-conflict-recovery')
    assert len(wakes())==old+1
    cycle('29-reordered-fixture-repeat'); assert len(wakes())==old+1
    note('Restoring metadata order in fixture alone restores exactly one conflict fallback wake; source remains unchanged.')
    # R5: if the attempt cannot be persisted, the real handler must never call control.
    forge(D)
    marker=S/'lane.pr-conflict-relaunched'; marker.unlink(); marker.mkdir()
    before=(S/'lane.control-relaunch').read_bytes(); old=len(wakes())
    cycle('30-attempt-marker-unwritable')
    assert len(wakes())==old+1 and (S/'lane.control-relaunch').read_bytes()==before and not messages()
    cycle('31-attempt-marker-unwritable-repeat'); assert len(wakes())==old+1
    marker.rmdir()
    note('PASS Failed attempt persistence published one conflict wake and never invoked relaunch (journal unchanged).')
    # R4/R6: real worker acknowledgement races with the actual sender, without replacing any product helper.
    tmux('rename-window','-t','primary:fm-lane','recover-ended')
    tmux('rename-window','-t','primary:primary-ui','fm-lane')
    meta()
    import threading
    handled=S/'lane.inbox'/'handled'; handled.mkdir(parents=True,exist_ok=True)
    stop=threading.Event(); acks=[]
    def acknowledge():
        while not stop.is_set():
            for f in messages():
                try:
                    f.rename(handled/f.name); acks.append((f.name,time.time_ns()))
                except FileNotFoundError: pass
            time.sleep(.001)
    thread=threading.Thread(target=acknowledge); thread.start()
    try:
        old=len(wakes())
        for date,num in [('2026-08-08T00:00:00Z',32),('2026-09-09T00:00:00Z',33),('2026-10-10T00:00:00Z',34)]:
            forge(date); cycle(str(num)+'-immediate-worker-ack')
            assert not messages() and len(wakes())==old
            assert (S/'lane.pr-conflict-episode').read_text().splitlines()[-1]=='action'
        assert len(acks)==3
    finally:
        stop.set(); thread.join(timeout=5); assert not thread.is_alive()
    note('PASS Immediate acknowledgements while real fm-send confirms delivery produced no false fallback wakes: '+repr(acks))
    (E/'immediate-ack-state.txt').write_text('Handled records: '+repr(sorted(x.name for x in handled.glob('*.msg')))+'\nBinding:\n'+(S/'lane.pr-conflict-steer').read_text()+'Episode:\n'+(S/'lane.pr-conflict-episode').read_text())
    # Adjacent stale and ready/status producers: execute their real classifiers with lab records.
    for verb in ['working: isolated ongoing work','done: PR ready https://github.com/disposable/conflict-lab/pull/7']:
        (S/'lane.status').write_text(verb+'\n')
        before=list(messages()); old=len(wakes())
        p=shell('. bin/fm-supervise-daemon.sh; classify_stale primary:fm-lane "$FM_HOME/state"; echo; classify_signal "$FM_HOME/state/lane.status" "$FM_HOME/state"; echo')
        note('Adjacent stale/ready classification for '+repr(verb)+':\n'+p.stdout)
        assert list(messages())==before and len(wakes())==old
    note('PASS Adjacent stale/ready classifiers route supervision events without creating conflict-like instruction records.')
except Exception:
    note(traceback.format_exc()); raise
finally:
    log.close()
