from pathlib import Path
E=Path('~/.no-mistakes/evidence/01M623WEVE8Z0BJ53B6V14ECWW')
prefix=(E/'live-conflict.py').read_text().split("\ntry:\n    note('Production")[0]
prefix=prefix.replace('W.mkdir(exist_ok=False)','W.mkdir(exist_ok=True)').replace("B=W/'bin'; B.mkdir()", "B=W/'bin'; B.mkdir(exist_ok=True)").replace("log=(E/'live-conflict.log').open('w')", "log=(E/'live-adjacent.log').open('w')")
exec(prefix)
try:
    for case in ['ready','stale']:
        shutil.rmtree(S); S.mkdir()
        (S/'lane.meta').write_text('kind=ship\nharness=codex\nwindow=primary:fm-lane\n')
        out=E/(case+'-live.stdout'); err=E/(case+'-live.stderr')
        with out.open('w') as o,err.open('w') as e:
            p=subprocess.Popen(['bash','bin/fm-watch.sh'],cwd=ROOT,env=ENV,stdout=o,stderr=e,start_new_session=True)
            try:
                if case=='ready':
                    end=time.monotonic()+10
                    while not (S/'.last-watcher-beat').exists() and p.poll() is None and time.monotonic()<end: time.sleep(.005)
                    (S/'lane.status').write_text('done: PR ready https://github.com/disposable/conflict-lab/pull/7\n')
                rc=p.wait(timeout=20)
            finally:
                if p.poll() is None: p.terminate(); p.wait(timeout=10)
        text=out.read_text()
        note(case+' actual watcher exit='+str(rc)+'; stdout='+repr(text)+'; stderr='+repr(err.read_text()))
        assert rc==0 and (('signal:' in text) if case=='ready' else ('stale: primary:fm-lane' in text))
        assert not messages()
        note('PASS '+case+' event surfaces supervision without writing an instruction record.')
finally:
    log.close()
