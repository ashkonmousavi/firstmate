import os,pathlib,subprocess,time,atexit,tempfile,shutil
R=pathlib.Path.cwd();B=pathlib.Path(tempfile.mkdtemp(prefix='.fm-relaunch-repro.',dir=R));E=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS']:
    E.pop(k,None)
def run(a,ok=0):
    global LAST_RC
    p=subprocess.run(list(map(str,a)),env=E,text=True,capture_output=True)
    LAST_RC=p.returncode
    print('$',' '.join(map(str,a)),flush=True);print(p.stdout+p.stderr,end='',flush=True)
    if ok is not None:assert p.returncode==ok,(p.returncode,p.stdout,p.stderr)
    return p.stdout
h=B/'home';run([R/'bin/fm-lab-home.sh','create',h]);E['FM_HOME']=str(h)
E['TMUX_TMPDIR']=run([R/'bin/fm-lab-home.sh','tmux-dir',h]).strip()
E['TMUX']=str(pathlib.Path(E['TMUX_TMPDIR'])/f'tmux-{os.getuid()}/fm-lab')+',0,0'
E.update(FM_BACKEND='tmux',FM_POLL='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_SIGNAL_GRACE='1',FM_SECONDMATE_LIVENESS_SECS='1',FM_SECONDMATE_LIVENESS_TIMEOUT='1')
(h/'config/supervision-host-off').touch()
run(['tmux','-L','fm-lab','new-session','-d','-s','firstmate','-n','anchor','-c',h,'-x','120','-y','40'])
holder=None
def cleanup():
    if holder is not None:
        (h/'release').touch()
        try:holder.wait(timeout=5)
        except subprocess.TimeoutExpired:holder.terminate();holder.wait()
    subprocess.run(['tmux','-L','fm-lab','kill-server'],env=E,capture_output=True)
    subprocess.run([str(R/'bin/fm-lab-home.sh'),'teardown',str(h)],env=E,capture_output=True)
    shutil.rmtree(B)
atexit.register(cleanup)
reg=[]
for ident in ['first','second']:
    mate=B/ident;run([R/'bin/fm-lab-home.sh','create',mate]);(mate/'.fm-secondmate-home').write_text(ident+'\n')
    run(['tmux','-L','fm-lab','new-window','-d','-t','firstmate','-n','fm-'+ident,'-c',mate])
    (h/f'state/{ident}.meta').write_text(f'window=firstmate:fm-{ident}\nworktree={mate}\nhome={mate}\nkind=secondmate\nharness=claude\nbackend=tmux\nspawn_gen=live-{ident}\n')
    reg.append(f'- {ident} (home: {mate}) - lab mate (projects: none; scope: lab)')
(h/'data/secondmates.md').write_text('\n'.join(reg)+'\n')
holder=subprocess.Popen(['bash','-c','. "$1"; fm_lock_acquire_wait "$FM_HOME/state/.secondmate-relaunch.lock"; touch "$FM_HOME/held"; while [ ! -e "$FM_HOME/release" ]; do sleep 0.1; done; fm_lock_release "$FM_HOME/state/.secondmate-relaunch.lock"','_',str(R/'bin/fm-wake-lib.sh')],env=E)
for _ in range(100):
    if (h/'held').exists():break
    time.sleep(.05)
else:raise RuntimeError('lock holder failed')
print('SCENARIO: a bounded checkpoint requests recovery; the foreground recovery cycle safely defers competing relaunches',flush=True)
out=run([R/'bin/fm-watch-checkpoint.sh','--seconds','8'])
assert 'recovery cycle required for relaunch' in out
queued=(h/'state/.wake-queue').read_text()
assert 'checkpoint-recovery-relaunch-first' in queued
run([R/'bin/fm-watch-checkpoint.sh','--recover'])
trace=(h/'state/.watch-triage.log').read_text()
print(trace,flush=True)
for ident in ['first','second']:
    assert f'secondmate {ident} liveness deferred:' in trace
    run(['tmux','-L','fm-lab','display-message','-p','-t','firstmate:fm-'+ident,'#{window_name}'])
    assert not (h/f'state/.secondmate-relaunch-{ident}').exists()
out=run([R/'bin/fm-watch-checkpoint.sh','--seconds','8'])
assert 'recovery cycle required for relaunch' in out
assert (h/'state/.wake-queue').read_text() == queued, 'recovery request was lost or duplicated'
print('PASS: bounded check requests recovery; recovery safely defers both mates; the unacknowledged request stays actionable without duplicate records.',flush=True)
