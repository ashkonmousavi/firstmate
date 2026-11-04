#!/usr/bin/env python3
"""Reproducible CLI exercise: real tmux and Claude, disposable Firstmate homes.
Oracle: dead+explicit-empty is vacant; alive/uncertain holds; placement is advisory.
"""
import json, os, pathlib, shlex, shutil, subprocess, tempfile, time
ROOT = pathlib.Path('~/.no-mistakes/worktrees/049a88734b0e/01M6JCBKW17X5BMNY1G2F12DMV')
EVIDENCE = pathlib.Path('~/.no-mistakes/evidence/01M6JCBKW17X5BMNY1G2F12DMV')
lab = pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.', dir=ROOT/'.test-phase-tmp'))
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'HERDR_', 'REX_', 'TASKS_AXI_')) or key in ('TMUX','TMUX_PANE','CLAUDECODE','NO_MISTAKES_GATE'):
        env.pop(key, None)
env.update(FM_HOME=str(lab), FM_BACKEND='tmux')
log = (EVIDENCE/'live-cli-transcript.txt').open('w', buffering=1)
socket_dir = None
results = []
def run(args, *, expected=0, show=True, localenv=None, timeout=40):
    p = subprocess.run([str(x) for x in args], cwd=ROOT, env=localenv or env,
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if show:
        log.write('$ '+shlex.join([str(x) for x in args])+'\n')
        log.write(p.stdout)
        if p.stderr: log.write('stderr: '+p.stderr)
        log.write(f'[exit {p.returncode}]\n\n')
    if expected is not None:
        assert p.returncode == expected, f'{args}: expected {expected}, got {p.returncode}: {p.stderr}'
    return p

def tmux(*args, **kw): return run(['tmux','-L','fm-lab',*args], **kw)
def cli(*args, **kw): return run(['bash', ROOT/'bin'/args[0], *args[1:]], **kw)
def meta(name, **fields):
    path=lab/'state'/f'{name}.meta'
    path.write_text(''.join(f'{k}={v}\n' for k,v in dict(kind='ship',backend='tmux',window='lab-control:absent',**fields).items()))
    return path

def record(name):
    results.append({'name':name,'result':'pass','live':True,'evidence':'live-cli-transcript.txt','reason':''})
    log.write('SCENARIO PASSED: '+name+'\n\n')

try:
    cli('fm-lab-home.sh','create',lab)
    socket_dir=cli('fm-lab-home.sh','tmux-dir',lab).stdout.strip()
    env['TMUX_TMPDIR']=socket_dir
    (lab/'config'/'supervision-host-off').touch()
    (lab/'config'/'lane-capacity').write_text('8 0\n')
    policy={'schema':'fm-machine-admission.v1','memory_floor_gib':0,'memory_full_avg60_max':100,'disk_floor_gib':0,'disk_paths':[str(lab)]}
    (lab/'config'/'machine-admission.json').write_text(json.dumps(policy))
    (lab/'data'/'secondmates.md').write_text('')
    tmux('new-session','-d','-x','120','-y','35','-s','lab-control','-n','control','-c',ROOT,'bash --noprofile --norc')
    tmux('new-session','-d','-x','120','-y','35','-s','primary','-n','claude','-c',ROOT,'-e',f'FM_HOME={lab}','claude')
    socket=tmux('display-message','-p','-t','lab-control:control','#{socket_path}',show=False).stdout.strip()
    env['TMUX']=socket+',0,0'
    live=meta('live',window_override='unused')
    live.write_text('kind=ship\nbackend=tmux\nwindow=primary:claude\nworktree=\n')
    for attempt in range(60):
        p=cli('fm-lane-release.sh','read-evidence','agent',live,'live',show=False)
        if p.stdout.strip() == 'alive': break
        time.sleep(.5)
    else: raise AssertionError('Real Claude did not reach alive state: '+p.stdout)
    cli('fm-lane-release.sh','read-evidence','agent',live,'live')
    cli('fm-lane-release.sh','read-evidence','seat',live,'live',expected=0)
    tmux('capture-pane','-p','-t','primary:claude')
    # Original failure class: arbitrarily many historical records must add zero.
    for n in range(96): meta(f'gone-{n}', worktree='')
    gone=lab/'state'/'gone-0.meta'
    cli('fm-lane-release.sh','read-evidence','agent',gone,'gone-0')
    cli('fm-lane-release.sh','read-evidence','seat',gone,'gone-0',expected=1)
    facts=json.loads(cli('fm-capacity.sh','--json').stdout)
    assert facts['lanes']==1 and facts['free_lanes']==7 and facts['admitted']
    cli('fm-capacity.sh','--admit')
    cli('fm-fleet-view.sh','--capacity')
    ledger=json.loads(cli('fm-fleet-ledger.sh','capacity','--json').stdout)
    assert ledger['lanes']==1 and ledger['free_lanes']==7
    record('96 missing endpoints with explicitly empty copies free seats; a real live Claude endpoint still holds its seat')
    # A present bare shell is proven dead too, rather than just a missing target.
    dead=meta('dead-shell',worktree='')
    dead.write_text('kind=scout\nbackend=tmux\nwindow=lab-control:control\nworktree=\n')
    assert cli('fm-lane-release.sh','read-evidence','agent',dead,'dead-shell').stdout.strip()=='dead'
    cli('fm-lane-release.sh','read-evidence','seat',dead,'dead-shell',expected=1)
    assert json.loads(cli('fm-capacity.sh','--json').stdout)['lanes']==1
    record('A remaining shell with no agent and an explicitly cleared copy is known vacant')
    # Adversarial evidence: unknown backend, absent worktree key, missing directory,
    # malformed endpoint and an unrelated real process all retain conservative seats.
    unknown=meta('unknown',worktree='')
    unknown.write_text('kind=scout\nbackend=unverified\nwindow=lab-control:absent\nworktree=\n')
    absent=meta('absent-field')
    missing=meta('missing-directory',worktree=str(lab/'does-not-exist'))
    malformed=meta('bad-target',worktree='')
    malformed.write_text('kind=ship\nbackend=tmux\nwindow=invalid-target\nworktree=\n')
    tmux('new-window','-d','-t','lab-control','-n','ambiguous','-c',ROOT,'sleep 300')
    ambiguous=meta('ambiguous',worktree='')
    ambiguous.write_text('kind=ship\nbackend=tmux\nwindow=lab-control:ambiguous\nworktree=\n')
    for name in ('unknown','absent-field','missing-directory','bad-target','ambiguous'):
        path=lab/'state'/f'{name}.meta'
        cli('fm-lane-release.sh','read-evidence','agent',path,name)
        cli('fm-lane-release.sh','read-evidence','seat',path,name,expected=2)
    assert json.loads(cli('fm-capacity.sh','--json').stdout)['lanes']==6
    record('Unknown, ambiguous and unreadable endpoints, absent worktree fields and nonexistent directories all retain seats')
    for name in ('unknown','absent-field','missing-directory','bad-target','ambiguous'):
        (lab/'state'/f'{name}.meta').unlink()
    # Retained real process cwd continues to protect a nonempty worktree record.
    retained=lab/'retained-copy'; retained.mkdir()
    tmux('new-window','-d','-t','lab-control','-n','retained','-c',retained,'sleep 300')
    retained_meta=meta('retained',worktree=str(retained))
    cli('fm-lane-release.sh','read-evidence','seat',retained_meta,'retained',expected=0)
    assert json.loads(cli('fm-capacity.sh','--json').stdout)['lanes']==2
    tmux('kill-window','-t','lab-control:retained')
    for attempt in range(15):
        p=cli('fm-lane-release.sh','read-evidence','seat',retained_meta,'retained',expected=None,show=False)
        if p.returncode==1: break
        time.sleep(.2)
    cli('fm-lane-release.sh','read-evidence','seat',retained_meta,'retained',expected=1)
    assert json.loads(cli('fm-capacity.sh','--json').stdout)['lanes']==1
    record('A real process in a retained copy keeps a seat until that process stops')
    retained_meta.unlink()
    # Build remote publications through the actual publisher in a second lab home.
    remote=lab/'remote'; remote.mkdir()
    cli('fm-lab-home.sh','create',remote)
    (remote/'config'/'lane-capacity').write_text('4 0\n')
    (remote/'config'/'machine-admission.json').write_text(json.dumps({**policy,'disk_paths':[str(remote)]}))
    (remote/'data'/'secondmates.md').write_text('')
    remote_env={**env,'FM_HOME':str(remote)}
    published=json.loads(cli('fm-capacity.sh','--publish',localenv=remote_env).stdout)
    assert published['free_lanes']==4
    # A fetched machine name is protocol input; use whitespace and slash to check encoding.
    published['machine']='lab laptop/West'
    remote_facts=lab/'remote.json'; remote_facts.write_text(json.dumps(published))
    other={**published,'machine':'less-room','target':2,'free_lanes':2}
    other_file=lab/'other.json'; other_file.write_text(json.dumps(other))
    (lab/'config'/'lane-capacity').write_text('1 0\n')
    full=json.loads(cli('fm-capacity.sh','--json').stdout)
    assert full['reason']=='full' and full['free_lanes']==0
    p=cli('fm-capacity.sh','--admit','--machine-facts',other_file,'--machine-facts',remote_facts,expected=75)
    assert 'placement=lab%20laptop%2FWest placement_free_lanes=4' in p.stdout.splitlines()[0]
    assert 'free_lanes=0 reason=full lanes=1 target=1' in p.stdout.splitlines()[0]
    winner=json.loads(cli('fm-place.sh','--json',other_file,remote_facts).stdout)
    assert winner['machine']==published['machine'] and winner['free_lanes']==4
    assert 'Placement: lab laptop/West (4 lanes free' in cli('fm-place.sh',other_file,remote_facts).stdout
    record('A full local machine advises the best supplied fresh publication with an encoded name while local admission remains refused')
    # Malformed or stale publications must not lend authority to local admission.
    bad_files=[]
    for name,change in [('stale',{'generated_epoch':1}),('future',{'generated_epoch':int(time.time())+3600}),('full',{'free_lanes':0,'lanes':4,'reason':'full','admitted':False}),('unreadable',{'readable':False}),('inconsistent',{'free_lanes':3})]:
        path=lab/f'{name}.json'; path.write_text(json.dumps({**published,**change})); bad_files.append(path)
    malformed_file=lab/'malformed.json'; malformed_file.write_text('{invalid'); bad_files += [malformed_file,lab/'missing.json']
    opts=[item for f in bad_files for item in ('--machine-facts',f)]
    p=cli('fm-capacity.sh','--admit',*opts,expected=75)
    assert 'placement=' not in p.stdout
    cli('fm-place.sh','--json',*bad_files,expected=75)
    mixed=cli('fm-capacity.sh','--admit',*opts,'--machine-facts',remote_facts,expected=75)
    assert 'placement=lab%20laptop%2FWest' in mixed.stdout
    record('Stale, future, full, unreadable, malformed, inconsistent and missing publications cannot advertise room; a valid peer still qualifies')
    (lab/'config'/'lane-capacity').write_text('8 0\n')
    p=cli('fm-capacity.sh','--machine-facts',remote_facts)
    assert 'placement=' not in p.stdout
    json_report=json.loads(cli('fm-capacity.sh','--machine-facts',remote_facts,'--json').stdout)
    assert json_report['lanes']==1 and json_report['free_lanes']==7 and 'placement' not in json_report
    cli('fm-capacity.sh','--machine-facts',expected=2)
    cli('fm-capacity.sh','--json','--admit',expected=2)
    record('Local room suppresses the remote hint; JSON stays compatible and invalid arguments fail with usage status')
finally:
    if socket_dir:
        tmux('kill-server',expected=None)
        cli('fm-lab-home.sh','teardown',lab)
        log.write('CLEANUP: private tmux server stopped; socket directory removed.\n')
    shutil.rmtree(lab)
    log.write('CLEANUP: disposable lab homes removed.\n')
    (EVIDENCE/'live-scenario-results.json').write_text(json.dumps(results,indent=2)+'\n')
    log.close()
print(json.dumps(results,indent=2))
