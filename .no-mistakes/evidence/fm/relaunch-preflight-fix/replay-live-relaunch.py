import os, subprocess as sp, pathlib as p, tempfile, shutil, time, hashlib, json, sys, shlex
ROOT=p.Path.cwd(); E=p.Path('~/.no-mistakes/evidence/01M6MAKSCCRTYFWJ088627EQYQ')
LAB=p.Path(tempfile.mkdtemp(prefix='.lab-',dir=ROOT/'.test-validation')); HOME=LAB/'home'; PROJ=LAB/'project'; WT=LAB/'worker'
log=(E/'live-relaunch.log').open('w',buffering=1)
env=os.environ.copy()
for k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','HERDR_ENV','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_PANE_ID','HERDR_TAB_ID','HERDR_WORKSPACE_ID','FM_BACKEND','FM_TEST_SEAM','FM_TEST_HARNESS','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
    env.pop(k,None)
env.update(FM_HOME=str(HOME),FM_CONTROL_EXIT_WAIT='20',FM_CONTROL_LAUNCH_WAIT='35',FM_CONTROL_POLL='0.2',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null',GIT_TERMINAL_PROMPT='0')
socketdir=None; results=[]
def run(args,check=True,timeout=65,show=False):
    r=sp.run(list(map(str,args)),env=env,cwd=ROOT,stdout=sp.PIPE,stderr=sp.STDOUT,text=True,timeout=timeout)
    if show or r.returncode:
        log.write('$ '+ ' '.join(map(str,args))+'\n'+r.stdout+'\nexit='+str(r.returncode)+'\n')
    if check and r.returncode: raise RuntimeError('command failed: '+str(args)+': '+r.stdout)
    return r

def tm(*args,**kw): return run(['tmux','-L','fm-lab',*args],**kw)
def snap():
    h=hashlib.sha256()
    for root in (HOME,PROJ,WT):
        for f in sorted(root.rglob('*')):
            h.update(str(f.relative_to(LAB)).encode())
            h.update(str(f.lstat().st_mode).encode())
            if f.is_symlink(): h.update(os.readlink(f).encode())
            elif f.is_file(): h.update(f.read_bytes())
    return h.hexdigest()
def agent():
    return run(['bash','-c','. bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux primary:fm-live1']).stdout.strip()
def ids():
    tty=tm('display-message','-p','-t','primary:fm-live1','#{pane_tty}').stdout.strip()
    r=run(['ps','-t',tty.removeprefix('/dev/'),'-o','pid=,pgid=,tpgid=,comm='])
    return [line.strip() for line in r.stdout.splitlines() if 'claude' in line]
def refusal(name,args,rc,needle):
    before=snap(); pid_before=ids(); alive_before=agent()
    r=run(['bin/fm-control.sh','live1','relaunch',*args],check=False,show=True)
    after=snap(); pid_after=ids(); alive_after=agent()
    ok=(r.returncode==rc and needle in r.stdout and before==after and pid_before==pid_after and bool(pid_before) and alive_before==alive_after=='alive')
    detail={'name':name,'pass':ok,'returncode':r.returncode,'expected_returncode':rc,'snapshot_before':before,'snapshot_after':after,'agent_before':alive_before,'agent_after':alive_after,'process_before':pid_before,'process_after':pid_after}
    results.append(detail); log.write(json.dumps(detail,indent=2)+'\n'); print(name+': '+str(ok),flush=True)
    if not ok: raise RuntimeError('scenario failed: '+name)
try:
    run(['bin/fm-lab-home.sh','create',HOME])
    socketdir=run(['bin/fm-lab-home.sh','tmux-dir',HOME]).stdout.strip(); env['TMUX_TMPDIR']=socketdir
    (HOME/'config/backend').write_text('tmux\n'); (HOME/'config/lane-capacity').write_text('999999 0\n')
    (HOME/'config/supervision-host').touch()
    (HOME/'config/machine-admission.json').write_text(json.dumps({'schema':'fm-machine-admission.v1','memory_floor_gib':0,'memory_full_avg60_max':100,'disk_floor_gib':0,'disk_paths':[str(LAB)]})+'\n')
    PROJ.mkdir(); run(['git','-C',PROJ,'init','-q','-b','main'])
    (PROJ/'README.md').write_text('Disposable relaunch verification project.\n')
    run(['git','-C',PROJ,'add','README.md']); run(['git','-C',PROJ,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','initial'])
    run(['git','-C',PROJ,'worktree','add','-q','-b','fm/live1',WT])
    d=HOME/'data/live1'; d.mkdir()
    (d/'brief.md').write_text("# Task\n## Captain's intent\nValidate replacement refusal preserves a real running agent.\n\n## Firstmate spec\nReply READY and wait. Do not use tools or change files.\n")
    (HOME/'state/live1.meta').write_text(f'window=primary:fm-live1\nendpoint_task_id=live1\nbackend=tmux\nworktree={WT}\nproject={PROJ}\nharness=claude\nkind=ship\nmode=local-only\nyolo=off\nbranch=fm/live1\nmodel=default\neffort=default\n')
    # Config overrides are process-local. Hooks are disabled and no turn is submitted.
    cmd=['claude','-p','--input-format','stream-json','--output-format','stream-json','--verbose','--model','haiku','--setting-sources','','--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--no-session-persistence']
    tm('new-session','-d','-s','primary','-n','fm-live1','-x','120','-y','40','-c',WT,'-e',f'FM_HOME={HOME}')
    tm('set-window-option','-t','primary:fm-live1','remain-on-exit','on')
    tm('pipe-pane','-O','-t','primary:fm-live1','cat > '+str(E/'claude-pty.raw'))
    fifo=LAB/'claude-input'; os.mkfifo(fifo); fifo_fd=os.open(fifo,os.O_RDWR|os.O_NONBLOCK)
    tm('respawn-pane','-k','-t','primary:fm-live1','-c',WT,'exec '+shlex.join(cmd)+' < '+shlex.quote(str(fifo)))
    tm('show-options','-g','-v','default-command',check=False)
    tm('display-message','-p','-t','primary:fm-live1','#{socket_path}',show=True)
    env['TMUX']=tm('display-message','-p','-t','primary:fm-live1','#{socket_path}').stdout.strip()+',0,0'
    for _ in range(30):
        if agent()=='alive' and ids(): break
        time.sleep(0.5)
    time.sleep(3)
    os.write(fifo_fd,(json.dumps({'type':'user','message':{'role':'user','content':'Do not use tools or change files. Reply only LAB_READY.'}})+'\n').encode())
    for _ in range(80):
        screen=tm('capture-pane','-p','-t','primary:fm-live1','-S','-80').stdout
        if '"type":"result"' in screen or '"type": "result"' in screen: break
        time.sleep(0.5)
    capture=tm('capture-pane','-p','-t','primary:fm-live1','-S','-80').stdout
    (E/'claude-before.txt').write_text(capture); log.write('REAL HARNESS INITIAL SCREEN\n'+capture+'\n')
    assert agent()=='alive' and ids(), 'real Claude is not alive'
    assert 'LAB_READY' in capture and '"is_error":false' in capture.replace(' ',''), 'Claude did not complete the readiness turn'
    # Backlog exact incident: in-flight row held against new dispatch.
    backlog=HOME/'data/backlog.md'; backlog.write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    run(['tasks-axi','add','live1','live replacement verification','--kind','ship','--file',backlog])
    run(['tasks-axi','start','live1','--file',backlog]); run(['tasks-axi','hold','live1','--kind','external','--reason','replacement admission refusal','--file',backlog])
    refusal('held in-flight backlog preserves real Claude',['--note','must not be written'],1,'not dispatchable in state in_flight')
    run(['tasks-axi','unhold','live1','--file',backlog])
    (HOME/'config/lane-capacity').write_text('0 0\n')
    refusal('capacity rc75 preserves real Claude',['--note','must not be written'],75,'deferred:')
    (HOME/'config/lane-capacity').write_text('999999 0\n')
    for file,value,needle in [('claude-permission-mode','invalid','claude-permission-mode'),('codex-approval-mode','invalid','codex-approval-mode'),('codex-permission-mode','invalid','codex-permission-mode'),('lavish-axi-host','bad host','lavish-axi-host')]:
        f=HOME/'config'/file; f.write_text(value+'\n')
        refusal('invalid '+file+' preserves real Claude',['--note','must not be written'],1,needle); f.unlink()
    # Supported stale-lock states use real lock-owner helpers and real holder processes.
    for lockcase in ('project-lock','plain-steal','nested-steal','live-reaper'):
        hold=LAB/'hold.sh'; ready=LAB/'ready'; release=LAB/'release'
        hold.write_text(r"""#!/usr/bin/env bash
set -eu
. bin/fm-wake-lib.sh
lock=$(fm_treehouse_project_lock_path "$1")
dead_create() { bash -c '. bin/fm-wake-lib.sh; fm_lock_try_create "$1"' _ "$1"; }
ready() { touch "$2"; while [ ! -e "$3" ]; do sleep 0.05; done; }
case "$4" in
project-lock) fm_lock_acquire_wait "$lock"; ready "$@"; fm_lock_release "$lock" ;;
plain-steal) dead_create "$lock"; mkdir "$lock.steal"; printf '99999999\n' > "$lock.steal/pid"; ready "$@" ;;
nested-steal) dead_create "$lock"; fm_lock_try_create "$lock.steal.steal"; ready "$@"; fm_lock_release "$lock.steal.steal" ;;
live-reaper)
  dead_create "$lock"; dead_create "$lock.steal"; sleep 3
  # Keep the existing owner paused immediately before the unlink.
  READY_PATH=$2 RELEASE_PATH=$3
  rm() { if [ "${!#}" = "$lock.steal" ]; then touch "$READY_PATH"; while [ ! -e "$RELEASE_PATH" ]; do sleep 0.05; done; fi; command rm "$@"; }
  fm_lock_reap_dead_link "$lock.steal" ;;
esac
""")
        holder=sp.Popen(['bash',str(hold),str(PROJ),str(ready),str(release),lockcase],env=env,cwd=ROOT,stdout=log,stderr=log)
        try:
            for _ in range(160):
                if ready.exists(): break
                if holder.poll() is not None: raise RuntimeError('lock holder exited early')
                time.sleep(0.05)
            assert ready.exists(), 'lock fixture did not become ready'
            refusal(lockcase+' preserves real Claude',['--note','must not be recorded'],75,'another Treehouse slot allocation or return is in progress')
        finally:
            release.touch()
            try: assert holder.wait(timeout=10)==0
            except sp.TimeoutExpired: holder.kill(); holder.wait(); raise
            ready.unlink(missing_ok=True); release.unlink(missing_ok=True)
        # Only test-owned lock files inside the disposable project are removed.
        lockpath=p.Path(run(['bash','-c','. bin/fm-wake-lib.sh; fm_treehouse_project_lock_path "$1"','_',PROJ]).stdout.strip())
        assert lockpath.is_relative_to(LAB)
        for f in lockpath.parent.glob(lockpath.name+'*'):
            if f.is_symlink() or f.is_file(): f.unlink()
            elif f.is_dir(): shutil.rmtree(f)
    (HOME/'config/herdr-lifecycle-spawn-guard').touch()
    note='Do not run bin/fm-herdr-lab.sh; continue the source fix'
    for kind in ('ship','scout'):
        meta=HOME/'state/live1.meta'; meta.write_text(meta.read_text().replace('kind=ship','kind='+kind))
        for option in ('--note','--note-file'):
            notevalue=note
            if option=='--note-file':
                note_file=LAB/'pending-note'; note_file.write_text(note+'\n'); notevalue=str(note_file)
            refusal(kind+' '+option+' effective note preserves real Claude',[option,notevalue],1,'pending progress note caused this refusal')
    refusal('unverified replacement adapter preserves real Claude',['--harness','invalid-fixture','--note','must not be written'],1,'not a verified harness')
    env['FM_SUPERVISION_MODEL']='persistent'
    marker=HOME/'state/.guard-watcher-stale-banner'
    fresh=['bin/fm-spawn.sh','fresh',str(PROJ),'--mode','local-only','--yolo','off','--harness','invalid-fixture']
    r=run(fresh,check=False,show=True)
    assert r.returncode and 'WATCHER DOWN' in r.stdout and marker.exists(), 'ordinary fresh spawn failed to record warning'
    old_meta=HOME/'state/live1.meta'; saved_meta=LAB/'saved-meta'; old_meta.rename(saved_meta)
    r=run(fresh,check=False,show=True)
    assert r.returncode and not marker.exists(), 'ordinary fresh spawn failed to clear recovered warning'
    saved_meta.rename(old_meta)
    results.append({'name':'ordinary fresh spawn records and clears warning episode','pass':True,'real_guard':True})
    log.write('PASS ordinary fresh spawn records and clears warning episode through real fm-spawn and fm-guard\n')
    (E/'claude-after.txt').write_text(tm('capture-pane','-p','-t','primary:fm-live1','-S','-80').stdout)
    log.write('LIVE SCENARIOS COMPLETE\n')
except Exception as exc:
    log.write('DRIVER ERROR: '+repr(exc)+'\n'); print(repr(exc),file=sys.stderr); raise
finally:
    if 'fifo_fd' in locals(): os.close(fifo_fd)
    if socketdir:
        tm('kill-server',check=False,show=True)
        run(['bin/fm-lab-home.sh','teardown',HOME],check=False,show=True)
    (E/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(LAB)
    log.write('Disposable lab removed.\n'); log.close()
