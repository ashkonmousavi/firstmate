import json, os, pathlib, shutil, signal, subprocess, time, shlex

ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('~/.no-mistakes/evidence/01M66DAF303ANXGAQ00SM1EXND')
SCRATCH = ROOT / '.tmp-walk-validation' / 'manual'
SCRATCH.mkdir(parents=True)
BASE = ROOT / 'bin' / '.fm-walk-request-before-validation.sh'
CHECK = ROOT / 'bin' / 'fm-walk-request-check.sh'
RELEASE = '0123456789abcdef0123456789abcdef01234567'
RESULTS = []


def log(msg):
    print(msg, flush=True)


def env(home, **extra):
    e = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX', 'TMUX_PANE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'BASH_ENV', 'ENV')}
    e.update(FM_HOME=str(home), TMPDIR=str(SCRATCH), TMUX=str(home.relative_to(ROOT) / 'no-tmux-server') + ',0,0')
    e.update(extra)
    return e


def run(args, e, expected=0):
    p = subprocess.run([str(a) for a in args], env=e, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=40)
    log('$ ' + ' '.join(str(a).replace(str(ROOT) + '/', '') for a in args))
    log(f'exit={p.returncode}' + (f'\n{p.stdout.rstrip()}' if p.stdout else ' (silent)'))
    assert p.returncode == expected, (p.returncode, expected, p.stdout)
    return p.stdout


def home(name):
    h = SCRATCH / name
    run([ROOT / 'bin/fm-lab-home.sh', 'create', h], env(h))
    return h


def wait_until(f, label, seconds=25):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if f(): return
        time.sleep(.1)
    raise AssertionError('timeout: ' + label)


def guards():
    h = home('guards')
    config = h / 'config/watch.env'
    marker = h / 'EXECUTED'
    log('\n=== LIVE: absent configuration preserves optional routing ===')
    run([CHECK, 'check'], env(h))
    assert not list((h / 'state/walk-requests').glob('*.record'))
    RESULTS.append({'name':'absent file accepted', 'live':True, 'result':'pass'})
    log('\n=== LIVE: an explicit environment pair overrides an invalid file ===')
    config.write_text('FM_WALK_REQUEST_PROJECT=file\n')
    run([CHECK, 'check'], env(h, FM_WALK_REQUEST_PROJECT='env-project', FM_WALK_REQUEST_TARGET='staging'))
    run([CHECK, 'check'], env(h), 2)
    RESULTS.append({'name':'environment precedence', 'live':True, 'result':'pass'})
    log('\n=== LIVE: a partial environment pair cannot borrow its missing half ===')
    config.write_text('FM_WALK_REQUEST_PROJECT=x\nFM_WALK_REQUEST_TARGET=production\n')
    run([CHECK, 'check'], env(h, FM_WALK_REQUEST_PROJECT='env-project'), 2)
    RESULTS.append({'name':'partial pair rejected', 'live':True, 'result':'pass'})
    log('\n=== LIVE: shell syntax in watch.env is never executed ===')
    config.write_text(f'OTHER=$(touch {marker})\nOTHER=`touch {marker}`\ntouch {marker}\nexport FM_WALK_REQUEST_PROJECT="x" FM_WALK_REQUEST_TARGET=production # comment\n')
    run([CHECK, 'check'], env(h))
    assert not marker.exists()
    for name in ('PROJECT', 'TARGET'):
        config.write_text('FM_WALK_REQUEST_PROJECT=x\nFM_WALK_REQUEST_TARGET=production\n' + f'FM_WALK_REQUEST_{name}="$(touch${{IFS}}{marker})"\n')
        run([CHECK, 'check'], env(h), 2)
        assert not marker.exists()
    assert not list((h / 'state/walk-requests').glob('*.record'))
    log('No execution marker or request record was created.')
    RESULTS.append({'name':'non-executing parser and malformed routing rejection', 'live':True, 'result':'pass'})
    log('\n=== LIVE: the configured config-directory override is honored ===')
    alternate = h / 'alternate-config'
    alternate.mkdir()
    (alternate / 'watch.env').write_text('FM_WALK_REQUEST_TARGET=production\n')
    config.write_text('FM_WALK_REQUEST_PROJECT=x\nFM_WALK_REQUEST_TARGET=production\n')
    run([CHECK, 'check'], env(h, FM_CONFIG_OVERRIDE=str(alternate)), 2)
    RESULTS.append({'name':'config root override', 'live':True, 'result':'pass'})


