#!/usr/bin/env python3
"""Run from the gate worktree. Disposable homes only; no backend doubles.
Oracle: author intent frees cleanup sentinels only for agent-free records;
ordinary missing worktrees and uncertain/live endpoints retain admission seats.
"""
import os, json, pathlib, shutil, subprocess, time
ROOT = pathlib.Path.cwd()
EV = pathlib.Path('~/.no-mistakes/evidence/01M6555Y7KDGCNQEKYSHPK5NFS')
LAB = ROOT / '.v'
assert not LAB.exists(), 'refusing to adopt existing .v'
log = open(EV/'capacity-live.log', 'w', buffering=1)
env = dict(os.environ)
for k in list(env):
    if k.startswith('FM_') or k in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_PANE_ID','HERDR_TAB_ID','HERDR_WORKSPACE_ID','NO_MISTAKES_GATE'):
        env.pop(k)
env.update(FM_HOME=str(LAB), TMUX_TMPDIR=str(LAB/'tmux'))
server = False
results = []
def run(args, *, check=True, extra=None):
    p = subprocess.run([str(a) for a in args], env={**env, **(extra or {})}, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if p.stderr:
        log.write('stderr: '+p.stderr)
    if check and p.returncode:
        raise RuntimeError(f'{args}: exit {p.returncode}: {p.stdout}')
    return p

def meta(home, id, target, worktree):
    (home/'state'/f'{id}.meta').write_text(f'id={id}\nkind=ship\nbackend=tmux\nwindow={target}\nworktree={worktree}\npr=https://github.com/example/disposable/pull/1\n')

def state(target):
    # The real shared backend interface, with its real tmux process probes.
    p = run(['bash','-c','. bin/fm-backend.sh; fm_backend_agent_state tmux "$1"', 'probe', target])
    log.write(f'Endpoint {target}: {p.stdout}\n')
    return p.stdout.strip()

def capacity(name, lanes, free, rc, script=None):
    script = script or ROOT/'bin/fm-capacity.sh'
    report = run(['bash',script,'--json'])
    facts = json.loads(report.stdout)
    admission = run(['bash',script,'--admit'],check=False)
    log.write(f'\n{name}\n{report.stdout}--admit exit={admission.returncode}\n{admission.stdout}')
    assert (facts['lanes'],facts['free_lanes'],admission.returncode)==(lanes,free,rc), (name,facts,admission.returncode)
    results.append(dict(name=name,lanes=lanes,free_lanes=free,admit_exit=rc))
try:
    run(['bash','bin/fm-lab-home.sh','create',LAB])
    (LAB/'tmux').mkdir()
    # A real harness on a sized terminal; no model turn or credential mutation.
    run(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','primary','-n','fm-live','-x','120','-y','40','-c',ROOT,'-e',f'FM_HOME={LAB}','codex'])
    server=True
    run(['tmux','-L','fm-lab','set-window-option','-t','primary:fm-live','automatic-rename','off'])
    run(['tmux','-L','fm-lab','set-window-option','-t','primary:fm-live','allow-rename','off'])
    log.write('Real tmux inventory: '+run(['tmux','-L','fm-lab','list-windows','-t','primary','-F','#{window_id} #{window_index} #{window_name} #{pane_current_command} #{window_width}x#{window_height}']).stdout)
    env['TMUX']=run(['tmux','-L','fm-lab','display-message','-p','#{socket_path},#{pid},0']).stdout.strip()
    for _ in range(30):
        if state('primary:fm-live')=='alive':
            break
        time.sleep(.2)
    else:
        raise RuntimeError('real codex did not become alive')
    pane = run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-live']).stdout
    (EV/'codex-lab-pane.txt').write_text(pane)
    run(['tmux','-L','fm-lab','new-window','-d','-t','primary:','-n','empty','bash --noprofile --norc'])
    assert state('primary:empty')=='dead'
    assert state('primary:gone')=='missing'
    (LAB/'config/lane-capacity').write_text('5 0\n')
    (LAB/'config/machine-admission.json').write_text(json.dumps(dict(schema='fm-machine-admission.v1',memory_floor_gib=0,memory_full_avg60_max=100,disk_floor_gib=0,disk_paths=[str(LAB)])))
    mate=LAB/'mate'
    for d in ('state','config','data'):
        (mate/d).mkdir(parents=True,exist_ok=True)
    (LAB/'data/secondmates.md').write_text(f'- mate - disposable local home (home: {mate}; scope: capacity; projects: demo; added 2026-10-29)\n')
    (mate/'.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={LAB}\n')
    for n in range(11):
        home=LAB if n<6 else mate
        id=f'released-{n}'
        meta(home,id,'primary:gone',home/'state'/f'{id}.released-copy')
    # Execute the old public CLI on exactly the same records and real probes.
    shutil.copytree(ROOT/'bin',LAB/'base-bin',symlinks=True)
    base=run(['git','show','b7f4244995d98b15ea57e99b24e357c635eaa8a4:bin/fm-capacity-lib.sh']).stdout
    (LAB/'base-bin/fm-capacity-lib.sh').write_text(base)
    capacity('Before fix: eleven retained records refuse admission',11,0,75,LAB/'base-bin/fm-capacity.sh')
    capacity('Fixed: eleven cleanup-completed missing endpoints free all five lanes across local homes',0,5,0)
    meta(LAB,'dead','primary:empty',LAB/'state/dead.released-copy')
    capacity('Shell-only dead endpoint with cleanup sentinel also frees its lane',0,5,0)
    meta(LAB,'live','primary:fm-live',LAB/'state/live.released-copy')
    (LAB/'config/lane-capacity').write_text('1 0\n')
    capacity('Real live Codex agent with released-copy sentinel still fills a one-lane machine',1,0,75)
    (LAB/'state/live.meta').unlink()
    capacity('Removing live task record restores admission despite retained cleanup records',0,1,0)
    meta(LAB,'unknown','malformed-target',LAB/'state/unknown.released-copy')
    assert state('malformed-target')=='unreadable'
    capacity('Unprovable endpoint liveness retains a cleanup-sentinel lane',1,0,75)
    (LAB/'state/unknown.meta').unlink()
    cases = [
        ('ordinary',LAB/'missing-worktree'),
        ('wrong-id',LAB/'state/another-task.released-copy'),
        ('wrong-dir',mate/'state/wrong-dir.released-copy'),
        ('suffix',LAB/'state/suffix.released-copy.extra'),
    ]
    for id, path in cases:
        meta(LAB,id,'primary:gone',path)
        capacity(f'Unreleased/incorrect sentinel {id} retains a lane despite missing endpoint',1,0,75)
        (LAB/'state'/f'{id}.meta').unlink()
    capacity('Final clean admission with all eleven retained records still present',0,1,0)
    p=run(['bash',ROOT/'bin/fm-capacity.sh','--publish'])
    persisted=json.loads((LAB/'state/lane-capacity.json').read_text())
    assert persisted['lanes']==0 and persisted['free_lanes']==1
    log.write('\nPublished placement facts:\n'+p.stdout)
    (EV/'capacity-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
finally:
    if server:
        p=run(['tmux','-L','fm-lab','kill-server'],check=False)
        log.write(f'\nPrivate lab tmux kill-server exit={p.returncode}\n')
        assert p.returncode==0,p.stdout
        probe=run(['tmux','-L','fm-lab','list-sessions'],check=False)
        assert probe.returncode!=0,probe.stdout
    shutil.rmtree(LAB)
    log.write('Disposable lab and baseline copy removed.\n')
    log.close()
print('Live capacity scenarios completed; evidence retained in capacity-live.log and capacity-live-results.json')
