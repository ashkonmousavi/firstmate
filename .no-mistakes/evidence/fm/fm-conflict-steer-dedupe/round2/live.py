import os, pathlib, subprocess, time, json, signal, shutil, traceback
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M623WEVE8Z0BJ53B6V14ECWW/round2')
LAB=E.parent/'r2'
W=ROOT/'.conflict-live-validation'
W.mkdir(exist_ok=False)
B=W/'bin'; B.mkdir()
S=LAB/'state'
log=(E/'live.log').open('w')
results=[]
def note(s):
    print(s,flush=True); log.write(s+'\n'); log.flush()
def run(args,env=None,check=True):
    p=subprocess.run(args,cwd=ROOT,env=env or ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if p.returncode and check: raise RuntimeError(f'{args}: exit {p.returncode}: {p.stdout} {p.stderr}')
    return p
ENV=os.environ.copy()
for k in list(ENV):
    if k.startswith('FM_') or k in ['TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION','HERDR_PANE_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
        ENV.pop(k,None)
ENV.update(FM_HOME=str(LAB),TMUX_TMPDIR=str(LAB/'tmux'))
def tmux(*args,check=True): return run(['/usr/bin/tmux','-L','fm-lab',*args],check=check)
ENV['TMUX']=tmux('display-message','-p','#{socket_path},#{pid},0').stdout.strip()
ENV.update(PATH=str(B)+':'+os.environ['PATH'],FM_CHECK_INTERVAL='1',FM_POLL='0.1',FM_HEARTBEAT='999999',FM_SIGNAL_GRACE='0',FM_TASK_INBOX_RING_SECS='999999',FM_WATCH_HANDLING_SUCCESSOR='1')
(B/'gh').write_text('''#!/usr/bin/env python3
import os,sys,json,subprocess,pathlib
a=sys.argv[1:]
w=pathlib.Path(__file__).resolve().parents[1]
c=json.loads((w/'forge.json').read_text())
with (w/'forge-calls.log').open('a') as f: f.write(json.dumps(a)+'\\n')
if a[:2]==['pr','view']:
 print(c.get('state','OPEN'))
elif a[:2]==['api','graphql']:
 p=subprocess.run(['jq','-r',a[a.index('--jq')+1]],input=json.dumps(c['graphql']),text=True)
 sys.exit(p.returncode)
else:
 print('Unsupported isolated forge request',file=sys.stderr); sys.exit(91)
''')
(B/'gh').chmod(0o755)
A='2026-01-01T00:00:00Z'; BDATE='2026-02-02T00:00:00Z'; C='2026-03-03T00:00:00Z'; D='2026-04-04T00:00:00Z'
URL='https://github.com/disposable/conflict-lab/pull/7'
def forge(date=A,present=True):
    pr={'labels':{'nodes':[{'name':'conflict'}] if present else []},'timelineItems':{'nodes':[{'__typename':'LabeledEvent','createdAt':date,'label':{'name':'conflict'}}]}}
    (W/'forge.json').write_text(json.dumps({'state':'OPEN','graphql':{'data':{'repository':{'pullRequest':pr}}}}))
def shell(s,check=True): return run(['bash','-c',s],check=check)
def meta(endpoint='primary:fm-lane',kind='ship'):
    (S/'lane.meta').write_text(f'kind={kind}\nharness=codex\nbackend=tmux\nwindow={endpoint}\nbase_branch=main\npr={URL}\n')
def arm():
    shell('. bin/fm-pr-lib.sh; fm_pr_poll_prepare "$FM_HOME/state" lane github '+URL+' github.com disposable/conflict-lab 7 "$PWD/bin/fm-pr-poll.sh" && fm_pr_poll_publish_prepared')
def messages(): return sorted((S/'lane.inbox').glob('*.msg'))
def wakes():
    p=S/'.wake-queue'
    return [s for s in p.read_text().splitlines() if '\tcheck\t' in s and s.endswith('lane.check.sh: conflict')] if p.exists() else []
def cycle(label):
    # A completed .last-check update proves a whole authenticated PR sweep finished.
    last=S/'.last-check'
    last.unlink(missing_ok=True)
    before=0
    out=E/(label+'.stdout'); err=E/(label+'.stderr')
    with out.open('w') as o,err.open('w') as e:
        p=subprocess.Popen(['bash','bin/fm-watch.sh'],cwd=ROOT,env=ENV,stdout=o,stderr=e,start_new_session=True)
        deadline=time.monotonic()+30
        try:
            while time.monotonic()<deadline:
                if last.exists() and last.stat().st_mtime_ns != before: break
                if p.poll() is not None: raise RuntimeError(f'{label}: watcher exited {p.returncode} before completing sweep: {err.read_text()} {out.read_text()}')
                time.sleep(.05)
            else: raise RuntimeError(f'{label}: watcher sweep timed out: {err.read_text()}')
        finally:
            stopped_by_driver=p.poll() is None
            if stopped_by_driver: p.send_signal(signal.SIGTERM)
            rc=p.wait(timeout=10)
    assert rc in (0,143,-15) or (stopped_by_driver and rc==1), (label,rc,err.read_text())
    note(f'{label}: watcher exit={rc}; unread={[x.name for x in messages()]}; conflict wakes={len(wakes())}')
    if out.read_text().strip(): note('  watcher output: '+out.read_text().strip())
    if err.read_text().strip(): note('  watcher stderr: '+err.read_text().strip())
    if (S/'lane.pr-conflict-episode').exists(): note('  episode: '+(S/'lane.pr-conflict-episode').read_text().replace('\n',' | '))
def scenario(name,fn):
    try:
        fn(); results.append({'name':name,'result':'pass','live':True}); note('PASS '+name)
    except Exception as ex:
        results.append({'name':name,'result':'fail','live':True,'reason':str(ex)}); raise
def remove_tree(path):
    for base,dirs,files in os.walk(path):
        for d in dirs:
            child=pathlib.Path(base)/d
            if not child.is_symlink(): child.chmod(child.stat().st_mode|0o700)
    shutil.rmtree(path)

try:
    note('Production watcher + sender + tmux/Codex endpoint. Only the external forge is a disposable fixture; no real PR or fleet data is accessed.')
    note('Oracle: author intent and recorded R1-R6 decisions; forbidden outcomes are duplicate unread messages, steering done/dead tasks, lost fallback wakes, and duplicate wakes.')
    tmux('rename-window','-t','primary:','fm-lane')
    tmux('set-window-option','-t','primary:fm-lane','automatic-rename','off')
    deadline=time.monotonic()+20
    while 'OpenAI Codex' not in tmux('capture-pane','-p','-t','primary:fm-lane').stdout:
        assert time.monotonic()<deadline, 'Real Codex did not render'
        time.sleep(.1)
    tmux('send-keys','-t','primary:fm-lane','-l','Isolated validation: leave this draft unsubmitted.')
    time.sleep(.3)
    meta(); forge(); arm()
    state=shell('. bin/fm-backend.sh; fm_backend_agent_alive tmux primary:fm-lane; echo; fm_backend_composer_state tmux primary:fm-lane fm-lane').stdout
    note('Actual endpoint probes: '+repr(state)); assert state.split()==['alive','pending']
    (E/'codex-endpoint.txt').write_text(tmux('capture-pane','-p','-t','primary:fm-lane').stdout)
    def live_dedupe():
        cycle('01-first-conflict'); assert len(messages())==1 and len(wakes())==0
        (E/'delivered-conflict.msg').write_bytes(messages()[0].read_bytes())
        for i in range(3): cycle(f'02-repeat-{i}')
        assert len(messages())==1 and not wakes()
    scenario('Live worker receives one durable conflict steer across repeated polls',live_dedupe)
    def relabel():
        forge(BDATE); cycle('03-relabel-without-clear'); assert len(messages())==1 and not wakes()
        forge(BDATE,False); cycle('04-conflict-clear'); assert not (S/'lane.pr-conflict-episode').exists()
        assert (S/'lane.pr-conflict-steer').exists()
        forge(C); cycle('05-relabel-after-clear'); assert len(messages())==1 and not wakes()
    scenario('Unread steer survives label reapplication and observed conflict-clear',relabel)
    def upgrade():
        (S/'lane.pr-conflict-steer').unlink(); (S/'lane.pr-conflict-episode').unlink()
        cycle('06-upgrade-unbound'); assert len(messages())==1 and not wakes()
        assert (S/'lane.pr-conflict-steer').read_text().splitlines()[-1]==messages()[0].name
        # A restart after delivery but before binding has the same persisted state.
        (S/'lane.pr-conflict-steer').unlink(); (S/'lane.pr-conflict-episode').unlink()
        cycle('07-restart-before-bind'); assert len(messages())==1 and not wakes()
        # Owned serialized v2 episode protocol, as produced by the pre-upgrade watcher.
        (S/'lane.pr-conflict-episode').write_text('fm-pr-conflict-episode-v2\ngithub\ngithub.com\ndisposable/conflict-lab\n7\n'+C+'\n')
        (S/'lane.pr-conflict-episode').chmod(0o600)
        cycle('08-existing-v2'); assert len(messages())==1 and not wakes()
    scenario('Upgrade and restart recover an unbound unread steer and accept a v2 episode',upgrade)
    def binding_failure():
        (S/'lane.pr-conflict-episode').unlink(); (S/'lane.pr-conflict-steer').unlink()
        (S/'lane.pr-conflict-steer').mkdir()
        forge(D); cycle('09-unwritable-binding'); assert len(messages())==1 and len(wakes())==1
        cycle('10-binding-failure-repeat'); assert len(messages())==1 and len(wakes())==1
        (S/'lane.pr-conflict-steer').rmdir()
    scenario('Failed binding blocks a duplicate send and publishes one fallback wake',binding_failure)
    def ack():
        inbox=S/'lane.inbox'; (inbox/'handled').mkdir(exist_ok=True)
        for f in messages(): f.rename(inbox/'handled'/f.name)
        forge(D,False); cycle('11-clear-after-ack')
        forge('2026-05-05T00:00:00Z'); cycle('12-new-episode-after-ack')
        assert len(messages())==1 and messages()[0].name=='002.msg' and len(wakes())==1
    scenario('Acknowledging the old steer allows exactly one steer for a new episode',ack)
    def done():
        (S/'lane.status').write_text('done: completed before conflict recovery\n')
        cycle('13-live-worker-becomes-done'); assert len(messages())==1 and len(wakes())==2
        for i in range(2): cycle(f'14-done-repeat-{i}')
        assert len(messages())==1 and len(wakes())==2
    scenario('A task completing after steering receives one conflict wake and no more steers',done)
    def missing():
        (S/'lane.status').unlink(); meta('primary:missing-lane')
        forge('2026-06-06T00:00:00Z'); cycle('15-dead-endpoint'); assert len(messages())==1 and len(wakes())==3
        assert (S/'lane.pr-conflict-relaunched').exists()
        cycle('16-dead-endpoint-repeat'); assert len(messages())==1 and len(wakes())==3
        # No endpoint in a new task episode must also wake without enqueueing.
        meta(''); forge('2026-07-07T00:00:00Z'); cycle('17-no-endpoint'); assert len(messages())==1 and len(wakes())==4
        cycle('18-no-endpoint-repeat'); assert len(wakes())==4
    scenario('Dead or missing endpoints fall back to one wake without enqueueing unread instructions',missing)
    note('Initial durable conflict wakes:\n'+'\n'.join(wakes()))
    (E/'wake-queue.tsv').write_text((S/'.wake-queue').read_text())
    (E/'steer-binding.txt').write_text((S/'lane.pr-conflict-steer').read_text())
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
    remove_tree(S); S.mkdir()
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
            remove_tree(S); S.mkdir()
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

except Exception:
    note(traceback.format_exc())
    raise
finally:
    (E/'results.json').write_text(json.dumps(results,indent=2))
    if (W/'forge-calls.log').exists(): shutil.copyfile(W/'forge-calls.log',E/'forge-boundary-calls.jsonl')
    stopped=tmux('kill-server',check=False)
    note('Private tmux teardown exit='+str(stopped.returncode))
    assert stopped.returncode==0
    remove_tree(LAB)
    remove_tree(W)
    note('Disposable lab and worktree fixtures removed.')
    log.close()
