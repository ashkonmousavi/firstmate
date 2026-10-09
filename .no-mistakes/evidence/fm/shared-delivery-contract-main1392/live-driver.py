import os, pathlib, subprocess, tempfile, time, signal, shutil, json
ROOT = pathlib.Path('/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4F2NZEMTNTG7A1KQNEJ55Y7')
EVID = pathlib.Path('/home/tegris/.no-mistakes/evidence/01M4F2NZEMTNTG7A1KQNEJ55Y7')
INVOKING = '/home/tegris/.treehouse/fm-fleet-ops-befb82/5/fm-fleet-ops'
RUN = '01M4F2NZEMTNTG7A1KQNEJ55Y7'
base = os.environ.copy()
for key in list(base):
    if key.startswith('FM_') or key in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX','TMUX_PANE','HERDR_SESSION_ID','HERDR_PANE_ID']:
        base.pop(key)
# A nonexistent task-private socket: real tmux reads cannot reach operator namespaces.
base['TMUX'] = str(EVID / 'live-private.sock') + ',0,0'
base['FM_WEDGE_ALARM_EXEC'] = 'discard'
records=[]; homes=[]
def command(args, env=base):
    r=subprocess.run(args,cwd=ROOT,env=env,text=True,capture_output=True,timeout=30)
    if r.returncode: raise RuntimeError(f'{args}: {r.returncode}: {r.stderr}')
    return r.stdout

def home(name, cap='3', release=None, ready=True):
    h=pathlib.Path(tempfile.mkdtemp(prefix='.fm-test-live-',dir=ROOT)); homes.append(h)
    command([str(ROOT/'bin/fm-lab-home.sh'),'create',str(h)])
    (h/'config/backend').write_text('tmux\n')
    (h/'config/writing-lane-cap').write_text(cap+'\n')
    if release is not None: (h/'config/release-capacity').write_text(release+'\n')
    (h/'data/backlog.md').write_text('# Backlog\n\n## Queued\n'+('- [ ] repair-one - Dispatchable repair (kind: ship)\n' if ready else ''))
    return h

def meta(h, task='one', pr=False, attributed=False):
    (h/f'state/{task}.meta').write_text('kind=ship\nmode=no-mistakes\nworktree='+ (INVOKING if attributed else str(h/'projects')) +'\n'+('pr=https://github.com/example/repo/pull/7\n' if pr else ''))

def env_for(h):
    e=base.copy(); e.update(FM_HOME=str(h),FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_IDLE_LANE_CHECK_INTERVAL='0',FM_WATCH_HANDLING_SUCCESSOR='1',FM_CREW_STATE_BIN=str(ROOT/'bin/fm-crew-state.sh'))
    return e

def drive(name,h,expect=None,diag=None,marker_absent=False):
    marker=h/'state/.last-idle-lane-wake'
    if marker.exists(): os.utime(marker,(time.time()-60,time.time()-60))
    before_marker=marker.read_text() if marker.exists() else None
    queue=h/'state/.wake-queue'; before_queue=queue.read_text() if queue.exists() else ''
    out=h/'watch.out'; err=h/'watch.err'; triage=h/'state/.watch-triage.log'
    p=None
    try:
        with out.open('w') as o, err.open('w') as er:
            p=subprocess.Popen([str(ROOT/'bin/fm-watch.sh')],cwd=ROOT,env=env_for(h),stdout=o,stderr=er,start_new_session=True)
            if expect is not None: p.wait(timeout=30)
            elif diag:
                deadline=time.monotonic()+25
                while time.monotonic()<deadline:
                    if triage.exists() and diag in triage.read_text(): break
                    if p.poll() is not None: break
                    time.sleep(.1)
                assert triage.exists() and diag in triage.read_text(), 'missing diagnostic'
                time.sleep(.5)
                assert p.poll() is None, 'quiet watcher unexpectedly exited'
            else:
                time.sleep(3)
                assert p.poll() is None, 'quiet watcher unexpectedly exited'
            if expect is None:
                p.terminate(); p.wait(timeout=5)
        output=out.read_text(); q=queue.read_text() if queue.exists() else ''; log=triage.read_text() if triage.exists() else ''
        if expect is not None:
            assert p.returncode==0, f'watcher exit {p.returncode}'
            assert expect in output, f'expected {expect!r}, got {output!r}'
            assert expect in q and q != before_queue, 'wake not durable'
        else:
            assert output=='', f'unexpected wake {output!r}'
            assert q==before_queue, 'quiet watcher appended queue'
        if marker_absent: assert not marker.exists(), 'unexpected notice marker'
        rec=dict(name=name,result='pass',stdout=output,wake_queue=q,triage=log,marker_before=before_marker,marker_after=marker.read_text() if marker.exists() else None)
        records.append(rec); print(json.dumps(rec,ensure_ascii=False),flush=True)
        return rec
    except Exception as ex:
        rec=dict(name=name,result='fail',error=str(ex),stdout=out.read_text() if out.exists() else '',stderr=err.read_text() if err.exists() else '',triage=triage.read_text() if triage.exists() else '')
        records.append(rec); print(json.dumps(rec,ensure_ascii=False),flush=True); raise
    finally:
        if p:
            if p.poll() is None: p.terminate(); p.wait(timeout=5)
            try: os.killpg(p.pid,signal.SIGTERM)
            except ProcessLookupError: pass

