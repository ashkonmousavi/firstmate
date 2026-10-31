import os, sys, json, subprocess, pathlib, shutil, time, signal
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M69TB417C7GV2DXZDSXZCFBW')
D=ROOT/'.test-tmp'/'live-scale'
D.mkdir()
H=D/'home'
HELP=ROOT/'bin/fm-herdr-lab.sh'
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k.startswith('HERDR_') or k in ('TMUX','TMUX_PANE'):
        env.pop(k)
env.update(TMPDIR=str(ROOT/'.test-tmp'),FM_HERDR_LAB_STATE_DIR=str(D/'lab-state'))
real=shutil.which('herdr')
session=subprocess.check_output([str(HELP),'name','cleanup-scale'],env=env,text=True).strip()
report={'session':session,'oracle':'docs/herdr-backend.md: Startup cleanup of restored projections; author workload 59 workspaces / 83 journals, cleanup target <30 seconds','results':[]}
def run(args,**kw):
    r=subprocess.run([str(x) for x in args],env=env,text=True,capture_output=True,**kw)
    if r.returncode: print(r.stdout+r.stderr,flush=True)
    r.check_returncode()
    return r
def lab(*args):
    r=run([HELP,'run',session,*args])
    return json.loads(r.stdout) if r.stdout.strip() else {}
def save(name,value):
    (E/name).write_text(json.dumps(value,indent=2)+'\n')
def record(name,**kw):
    row=dict(name=name,**kw); report['results'].append(row); print(json.dumps(row),flush=True); save('live-cleanup-report.json',report)
def journals():
    return {p.name:p.read_bytes() for p in (H/'state').glob('*.herdr-presentation')}
def snapshot():
    return lab('api','snapshot')['result']['snapshot']
def topology(s):
    keys={'workspaces':['workspace_id','label','focused','active_tab_id','tab_count','pane_count'],'tabs':['tab_id','workspace_id','label','focused','pane_count'],'panes':['pane_id','tab_id','workspace_id','focused']}
    return {kind:[{k:x[k] for k in fields} for x in s[kind]] for kind,fields in keys.items()} | {'focus':focus(s),'layouts':s['layouts']}
def focus(s):
    return [s['focused_workspace_id'],s['focused_tab_id'],s['focused_pane_id']]
def journal(i): return H/'state'/f'case{i}.herdr-presentation'
def token(i): return f'Scale{i:017d}'
def title(i): return f'└ case{i} · p:{token(i)}'
def v1(i): journal(i).write_text(f'version=1\ntask_id=case{i}\nprojection_id={token(i)}\n')
def v2(i,**overrides):
    w=ws[i]
    fields=dict(version='2',task_id=f'case{i}',projection_id=token(i),home=str(H),session=session,workspace_id=w['workspace']['workspace_id'],tab_id=w['tab']['tab_id'],pane_id=w['root_pane']['pane_id'],parent_workspace_id=anchor['workspace']['workspace_id'],parent_label='captain-anchor',workspace_label=title(i),task_label=f'fm-case{i}')
    fields.update(overrides)
    journal(i).write_text(''.join(f'{k}={v}\n' for k,v in fields.items()))
