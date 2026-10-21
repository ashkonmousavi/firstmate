import os,pathlib,tempfile,socket,subprocess,threading,time,signal,shutil,json
root=pathlib.Path.cwd(); evidence=pathlib.Path('~/.no-mistakes/evidence/01M5EDB3MBWCZX063DZJ8QGKGJ')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.inbox-live-',dir=root)); processes=[]; sockets=[]
try:
    for d in ['data','state','config']: (lab/d).mkdir()
    (lab/'state/home-summary.json').write_text('{}')
    (lab/'state/rsm.meta').write_text('window=remote:rsm\nkind=secondmate\nmode=secondmate\nharness=claude\nremote_host=inbox-lab\nremote_root='+str(root)+'\nremote_backend=herdr\nremote_herdr_session=fm-remote\nremote_target=fm-remote:p1\n')
    (lab/'data/secondmates.md').write_text('- rsm - disposable remote (host: inbox-lab; root: '+str(root)+'; home: '+str(lab)+'; scope: lab; projects: sample; added 2026-10-20)\n')
    listener=socket.socket(); listener.bind(('127.0.0.1',0))
    # Use only approved local ports.
    listener.close()
    for port in range(9600,9700):
        listener=socket.socket()
        try: listener.bind(('127.0.0.1',port)); break
        except OSError: listener.close()
    listener.listen(); listener.settimeout(.3); sockets.append(listener)
    stop=threading.Event(); accepted=[]
    def blackhole():
        while not stop.is_set():
            try:
                conn,_=listener.accept(); sockets.append(conn); accepted.append(time.monotonic())
            except socket.timeout: pass
            except OSError: break
    threading.Thread(target=blackhole,daemon=True).start()
    config=lab/'ssh-config'; config.write_text(f'Host inbox-lab\n HostName 127.0.0.1\n Port {port}\n BatchMode yes\n ConnectTimeout 40\n UserKnownHostsFile /dev/null\n GlobalKnownHostsFile /dev/null\n IdentityAgent none\n IdentitiesOnly yes\n IdentityFile none\n')
    wrapper=lab/'ssh'; wrapper.write_text('#!/bin/sh\nexec /usr/bin/ssh -F "'+str(config)+'" "$@"\n'); wrapper.chmod(0o755)
    env=os.environ.copy()
    for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']: env.pop(k,None)
    env.update(FM_HOME=str(lab),FM_ROOT_OVERRIDE=str(root),FM_SSH_BIN=str(wrapper),FM_POLL='1',FM_TASK_INBOX_GRACE_SECS='1',FM_SECONDMATE_LIVENESS_SECS='99999999',FM_HOME_SUMMARY_INTERVAL='99999999',FM_HEARTBEAT='99999999')
    out=open(evidence/'live-watch-output.log','w')
    p=subprocess.Popen(['bash','bin/fm-watch.sh'],env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True); processes.append(p)
    samples=[]; start=time.monotonic()
    while time.monotonic()-start<43:
        beat=lab/'state/.last-watcher-beat'
        samples.append({'second':round(time.monotonic()-start,1),'beacon':beat.stat().st_mtime if beat.exists() else None,'alive':p.poll() is None,'ssh_connections':len(accepted)})
        time.sleep(1)
    (evidence/'live-watch-samples.json').write_text(json.dumps(samples,indent=2))
    triage=lab/'state/watch-triage.log'
    logs=[x for x in (lab/'state').iterdir() if x.is_file() and ('triage' in x.name)]
    for x in logs: shutil.copyfile(x,evidence/('live-'+x.name))
    assert accepted,'watcher never contacted stalled SSH endpoint'
    inhop=[s['beacon'] for s in samples if 7<s['second']<27 and s['beacon']]
    assert len(set(inhop))>=3,'beacon failed to advance during SSH handshake stall'
    assert p.poll() is None,'watcher exited unexpectedly'
    print('PASS: real watcher maintained beacon during stalled OpenSSH handshake; distinct beacon values during seconds 7-27:',len(set(inhop)))
    print('SSH connections:',len(accepted),'(retry after bounded failed hop); samples: live-watch-samples.json')
finally:
    for p in processes:
        try: os.killpg(p.pid,signal.SIGTERM)
        except ProcessLookupError: pass
    time.sleep(.5)
    for p in processes:
        try: os.killpg(p.pid,signal.SIGKILL)
        except ProcessLookupError: pass
        p.wait()
    if 'stop' in locals(): stop.set()
    for s in sockets: s.close()
    shutil.rmtree(lab)
