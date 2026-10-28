import os, pathlib, subprocess, time, json, signal, shutil, traceback
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M623WEVE8Z0BJ53B6V14ECWW/round2')
LAB=E.parent/'r2'
W=ROOT/'.conflict-live-validation'
W.mkdir(exist_ok=False)
B=W/'bin'; B.mkdir()
S=LAB/'state'
log=(E/'adjacent.log').open('w')
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
    tmux('rename-window','-t','primary:','fm-lane')
    tmux('set-window-option','-t','primary:fm-lane','automatic-rename','off')
    deadline=time.monotonic()+20
    while 'OpenAI Codex' not in tmux('capture-pane','-p','-t','primary:fm-lane').stdout:
        assert time.monotonic()<deadline, 'Real Codex did not render'
        time.sleep(.1)
    tmux('send-keys','-t','primary:fm-lane','-l','Isolated validation: leave this draft unsubmitted.')
    time.sleep(.3)
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

finally:
    stopped=tmux('kill-server',check=False)
    note('Private tmux teardown exit='+str(stopped.returncode))
    assert stopped.returncode==0
    remove_tree(LAB); remove_tree(W)
    (E/'adjacent-results.json').write_text(json.dumps(results,indent=2))
    note('Disposable lab and worktree fixtures removed.')
    log.close()