def cleanup(name,source=ROOT/'bin/fm-herdr-session-cleanup.sh',bound=30):
    e=env.copy(); e.update(FM_HOME=str(H),FM_BACKEND='herdr',HERDR_SESSION=session,PATH=str(D/'transport')+':'+env['PATH'])
    # The caller owns the isolated home lock before invoking the documented cleanup command.
    (H/'state/.lock').write_text(str(os.getpid())+'\n')
    start=time.monotonic()
    try:
        child=subprocess.Popen([str(source)],env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        out,err=child.communicate(timeout=bound)
        r=subprocess.CompletedProcess(child.args,child.returncode,out,err)
        elapsed=time.monotonic()-start
        (E/(name+'.log')).write_text(r.stdout+r.stderr)
        assert r.returncode==0,(name,r.returncode,r.stderr)
        return elapsed
    except subprocess.TimeoutExpired as x:
        os.killpg(child.pid,signal.SIGKILL)
        out,err=child.communicate()
        (E/(name+'.log')).write_text(out+err+f'\nTimed out after {bound} seconds; owned process group terminated and awaited\n')
        raise
provisioned=False
try:
    run([ROOT/'bin/fm-lab-home.sh','create',H])
    (H/'config/backend').write_text('herdr\n')
    (H/'config/herdr-presentation-spaces').touch()
    (D/'transport').mkdir()
    wrapper=D/'transport/herdr'
    wrapper.write_text('''#!/usr/bin/env bash
set -eu
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[n-2]}" = --session ] && [ "${args[n-1]}" = "$LAB_SESSION" ]; then
  unset 'args[n-1]' 'args[n-2]'
fi
for a in "${args[@]}"; do case "$a" in --session|--session=*) exit 9;; esac; done
if [ "${args[0]:-}" = --version ]; then exec env PATH="$LAB_REAL_PATH" "$LAB_REAL_HERDR" --version --session "$LAB_SESSION"; fi
if [ "${args[0]:-}" = api ] && [ "${args[1]:-}" = snapshot ] && [ -n "${LAB_RACE_JOURNAL:-}" ] && [ ! -f "$LAB_RACE_JOURNAL" ]; then
  env PATH="$LAB_REAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "${args[@]}"
  printf 'version=1\\ntask_id=fm-case1\\nprojection_id=%s\\n' "$LAB_RACE_TOKEN" > "$LAB_RACE_JOURNAL.tmp"
  mv "$LAB_RACE_JOURNAL.tmp" "$LAB_RACE_JOURNAL"
  exit 0
fi
exec env PATH="$LAB_REAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "${args[@]}"
''')
    wrapper.chmod(0o755)
    env.update(LAB_SESSION=session,LAB_REAL_PATH=env['PATH'],LAB_REAL_HERDR=real,LAB_HELPER=str(HELP))
    run([HELP,'provision',session]); provisioned=True
    save('live-herdr-status.json',lab('status','--json'))
    initial=lab('workspace','list')['result']['workspaces']
    assert not initial,initial
    anchor=lab('workspace','create','--cwd',str(ROOT),'--label','captain-anchor','--focus')['result']
    a=dict(workspace_id=anchor['workspace']['workspace_id'],active_tab_id=anchor['tab']['tab_id'])
    ws={}
    for i in range(1,59):
        ws[i]=lab('workspace','create','--cwd',str(ROOT),'--label',title(i),'--no-focus')['result']
    for i in range(1,41):
        v2(i); (H/'state'/f'case{i}.meta').touch()
    for i in range(100,143): v1(i)
    before=snapshot(); before_j=journals()
    assert len(before['workspaces'])==59 and len(before_j)==83
    save('scale-before.json',before)
    elapsed=cleanup('scale-indexed-no-candidate')
    after=snapshot()
    save('scale-after.json',after)
    assert before_j==journals() and topology(before)==topology(after)
    record('59 workspaces and 83 journals: no eligible pane, unchanged layout and journals',seconds=elapsed,workspaces=59,journals=83,result='pass')
    # Reproduce the old executable on identical live data, without editing target code.
    baseline=D/'baseline'
    shutil.copytree(ROOT/'bin',baseline/'bin')
    for path in ['bin/fm-herdr-session-cleanup.sh','bin/backends/herdr.sh']:
        data=subprocess.check_output(['git','show','4220467f622e1095bae46961814f305d27418b97:'+path])
        (baseline/path).write_bytes(data)
    try:
        old=cleanup('scale-base-no-candidate',baseline/'bin/fm-herdr-session-cleanup.sh',bound=100)
        assert before_j==journals() and topology(before)==topology(snapshot())
        record('Base commit comparison on identical live 59/83 workload',seconds=old,speedup=old/elapsed,result='measured')
    except subprocess.TimeoutExpired:
        record('Base commit comparison on identical live 59/83 workload',seconds_at_least=100,result='timeout')
    # 18 adversarial projected workspaces. Reuse filler journals to retain 83 total.
    for i in range(41,59):
        journal(100+i-41).unlink(); v1(i)
    v1(42)
    (H/'state/fm-case42.herdr-presentation').write_text(f'version=1\ntask_id=fm-case42\nprojection_id={token(42)}\n')
    journal(118).unlink()
    with journal(43).open('ab') as f: f.write(f'projection_id={token(43)}'.encode())
    with journal(44).open('ab') as f: f.write(b'\0\n')
    (D/'other-home').mkdir(); v2(45,home=str(D/'other-home'))
    v2(46,session='fm-lab-other-session')
    v2(47,pane_id=ws[48]['root_pane']['pane_id'])
    journal(48).rename(D/'symlink-target'); journal(48).symlink_to(D/'symlink-target')
    lab('tab','create','--workspace',ws[49]['workspace']['workspace_id'],'--cwd',str(ROOT),'--label','human-extra-tab','--no-focus')
    lab('pane','split',ws[50]['root_pane']['pane_id'],'--direction','right','--no-focus')
    lab('pane','run',ws[51]['root_pane']['pane_id'],'sleep 300')
    lab('pane','run',ws[52]['root_pane']['pane_id'],'sleep 300 &')
    lab('workspace','rename',ws[54]['workspace']['workspace_id'],title(53))
    lab('workspace','rename',ws[55]['workspace']['workspace_id'],f'└ malformed p:{token(55)}')
    lock=H/'state/.spawn-case56.lock'; lock.mkdir(); (lock/'pid').write_text(str(os.getpid())+'\n')
    # Active exact target is protected. Only case41 is independently eligible.
    lab('tab','focus',ws[57]['tab']['tab_id'])
    # Keep case58 for a separate exact-v2 positive proof.
    (H/'state/case58.meta').touch()
    before=snapshot(); before_j=journals()
    assert len(before['workspaces'])==59 and len(before_j)==83
    save('safety-before.json',before)
    elapsed=cleanup('scale-one-candidate-and-safety')
    after=snapshot(); save('safety-after.json',after)
    assert focus(before)==focus(after)
    expected=[w for w in before['workspaces'] if w['workspace_id']!=ws[41]['workspace']['workspace_id']]
    assert {w['workspace_id'] for w in after['workspaces']}=={w['workspace_id'] for w in expected}
    for kind,key in [('panes','pane_id'),('tabs','tab_id')]:
        removed={x[key] for x in before[kind]}-{x[key] for x in after[kind]}
        wanted=ws[41]['root_pane']['pane_id'] if kind=='panes' else ws[41]['tab']['tab_id']
        assert removed=={wanted},(kind,removed,wanted)
    before_j.pop('case41.herdr-presentation')
    assert before_j==journals()
    record('59/83 mixed workload: close exactly one stale v1 pane; preserve active target, metadata, duplicates, binary/unterminated journals, cross-home/session/endpoint, symlink, extra tab/pane, foreground/background jobs, malformed title and busy task lock',seconds=elapsed,remaining_workspaces=len(after['workspaces']),remaining_journals=len(journals()),focus=focus(after),result='pass')
    lab('tab','focus',a['active_tab_id'])
    (H/'state/case58.meta').unlink(); v2(58)
    before=snapshot(); before_j=journals()
    elapsed=cleanup('exact-v2-candidate')
    after=snapshot()
    assert focus(before)==focus(after)
    assert {w['workspace_id'] for w in before['workspaces']}-{w['workspace_id'] for w in after['workspaces']}=={ws[58]['workspace']['workspace_id'],ws[57]['workspace']['workspace_id']}
    # case57 becomes eligible when no longer active and is correctly retired too.
    before_j.pop('case58.herdr-presentation'); before_j.pop('case57.herdr-presentation')
    assert before_j==journals()
    record('Exact v2 binding closes; previously active v1 pane closes only after focus leaves',seconds=elapsed,focus=focus(after),result='pass')
    (H/'state/case1.meta').unlink()
    env.update(LAB_RACE_JOURNAL=str(H/'state/fm-case1.herdr-presentation'),LAB_RACE_TOKEN=token(1))
    before=snapshot(); before_j=journals()
    elapsed=cleanup('late-duplicate-revalidation')
    after=snapshot(); save('late-duplicate-after.json',after)
    assert topology(before)==topology(after)
    duplicate=f'version=1\ntask_id=fm-case1\nprojection_id={token(1)}\n'.encode()
    before_j['fm-case1.herdr-presentation']=duplicate
    assert before_j==journals()
    record('Duplicate journal published after discovery but during the real locked snapshot prevents stale-index closure',seconds=elapsed,result='pass')
    env.pop('LAB_RACE_JOURNAL'); env.pop('LAB_RACE_TOKEN')
    before=snapshot(); before_j=journals()
    elapsed=cleanup('mixed-idempotent-repeat')
    assert topology(before)==topology(snapshot()) and before_j==journals()
    record('Repeated mixed cleanup is idempotent for every preserved guard',seconds=elapsed,result='pass')
finally:
    if provisioned:
        r=subprocess.run([str(HELP),'teardown',session],env=env,text=True,capture_output=True)
        (E/'scale-lab-teardown.log').write_text(r.stdout+r.stderr)
        report['teardown_exit']=r.returncode
        save('live-cleanup-report.json',report)
        if r.returncode: print(r.stderr,file=sys.stderr)
        assert r.returncode==0,'lab teardown failed'
    if not provisioned or report.get('teardown_exit')==0: shutil.rmtree(D)
