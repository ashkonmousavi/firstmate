import os, pathlib, subprocess, tempfile, shutil, shlex, json
root = pathlib.Path.cwd()
evidence = pathlib.Path('~/.no-mistakes/evidence/01M6GJF4V85S3X2HN730V9H54K')
base = pathlib.Path(tempfile.mkdtemp(prefix='.hold-live-', dir=root))
log = (evidence/'live-hold-transcript.log').open('w', buffering=1)
env = dict(os.environ)
for key in list(env):
    if key.startswith(('FM_', 'TASKS_AXI_', 'HERDR_')) or key in ('TMUX', 'NO_MISTAKES_GATE'):
        env.pop(key, None)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(base))

def run(home, script, *args, ok=0, extra=None):
    child_env = dict(env, FM_HOME=str(home))
    child_env.update(extra or {})
    cmd = ['bash', str(root/'bin'/script), *map(str, args)]
    result = subprocess.run(cmd, env=child_env, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    log.write('$ FM_HOME='+str(home)+' '+shlex.join(cmd)+'\n'+result.stdout+f'[exit {result.returncode}]\n')
    assert result.returncode == ok, (cmd, result.returncode, result.stdout)
    return result.stdout

def axi(home, *args, **kw): return run(home, 'fm-tasks-axi.sh', *args, **kw)
def captain(home, *args, **kw): return run(home, 'fm-captain-hold.sh', *args, **kw)
def home(name):
    p=base/name
    run(p, 'fm-lab-home.sh', 'create', p)
    (p/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 100\n')
    (p/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    return p

def snapshot(h):
    return {str(p.relative_to(h)): p.read_bytes() for p in [h/'data/backlog.md', *list((h/'state/hold-releases').glob('*'))] if p.is_file() and not p.name.endswith('.lock')}

def mark(name): log.write('\nSCENARIO PASS: '+name+'\n\n')
try:
    main=home('main'); peer=home('peer home with spaces')
    for h in (main, peer):
        for task in ('target', 'writer', 'finished', 'shadow'):
            axi(h,'add',task,task,'--repo','demo')
        axi(h,'done','finished')
    axi(peer,'done','shadow')
    (main/'data/secondmates.md').write_text(f'- peer - Test peer (home: {peer}; scope: tests; projects: demo; added 2026-11-03)\n')
    condition='marker:'+str(main/'ready')
    for kind in ('task','captain'):
        def hold(reason, task='target', **kw):
            if kind=='task': return axi(main,'hold',task,'--reason',reason,'--kind','external','--release-on',condition,**kw)
            return captain(main,'hold',task,'--title',task,'--repo','demo','--origin','writer','--reason',reason,'--release-on',condition,**kw)
        for reason in ('no writer', 'writer: finished', 'writer: absent', 'writer: MAIN', 'rewriter: writer', 'writer: writer/bad', 'writer: peer:finished', 'writer: peer:shadow', 'writer: nowhere:writer'):
            before=snapshot(main)
            output=hold(reason, ok=2 if kind=='task' else 1)
            assert 'a marker hold names its writer task' in output
            assert before == snapshot(main), 'Refusal changed persisted hold/backlog'
        mark(kind+' refuses missing, done, malformed, unregistered and wrong-home writer without mutation')
        for reason in ('writer: writer', 'awaiting activation; writer: peer:writer'):
            hold(reason)
            shown=axi(main,'show','target')
            assert '  held: yes\n' in shown and json.loads(shown.split('  hold_release_on: ',1)[1].splitlines()[0]) == condition
            before=snapshot(main)
            hold('writer: absent', ok=2 if kind=='task' else 1)
            assert before == snapshot(main), 'Invalid re-hold changed persisted episode'
            axi(main,'unhold','target')
            assert not (main/'state/hold-releases/target').exists()
        mark(kind+' accepts local and cross-home open writer; invalid re-hold preserves episode; unhold clears cache')
        if kind=='captain':
            hold('no writer', task='absent', ok=1)
            assert 'NOT_FOUND' in axi(main,'show','absent',ok=1)
            mark('captain invalid marker writer does not create a task')
    # Done then reopened writer is accepted, but a qualified reference must read the peer.
    axi(peer,'reopen','shadow')
    axi(main,'hold','target','--reason','writer: peer:shadow','--release-on',condition)
    axi(main,'unhold','target')
    mark('reopened cross-home writer is open and can author a marker')
    for fn in (axi,captain):
        extras=['--origin','writer'] if fn==captain else ['--kind','external']
        fn(main,'hold','target','--reason','PR produces the event','--release-on','pr:owner/repo#42',*extras)
        assert '  held: yes\n' in axi(main,'show','target')
        axi(main,'unhold','target')
        fn(main,'hold','target','--reason','deferred','--until','2099-01-01',*extras)
        axi(main,'unhold','target')
    captain(main,'hold','target','--reason','a decision','--origin','writer')
    axi(main,'unhold','target')
    mark('PR and date holds do not need writers; captain conditionless hold remains available')
    # Marker event itself, evaluated with the real library and no mock show or process boundary.
    axi(main,'hold','target','--reason','writer: peer:writer','--release-on',condition)
    (main/'ready').touch()
    expr='source "$1/bin/fm-hold-release-lib.sh"; fm_hold_release_evaluate "$FM_HOME/state"'
    proc=subprocess.run(['bash','-c',expr,'_',str(root)],env=dict(env,FM_HOME=str(main)),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
    log.write('$ fm_hold_release_evaluate '+str(main/'state')+'\n'+proc.stdout+f'[exit {proc.returncode}]\n')
    assert proc.returncode==0 and 'hold condition met: target '+condition in proc.stdout
    shown=axi(main,'show','target'); assert '  held: yes\n' in shown
    log.write('Persisted decision event:\n'+(main/'state/target.status').read_text())
    mark('present marker publishes a decision while keeping the task held')
    log.write('All direct CLI scenarios completed successfully.\n')
finally:
    shutil.rmtree(base)
    log.write('Disposable homes removed.\n')
    log.close()
