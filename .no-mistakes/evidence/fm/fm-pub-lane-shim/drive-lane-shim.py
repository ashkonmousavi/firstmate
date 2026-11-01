#!/usr/bin/env python3
"""Run the real lane-release CLI and watcher snapshot consumer, using disposable code roots.
Oracle: author's home-own-code-root requirement and documented arm/sweep/disarm CLI.
Rejects pinning an obsolete root, wrong-home writes, missing-script status 127, and unsafe quoting.
No replacement product scripts, backend probes, or harnesses are used.
"""
import json, os, pathlib, shlex, shutil, subprocess, tempfile
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path(__file__).parent
results = []
base = pathlib.Path(tempfile.mkdtemp(prefix='.lane-shim-live-', dir=ROOT))
env = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('BASH_ENV', 'ENV', 'SHELLOPTS', 'BASHOPTS')}
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
log = (EVIDENCE/'lane-shim-live.log').open('w')

def run(args, home, expected=0, cwd=None):
    e = dict(env, FM_HOME=str(home))
    log.write('$ ' + shlex.join(map(str,args)) + '\nFM_HOME=' + str(home) + '\n')
    p = subprocess.run(list(map(str,args)), env=e, cwd=cwd or ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=35)
    log.write(p.stdout + p.stderr + 'exit=' + str(p.returncode) + '\n\n'); log.flush()
    assert p.returncode == expected, (args,p.returncode,expected,p.stdout,p.stderr)
    return p

def setup(name, own=True, special=False):
    d = base/name; d.mkdir()
    pin = d/('arming root \' $literal; (x)' if special else 'arming')
    pin.mkdir(); shutil.copytree(ROOT/'bin', pin/'bin', symlinks=True)
    home = d/('home \' $literal; (x)' if special else 'home')
    run([ROOT/'bin/fm-lab-home.sh','create',home], home)
    if own: shutil.copytree(ROOT/'bin', home/'bin', symlinks=True)
    (home/'config/lane-release').write_text('live-proof-'+name+'\n')
    return d,pin,home

def arm(pin,home,relative=False):
    selected = pathlib.Path(os.path.relpath(home,ROOT)) if relative else home
    run([pin/'bin/fm-lane-release.sh','arm'],selected)
    shim = home/'state/lane-release.check.sh'
    assert shim.stat().st_mode & 0o777 == 0o700
    assert (home/'state/lane-release.check-trust').exists()
    return shim

def drive(home, selected=None, error=False):
    # Use the same real byte-bound snapshot consumer called by fm-watch.sh.
    # bash -x makes the selected exec target visible; the real sweep then runs.
    command = '''source "$1/bin/fm-pr-lib.sh"
source "$1/bin/fm-check-lib.sh"
fm_custom_check_snapshot_prepare "$2/state" lane-release || exit 91
trap fm_custom_check_snapshot_cleanup EXIT
bash -x "$FM_CUSTOM_CHECK_SNAPSHOT"
'''
    p = run(['bash','-c',command,'lane-shim-live',ROOT,home],base/'unrelated-home',1 if error else 0)
    if error:
        assert 'fm-lane-release shim: no executable fm-lane-release.sh at ' in p.stderr
        assert not (home/'state/.lane-release-invalid').exists()
    else:
        execs = [shlex.split(line[2:]) for line in p.stderr.splitlines() if line.startswith('+ exec ')]
        assert execs == [['exec',str(selected),'sweep']], execs
        sentinel = 'live-proof-'+home.parent.name
        assert f"holds '{sentinel}', expected off, audit, or on" in p.stdout
        assert (home/'state/.lane-release-invalid').read_text() == sentinel+'\n'
        assert not (base/'unrelated-home').exists()
    return p

def record(name):
    results.append({'name':name,'result':'pass','live':True})
    log.write('PROVED: '+name+'\n\n'); log.flush()

