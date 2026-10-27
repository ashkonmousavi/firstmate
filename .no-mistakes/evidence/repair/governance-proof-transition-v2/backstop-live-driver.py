import json, os, pathlib, subprocess, sys, tempfile, time
root = pathlib.Path(sys.argv[1])
env = dict(os.environ)
for k in ['FM_HOME','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
    env.pop(k, None)

def setup(base):
    home = base / 'home'
    subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(home)], check=True, capture_output=True)
    (home/'config').chmod(0o700)
    (home/'state/example.meta').touch()
    (home/'data/main-pane').write_text('saved-pane-must-survive\n')
    beat = home/'state/.last-watcher-beat'
    beat.touch()
    os.utime(beat,(time.time()-600,)*2)
    return home, home/'config/main-backstop-send-enabled'

def invoke(home, cap):
    argv = ['python3',str(root/'bin/fm-main-backstop.py'),'--home',str(home),'--code-root',str(root),'--send-enabled-file',str(cap)]
    started=time.monotonic()
    p=subprocess.run(argv,env=env,text=True,capture_output=True,timeout=3)
    elapsed=time.monotonic()-started
    print('CLI:', ' '.join(argv), '\nEXIT:',p.returncode,'ELAPSED:',round(elapsed,3),'\nSTDOUT:',p.stdout,'\nSTDERR:',p.stderr)
    assert p.returncode == 0
    journal=json.loads((home/'state/.main-backstop.json').read_text())
    print('PERSISTED JOURNAL:',json.dumps(journal,sort_keys=True))
    print('AUDIT:',(home/'state/.main-backstop.log').read_text())
    return journal

def observe_only(home, memory):
    assert not list((home/'state/inbox').glob('*.note'))
    assert not (home/'state/.wake-queue').exists()
    assert 'last_nudge' not in memory
    assert (home/'data/main-pane').read_text() == 'saved-pane-must-survive\n'
    assert memory['episodes']['recovery'] in memory['deferred_alarms']

for case in ['missing','missing-newline','extra-content','oversized','symlink','hardlink','writable-file','writable-config','fifo','directory','wrong-path']:
    with tempfile.TemporaryDirectory(prefix='backstop-live-') as tmp:
        home,cap=setup(pathlib.Path(tmp))
        if case != 'missing':
            cap.write_bytes(b'enabled\n');cap.chmod(0o600)
        if case=='missing-newline': cap.write_bytes(b'enabled')
        elif case=='extra-content': cap.write_bytes(b'enabled\nextra')
        elif case=='oversized': cap.write_bytes(b'x'*1048576)
        elif case in ['symlink','hardlink']:
            target=home/'enabled-target';target.write_bytes(b'enabled\n');target.chmod(0o600);cap.unlink()
            if case=='symlink':cap.symlink_to(target)
            else:os.link(target,cap)
        elif case=='writable-file':cap.chmod(0o666)
        elif case=='writable-config':(home/'config').chmod(0o777)
        elif case=='fifo':cap.unlink();os.mkfifo(cap,0o600)
        elif case=='directory':cap.unlink();cap.mkdir()
        elif case=='wrong-path':cap=home/'enabled-target';cap.write_bytes(b'enabled\n');cap.chmod(0o600)
        print('\nSCENARIO INVALID CAPABILITY:',case)
        memory=invoke(home,cap);observe_only(home,memory)
        print('OBSERVED: incident retained, no inbox note/wake/nudge, saved pane unchanged')

with tempfile.TemporaryDirectory(prefix='backstop-resume-live-') as tmp:
    home,cap=setup(pathlib.Path(tmp))
    print('\nSCENARIO STOP, RESOLVE, RECUR, RESUME')
    first=invoke(home,cap);observe_only(home,first)
    first_id=first['episodes']['recovery']
    (home/'state/.last-watcher-beat').touch()
    resolved=invoke(home,cap)
    assert 'recovery' not in resolved['episodes']
    os.utime(home/'state/.last-watcher-beat',(time.time()-1200,)*2)
    second=invoke(home,cap);observe_only(home,second)
    second_id=second['episodes']['recovery']
    assert first_id != second_id
    # AFK suppresses primary discovery; deferred inbox delivery is independently observable.
    (home/'state/.afk').touch()
    cap.write_bytes(b'enabled\n');cap.chmod(0o600)
    resumed=invoke(home,cap)
    notes=list((home/'state/inbox').glob('*.note'))
    content='\n'.join(p.read_text() for p in notes)
    print('DURABLE INBOX NOTES:\n'+content)
    print('DURABLE WAKE QUEUE:\n'+(home/'state/.wake-queue').read_text())
    assert len(notes)==2
    assert content.count('request_id='+first_id)==1 and content.count('request_id='+second_id)==1
    assert not resumed['deferred_alarms']
    snapshot={p.name:p.read_bytes() for p in notes}
    invoke(home,cap)
    assert {p.name:p.read_bytes() for p in (home/'state/inbox').glob('*.note')} == snapshot
    print('OBSERVED: distinct incident identities delivered once each on resume; replay did not duplicate notes')
print('All real CLI scenarios completed; disposable lab homes removed.')
