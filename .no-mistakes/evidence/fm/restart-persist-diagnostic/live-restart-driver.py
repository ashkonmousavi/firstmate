import os, pathlib, subprocess, json, time, hashlib
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6DT06J8Z2BFSHPD3NGJXK0H')
home=root/'.lv/home'
sockdir=(root/'.lv/socket-dir').read_text().strip()
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') and (key.endswith('_OVERRIDE') or key=='FM_GATE_REFUSE_BYPASS'):
        env.pop(key)
env.update(FM_HOME=str(home),FM_BACKEND='tmux',TMUX_TMPDIR=sockdir,TMUX=f'{sockdir}/tmux-{os.getuid()}/fm-lab,0,0',FM_SECONDMATE_PERSIST_WAIT='0',FM_SECONDMATE_PERSIST_POLL='1')
transcript=[]
results=[]
def run(args, **kwargs):
    p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,**kwargs)
    transcript.append('$ '+' '.join(args)+'\n'+p.stdout+f'\n[exit {p.returncode}]\n')
    return p

def meta(h,wt):
    (h/'state/probe.meta').write_text(f'window=primary:fm-probe\nbackend=tmux\nendpoint_task_id=probe\nworktree={wt}\nproject={wt}\nharness=codex\nkind=secondmate\nmode=secondmate\nyolo=off\nhome={h}\n')

def pid():
    return run(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{pane_pid} #{pane_current_command}']).stdout.strip()

meta(home, root)
initial=pid()
assert initial.endswith(' codex'),initial
sentinel=home/'data/open-work.txt'
sentinel.write_text('Existing open work must survive a diagnostic-only restart attempt.\n')
original=sentinel.read_bytes()
(home/'state/probe.inbox').write_text('Deliberately block directory creation for a real inbox refusal.\n')
direct=run(['bash','bin/fm-send.sh','probe','Diagnostic setup probe'])
assert direct.returncode!=0,direct.stdout
assert 'WATCHER' in direct.stdout or 'WARNING:' in direct.stdout or '●' in direct.stdout,direct.stdout
assert 'error: ' in direct.stdout,direct.stdout
p=run(['bash','bin/fm-secondmate-restart.sh','probe'])
assert p.returncode==3,p.stdout
assert 'could not be delivered:' in p.stdout and 'could not be delivered either:' in p.stdout,p.stdout
assert 'inbox' in p.stdout and '●' not in p.stdout,p.stdout
assert 'restarted:' not in p.stdout and pid()==initial and sentinel.read_bytes()==original
results.append({'name':'Real inbox failures after supervision banners expose underlying errors for persist and nudge','pass':True,'output':p.stdout})
(home/'state/probe.inbox').unlink()
p=run(['bash','bin/fm-secondmate-restart.sh','probe'])
assert p.returncode==3 and p.stdout.startswith('nudged: probe:'),p.stdout
records=sorted((home/'state/probe.inbox').glob('*.msg'))
assert len(records)==2,records
bodies=[f.read_text() for f in records]
assert any('Open-record persistence' in b for b in bodies),bodies
assert any('re-read' in b.lower() or 'reread' in b.lower() for b in bodies),bodies
assert pid()==initial and sentinel.read_bytes()==original
for f in records:
    transcript.append(f'Persisted public inbox record {f.name}:\n{f.read_text()}\n')
result={'name':'Unanswered persist durably queues both requests without replacing the real Codex process','pass':True,'pid_before_after':initial,'records':[f.name for f in records],'output':p.stdout}
results.append(result)
# A long real filesystem error also checks the accepted removal of the length cap.
longhome=root/'.lv'/('a'*180)/('b'*180)/('c'*180+'\t\x01suffix')
p=run(['bash','bin/fm-lab-home.sh','create',str(longhome)])
assert p.returncode==0,p.stdout
meta(longhome, root)
(longhome/'state/probe.inbox').write_text('blocked\n')
env['FM_HOME']=str(longhome)
p=run(['bash','bin/fm-secondmate-restart.sh','probe'])
assert p.returncode==3,p.stdout
assert 'could not be delivered:' in p.stdout and 'could not be delivered either:' in p.stdout,p.stdout
assert len(p.stdout.splitlines()[0])>512,p.stdout
assert 'suffix/state/probe.inbox' in p.stdout,p.stdout
assert all(ord(c)>=32 or c=='\n' for c in p.stdout),repr(p.stdout)
assert '\t' not in p.stdout and '\x01' not in p.stdout
assert pid()==initial and sentinel.read_bytes()==original
results.append({'name':'Long underlying errors remain complete and printable on one report line','pass':True,'report_line_length':len(p.stdout.splitlines()[0]),'output':p.stdout})
env['FM_HOME']=str(home)
# Exercise a real correlated acknowledgement and a real pre-stop refusal.
meta(home,root/'.lv/missing-worktree')
env['FM_SECONDMATE_PERSIST_WAIT']='20'
p=subprocess.Popen(['bash','bin/fm-secondmate-restart.sh','probe'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
try:
    corr=None
    deadline=time.monotonic()+18
    while time.monotonic()<deadline:
        for f in (home/'state/pending-replies').glob('*'):
            if not f.is_file(): continue
            fields=dict(line.split('=',1) for line in f.read_text().splitlines() if '=' in line)
            if fields.get('task_id')=='probe' and fields.get('delivered_epoch') and fields.get('corr_id') not in set():
                # The newest inbox record carries the current public correlation.
                newest=max((home/'state/probe.inbox').glob('*.msg'),key=lambda x:x.stat().st_mtime_ns)
                if fields.get('corr_id') in newest.read_text() and newest.name not in result['records']:
                    corr=fields['corr_id'];break
        if corr: break
        time.sleep(.1)
    assert corr,'No newly delivered persist request'
    with (home/'state/probe.status').open('a') as f:
        f.write(f'done [corr={corr}]: disposable lab open records persisted; exercise pre-stop refusal\n')
    out=p.communicate(timeout=30)[0]
    transcript.append('$ bash bin/fm-secondmate-restart.sh probe (real acknowledged persist; missing worktree)\n'+out+f'\n[exit {p.returncode}]\n')
    assert p.returncode==3 and 'the restart outcome is unknown:' in out,out
    assert 'worktree' in out and '●' not in out,out
    assert pid()==initial and sentinel.read_bytes()==original
    results.append({'name':'Acknowledged persist reaches real relaunch refusal and reports its underlying reason without a restart claim','pass':True,'output':out})
finally:
    if p.poll() is None:
        p.terminate();p.communicate(timeout=5)
(evidence/'live-restart-transcript.log').write_text('\n'.join(transcript))
(evidence/'live-restart-results.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))