try:
    d,pin,home = setup('prefer-home')
    arm(pin,home); drive(home,home/'bin/fm-lane-release.sh')
    record('Both code roots executable: registered shim runs the home code root and writes only its home state')

    d,pin,home = setup('lost-arming-root')
    arm(pin,home); shutil.rmtree(pin)
    drive(home,home/'bin/fm-lane-release.sh')
    run([home/'bin/fm-lane-release.sh','disarm'],home)
    assert not (home/'state/lane-release.check.sh').exists()
    assert not (home/'state/lane-release.check-trust').exists()
    record('Delete arming checkout after arm: byte-bound shim still runs the real home sweep; disarm removes registration')

    d,pin,home = setup('fallback-no-home',own=False)
    arm(pin,home); drive(home,pin/'bin/fm-lane-release.sh')
    record('Home has no code: registered shim falls back to the real arming checkout')

    d,pin,home = setup('fallback-nonexec-home')
    arm(pin,home); (home/'bin/fm-lane-release.sh').chmod(0o600)
    drive(home,pin/'bin/fm-lane-release.sh')
    record('Home script loses execute permission: registered shim uses executable arming checkout')

    d,pin,home = setup('no-scripts',own=False)
    arm(pin,home); shutil.rmtree(pin)
    drive(home,error=True)
    record('Neither script exists: registered shim emits actionable diagnostic and exits 1')

    d,pin,home = setup('no-executables')
    arm(pin,home)
    (home/'bin/fm-lane-release.sh').chmod(0o600)
    (pin/'bin/fm-lane-release.sh').chmod(0o600)
    drive(home,error=True)
    record('Neither script executable: registered shim exits 1 without attempting sweep')

    d,pin,home = setup('arm-refusal')
    (pin/'bin/fm-lane-release.sh').chmod(0o600)
    p=run(['bash',pin/'bin/fm-lane-release.sh','arm'],home,1)
    assert 'refusing to arm' in p.stderr and 'is not executable' in p.stderr
    assert not (home/'state/lane-release.check.sh').exists()
    assert not (home/'state/lane-release.check-trust').exists()
    record('Arm through bash with nonexecutable arming script: refuses without creating shim or trust')

    d,pin,home = setup('quoted-relative-home',special=True)
    arm(pin,home,relative=True); drive(home,home/'bin/fm-lane-release.sh')
    (home/'state/.lane-release-invalid').unlink()
    (home/'bin/fm-lane-release.sh').chmod(0o600)
    drive(home,pin/'bin/fm-lane-release.sh')
    record('Relative home and shell-sensitive paths: own-root and fallback sweeps preserve paths and override unrelated caller FM_HOME')

    d,pin,home = setup('install-home-later',own=False)
    arm(pin,home); drive(home,pin/'bin/fm-lane-release.sh')
    (home/'state/.lane-release-invalid').unlink()
    shutil.copytree(ROOT/'bin',home/'bin',symlinks=True)
    drive(home,home/'bin/fm-lane-release.sh')
    record('Install home code after arming: unchanged trusted shim switches from fallback to home executable')

    # Reproduce the original incident using the actual pre-change script, not a fake.
    d,pin,home = setup('baseline-regression')
    old=subprocess.run(['git','show','ee1fcd6f14c2df2be31bc119171bc3f7c6014f3f:bin/fm-lane-release.sh'],cwd=ROOT,check=True,stdout=subprocess.PIPE).stdout
    (pin/'bin/fm-lane-release.sh').write_bytes(old)
    arm(pin,home); shutil.rmtree(pin)
    p=run(['bash',home/'state/lane-release.check.sh'],home,127)
    assert 'No such file or directory' in p.stderr
    log.write('BASELINE REPRODUCED: pre-fix shim exits 127 after arming checkout removal, despite executable home code. Target passed this same scenario.\n')
    log.flush()
finally:
    shutil.rmtree(base)
    log.write('Disposable roots removed.\n'); log.close()
    (EVIDENCE/'lane-shim-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