def boundary(label, checker):
    log(f'\n=== NON-LIVE downstream-boundary probe: {label} ===')
    log('Carrier, watcher, checker, and fm-send are real. The home-private bot dispatcher is a test double; this does not prove a live bot walk.')
    h = home(label)
    mate = home(label + '-mate')
    (mate / '.fm-secondmate-home').write_text('mate\n')
    (mate / '.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={h}\n')
    (mate / 'data/walk-briefs').mkdir()
    brief = mate / 'data/walk-briefs/brief.md'
    brief.write_text('Disposable walk validation brief.\n')
    dispatcher = h / 'data/boundary-dispatch'
    dispatcher.write_text('''#!/usr/bin/env python3
import json, pathlib, sys
args = sys.argv[1:]
p = pathlib.Path(__file__).with_suffix('.json')
p.write_text(json.dumps(args))
if '--project' not in args or '--target' not in args:
    print('explicit supported --project and --target required')
    sys.exit(2)
if args[args.index('--project')+1] != 'x' or args[args.index('--target')+1] != 'production':
    print('unexpected route')
    sys.exit(2)
print('BOUNDARY PROBE ONLY: accepted project=x target=production')
''')
    dispatcher.chmod(0o700)
    e = env(h, FM_WALK_REQUEST_DISPATCH=str(dispatcher), FM_POLL='1', FM_CHECK_INTERVAL='1', FM_SIGNAL_GRACE='0', FM_SECONDMATE_LIVENESS_SECS='3600', FM_EVENT_WAIT='0')
    run([checker, 'arm'], e)
    if label == 'before':
        shim = h / 'state/walk-request.check.sh'
        shim.write_text('#!/usr/bin/env bash\nexport FM_HOME=' + shlex.quote(str(h)) + '\nexec bash ' + shlex.quote(str(checker)) + ' check\n')
        run([ROOT / 'bin/fm-check-register.sh', 'walk-request'], e)
        log('Baseline generated fixture shim explicitly invokes the base-commit checker; trust binding refreshed.')
    (h / 'state/.secondmate-liveness-tick').touch()
    output = open(EVIDENCE / f'{label}-watcher.log', 'w')
    watcher = subprocess.Popen([str(ROOT / 'bin/fm-watch-arm.sh')], env=e, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        wait_until(lambda:(h / 'state/.last-watcher-beat').exists(), 'watcher beacon')
        log(f'Watcher armed pid={watcher.pid} before watch.env existed; routing values absent from launch environment.')
        (h / 'config/watch.env').write_text('export FM_WALK_REQUEST_PROJECT="old"\nexport FM_WALK_REQUEST_PROJECT="x" FM_WALK_REQUEST_TARGET=\'production\' # last assignment wins\n')
        log('Wrote config/watch.env AFTER the watcher beacon, without restarting the watcher.')
        (h / 'state/mate.meta').write_text(f'kind=secondmate\nhome={mate}\nwindow=fm-lab-validation:mate\nbackend=tmux\nharness=claude\n')
        run([ROOT / 'bin/fm-walk-request.sh', '--brief', brief, '--release', RELEASE, '--walks', 'desk-step', '--bot', 'J01Walker'], env(mate))
        wait_until(lambda:dispatcher.with_suffix('.json').exists(), 'dispatcher invocation')
        args = json.loads(dispatcher.with_suffix('.json').read_text())
        log('Configured dispatcher argv: ' + json.dumps(args))
        logs = list((h / 'state/walk-requests').glob('*.log'))
        wait_until(lambda:logs and '__FM_WALK_DISPATCH_EXIT__=' in logs[0].read_text(), 'detached dispatcher exit')
        report = logs[0].read_text()
        log('Dispatcher result:\n' + report)
        expected = 0 if label == 'after' else 2
        assert f'__FM_WALK_DISPATCH_EXIT__={expected}' in report
        if expected == 0:
            assert args[-4:] == ['--project','x','--target','production']
        else:
            assert '--project' not in args and '--target' not in args
        # The real check collects and the real fm-send durably enqueues the report.
        run([checker, 'check'], e)
        inbox = h / 'state/mate.inbox'
        wait_until(lambda:bool(list(inbox.glob('*.msg'))), 'real steering inbox delivery')
        records = list(inbox.glob('*.msg'))
        for record in records:
            log('Real inbox record:\n' + record.read_text())
        assert len(records) == 1
        if expected == 0:
            assert 'outcome: sent, exit=0' in records[0].read_text()
        else:
            assert 'outcome: dispatch failed (exit=2): explicit supported --project and --target required' in records[0].read_text()
        run([checker, 'check'], e)
        assert len(list(inbox.glob('*.msg'))) == 1
        shutil.copyfile(logs[0], EVIDENCE / f'{label}-dispatch.log')
        shutil.copyfile(records[0], EVIDENCE / f'{label}-inbox.md')
        RESULTS.append({'name':label+' stale-watcher boundary probe', 'live':False, 'result':'pass'})
    finally:
        if watcher.poll() is None:
            os.killpg(watcher.pid, signal.SIGTERM)
        try: watcher.wait(timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(watcher.pid, signal.SIGKILL)
            watcher.wait()
        output.close()
        log(f'Watcher process reaped, exit={watcher.returncode}.')

try:
    BASE.write_bytes(subprocess.check_output(['git','show','ce32074f8cec0a445f97f94079c46045504dbf17:bin/fm-walk-request-check.sh']))
    BASE.chmod(0o700)
    guards()
    boundary('before', BASE)
    boundary('after', CHECK)
    (EVIDENCE / 'probe-results.json').write_text(json.dumps(RESULTS, indent=2))
finally:
    BASE.unlink(missing_ok=True)
    shutil.rmtree(SCRATCH)