try:
    h=home('empty',ready=False)
    drive('Empty backlog produces no fill-lanes notice',h,marker_absent=True)
    with (h/'data/backlog.md').open('a') as f: f.write('- [ ] repair-one - Dispatchable repair (kind: ship)\n')
    drive('Ready work below writing maximum is named',h,'0/3 occupied, 0 working, 1 ready: repair-one')
    drive('Unchanged ready work does not repeat',h)
    with (h/'data/backlog.md').open('a') as f: f.write('- [ ] independent-two - Independent work (kind: ship)\n')
    drive('Changed ready set is named',h,'2 ready: repair-one,independent-two')
    for task in ['one','two','three']: meta(h,task,pr=True)
    drive('Full writing maximum suppresses fill notice',h,marker_absent=True)

    h=home('release',release='2'); meta(h,pr=True)
    drive('One published lane below release bound keeps ordinary notice',h,'idle writing lanes: 1/3 occupied')
    meta(h,'two',pr=True)
    drive('Published lanes saturate release bound and keep repair visible',h,'lane backpressure: 2/2 lanes awaiting validation or release; land or repair them before new starts, 2/3 occupied, 1 ready: repair-one')
    drive('Unchanged release pressure does not repeat',h)
    (h/'state/two.meta').unlink()
    drive('Retiring a published lane releases pressure',h,'idle writing lanes: 1/3 occupied')

    h=home('unconfigured'); meta(h)
    r=drive('Unconfigured release capacity reports ordinary availability',h,'idle writing lanes: 1/3 occupied')
    meta(h,pr=True)
    r2=drive('Adding PR without release capacity stays quiet',h)
    assert r['marker_after']==r2['marker_after']
    meta(h)
    drive('Removing PR without release capacity stays quiet',h)

    for value in ['00','0000','0','-1','','zero','9223372036854775808','18446744073709551616','9999999999999999999999999999999999999999','directory','dangling']:
        h=home('invalid',release=None)
        cap=h/'config/release-capacity'
        if value=='directory': cap.mkdir()
        elif value=='dangling': cap.symlink_to('missing-capacity')
        else: cap.write_text(value+'\n')
        diagnostic=('unreadable' if value in ['directory','dangling'] else 'invalid')+' config/release-capacity'
        drive('Capacity '+repr(value)+' refuses with diagnostic',h,diag=diagnostic,marker_absent=True)
    for value in ['0001','9223372036854775807']:
        h=home('valid',release=value);meta(h,pr=True)
        drive('Supported positive bound '+value+' remains usable',h,'lane backpressure: 1/0001' if value=='0001' else 'idle writing lanes: 1/3 occupied')

    h=home('unknown',release='1');meta(h)
    state=command([str(ROOT/'bin/fm-crew-state.sh'),'one'],env_for(h));print('REAL_UNKNOWN_STATE '+state,flush=True)
    assert state.startswith('state: unknown · source: none')
    drive('Unavailable real crew state refuses a capacity notice',h,diag='idle-lane release state unavailable: one',marker_absent=True)
    meta(h,pr=True)
    drive('Recorded PR establishes pressure despite unavailable crew state',h,'lane backpressure: 1/1')

    h=home('attributed',release='2'); meta(h,attributed=True)
    status=command(['no-mistakes','axi','status','--run',RUN]); (EVID/'live-run-status.txt').write_text(status)
    state=command([str(ROOT/'bin/fm-crew-state.sh'),'one'],env_for(h)); (EVID/'live-attributed-state.txt').write_text(state)
    print('REAL_ATTRIBUTED_STATE '+state,flush=True)
    assert state.startswith('state: working · source: run-step') and RUN in state, 'current real run did not attribute'
    (h/'config/release-capacity').write_text('1\n')
    drive('Current real validation saturates capacity without a PR',h,'lane backpressure: 1/1')
    meta(h,attributed=True,pr=True)
    drive('Adding PR to already counted real validation does not repeat',h)
    (h/'config/release-capacity').write_text('2\n')
    drive('Real validation plus PR on one lane counts once below bound two',h,'idle writing lanes: 1/3 occupied')
    meta(h,'two',pr=True)
    drive('Second published lane plus real validation saturates bound two',h,'lane backpressure: 2/2')
finally:
    (EVID/'live-results.json').write_text(json.dumps(records,ensure_ascii=False,indent=2)+'\n')
    for h in homes: shutil.rmtree(h)
    print('TEARDOWN all disposable homes removed; no tmux server created; all tmux reads used '+base['TMUX'],flush=True)
