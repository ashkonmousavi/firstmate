import os, pathlib, subprocess, time, json, signal, shutil, traceback
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M623WEVE8Z0BJ53B6V14ECWW')
LAB=pathlib.Path((E/'lab-path.txt').read_text().strip())
W=ROOT/'.conflict-live-validation'
W.mkdir(exist_ok=False)
B=W/'bin'; B.mkdir()
S=LAB/'state'
log=(E/'live-conflict.log').open('w')
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
ENV.update(PATH=str(B)+':'+os.environ['PATH'],FM_CHECK_INTERVAL='0',FM_POLL='0.1',FM_HEARTBEAT='999999',FM_SIGNAL_GRACE='0',FM_TASK_INBOX_RING_SECS='999999',FM_WATCH_HANDLING_SUCCESSOR='1')
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
    before=last.stat().st_mtime_ns if last.exists() else 0
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
            if p.poll() is None: p.send_signal(signal.SIGTERM)
            rc=p.wait(timeout=10)
    assert rc in (0,143,-15), (label,rc,err.read_text())
    note(f'{label}: watcher exit={rc}; unread={[x.name for x in messages()]}; conflict wakes={len(wakes())}')
    if out.read_text().strip(): note('  watcher output: '+out.read_text().strip())
    if err.read_text().strip(): note('  watcher stderr: '+err.read_text().strip())
    if (S/'lane.pr-conflict-episode').exists(): note('  episode: '+(S/'lane.pr-conflict-episode').read_text().replace('\n',' | '))
def scenario(name,fn):
    try:
        fn(); results.append({'name':name,'result':'pass','live':True}); note('PASS '+name)
    except Exception as ex:
        results.append({'name':name,'result':'fail','live':True,'reason':str(ex)}); raise
try:
    note('Production watcher + sender + tmux/Codex endpoint. Only the external forge is a disposable fixture; no real PR or fleet data is accessed.')
    note('Oracle: author intent and recorded R1-R6 decisions; forbidden outcomes are duplicate unread messages, steering done/dead tasks, lost fallback wakes, and duplicate wakes.')
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
    note('Final durable conflict wakes:\n'+'\n'.join(wakes()))
    (E/'wake-queue.tsv').write_text((S/'.wake-queue').read_text())
    (E/'steer-binding.txt').write_text((S/'lane.pr-conflict-steer').read_text())
except Exception:
    note(traceback.format_exc())
finally:
    (E/'live-results.json').write_text(json.dumps(results,indent=2))
    shutil.copyfile(W/'forge-calls.log',E/'forge-boundary-calls.jsonl') if (W/'forge-calls.log').exists() else None
    # Leave lab teardown to the encompassing evidence turn, allowing further scenarios.
    shutil.rmtree(W)
    log.close()
if any(r['result']=='fail' for r in results): raise SystemExit(1)
