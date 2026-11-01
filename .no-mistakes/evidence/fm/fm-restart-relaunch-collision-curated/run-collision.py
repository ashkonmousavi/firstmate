import json, os, pathlib, subprocess, time

root = pathlib.Path.cwd()
base = root / '.live-validation'
product = base / 'product'
evidence = pathlib.Path('~/.no-mistakes/evidence/01M6ARDD44DB5QEFFM79A1RJS3')
env = os.environ.copy()
for key in ('FM_GATE_REFUSE_BYPASS', 'NO_MISTAKES_GATE', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_CODEX_TYPED_LAUNCH'):
    env.pop(key, None)
env.update(FM_HOME=str(base/'home'), PATH=str(base/'cli')+':'+env['PATH'],
           TMUX_TMPDIR=(base/'socket-dir').read_text().strip(),
           TMUX=(base/'tmux-env').read_text().strip(), FM_BACKEND='tmux',
           FM_SKIP_SECONDMATE_SYNC='1', FM_SKIP_SECONDMATE_INHERIT='1',
           FM_SECONDMATE_PERSIST_WAIT='120', FM_SECONDMATE_PERSIST_POLL='1',
           FM_SECONDMATE_RESTART_VERIFY_WAIT='35', FM_SECONDMATE_RESTART_VERIFY_POLL='1',
           FM_CONTROL_EXIT_WAIT='20', FM_CONTROL_LAUNCH_WAIT='30')
mode = os.environ.get('COLLISION_MODE', 'complete')
if mode == 'probe-hang':
    env['FM_SECONDMATE_RESTART_VERIFY_WAIT'] = '3'
winner_log = evidence/f'live-collision-{mode}-winner.log'
restart_log = evidence/f'live-collision-{mode}-restart.log'
with winner_log.open('w') as wf, restart_log.open('w') as rf:
    winner = subprocess.Popen(['bash', str(base/'collision-winner.sh'), str(product), str(base), mode], env=env, stdout=wf, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic()+10
        while not (base/'home/state/.spawn-sm-live.lock').exists():
            if winner.poll() is not None or time.monotonic()>deadline:
                raise RuntimeError('competing launch did not acquire lock')
            time.sleep(.05)
        start = time.monotonic()
        restart = subprocess.run([str(product/'bin/fm-secondmate-restart.sh'), 'sm-live'], env=env, stdout=rf, stderr=subprocess.STDOUT, timeout=200)
        frozen = base/'probe-frozen'
        frozen_seconds = round(time.time()-frozen.stat().st_mtime, 2) if frozen.exists() else None
        (base/'resume-probe').touch()
        winner_rc = winner.wait(timeout=90)
        result = dict(mode=mode, restart_exit=restart.returncode, winner_exit=winner_rc, elapsed_seconds=round(time.monotonic()-start, 2), frozen_seconds=frozen_seconds, liveness_lock_left=(base/'home/state/.secondmate-liveness-sm-live.lock').exists())
        (evidence/f'live-collision-{mode}-result.json').write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(result))
        output = restart_log.read_text()
        assert restart.returncode == 3 and 'unreached: sm-live' in output and 'restarted: sm-live' not in output, output
        assert winner_rc == (0 if mode in ('complete','probe-hang') else 1), winner_log.read_text()
        assert not result['liveness_lock_left'], result
        if mode == 'probe-hang':
            assert frozen_seconds is not None and frozen_seconds < 6, result
    finally:
        (base/'resume-probe').touch()
        if mode == 'probe-hang':
            import signal
            os.kill(int((base/'tmux-env').read_text().split(',')[1]), signal.SIGCONT)
        if winner.poll() is None:
            winner.terminate()
            winner.wait(timeout=10)
