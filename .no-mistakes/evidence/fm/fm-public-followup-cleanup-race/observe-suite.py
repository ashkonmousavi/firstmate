import json, os, pathlib, signal, subprocess, sys, time, tempfile
repo = pathlib.Path.cwd()
evidence = pathlib.Path('~/.no-mistakes/evidence/01M67CPDNAQGQS4FQAF06S6HGF')
mode = sys.argv[1]
log = evidence / ('public-followup-' + mode + '.log')
temporary = tempfile.TemporaryDirectory(prefix='fm-followup-validation-')
tmp_root = pathlib.Path(temporary.name)
env = dict(os.environ, TMPDIR=str(tmp_root))
seen = {}
interrupted = False
started = time.monotonic()
with log.open('w') as out:
    proc = subprocess.Popen(['bash', 'tests/fm-public-followup.test.sh'], env=env, stdout=out, stderr=subprocess.STDOUT)
    while proc.poll() is None:
        for path in tmp_root.glob('fm-public-followup.*/remote-jobs/worker.pid'):
            try:
                pid = int(path.read_text().strip())
                command = subprocess.run(['ps','-p',str(pid),'-o','args='], capture_output=True, text=True).stdout.strip()
                if 'fm-remote-job-worker.sh' in command:
                    seen[pid] = {'pid':pid,'command':command,'fixture':str(path.parent.parent)}
                    if mode == 'term' and not interrupted and path.with_name('worker.ready').exists():
                        proc.send_signal(signal.SIGTERM)
                        interrupted = True
            except (OSError, ValueError):
                pass
        if time.monotonic()-started > 300:
            proc.send_signal(signal.SIGTERM)
            raise RuntimeError('suite exceeded 300 seconds')
        time.sleep(.05)
    code = proc.wait()
result = {'mode': mode, 'exit_code':code, 'term_sent':interrupted, 'elapsed_seconds':round(time.monotonic()-started,2), 'workers':list(seen.values())}
for item in result['workers']:
    status = subprocess.run(['ps','-p',str(item['pid']),'-o','stat='],capture_output=True,text=True).stdout.strip()
    item['status_after_exit'] = status or 'gone'
    item['fixture_removed'] = not pathlib.Path(item['fixture']).exists()
remaining = subprocess.run(['ps','-eo','pid=,stat=,args='],capture_output=True,text=True).stdout.splitlines()
result['remaining_fixture_processes'] = [line.strip() for line in remaining if any(item['fixture'] in line and not line.split()[1].startswith('Z') for item in seen.values())]
result['ok'] = bool(seen) and code == (143 if mode == 'term' else 0) and all(item['fixture_removed'] and (item['status_after_exit']=='gone' or item['status_after_exit'].startswith('Z')) for item in result['workers']) and not result['remaining_fixture_processes']
(evidence / ('public-followup-' + mode + '-observation.json')).write_text(json.dumps(result,indent=2)+'\n')
temporary.cleanup()
print(json.dumps(result,indent=2))
sys.exit(0 if result['ok'] else 1)
