import json, os, pathlib, subprocess, time
workspace = pathlib.Path('/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4F9P8ZT2CWPG9DB2G8CNPJK')
base = workspace / '.test-phase-tmp' / 'manual-ownership'
base.mkdir(parents=True, exist_ok=True)
producer = r'''
set -u
. "$PROOF_LIB"
root=$(fm_test_tmproot fm-manual-ownership)
printf '%s\n' "$root" > "$PROOF_CASE/root"
printf '%s\n' "$FM_TEST_PROCESS_REGISTRY" > "$PROOF_CASE/registry"
if [ "$PROOF_MODE" = exited ]; then
  (cd "$root" && exit 0) &
  pid=$!
  wait "$pid"
else
  bash -c '
    cd "$1" || exit 1
    deadline=$((SECONDS+300))
    : > "$2/ready"
    while [ ! -e "$2/release" ]; do
      if [ -e "$2/move" ]; then cd "$2" || exit 1; : > "$2/moved"; fi
      [ "$SECONDS" -lt "$deadline" ] || { : > "$2/expired"; exit 1; }
      sleep 0.05
    done
  ' _ "$root" "$PROOF_CASE" </dev/null >/dev/null 2>&1 &
  pid=$!
  while [ ! -e "$PROOF_CASE/ready" ]; do sleep 0.01; done
fi
printf '%s\n' "$pid" > "$PROOF_CASE/pid"
case "$PROOF_MODE" in
  invalid-root) fm_test_track_process "$pid" "$PROOF_CASE" && exit 99 ;;
  substitution) registered=$(fm_test_track_process "$pid" "$root") || exit 98 ;;
  *) fm_test_track_process "$pid" "$root" || exit 98 ;;
esac
case "$PROOF_MODE" in
  cwd-departure)
    : > "$PROOF_CASE/move"
    while [ ! -e "$PROOF_CASE/moved" ]; do sleep 0.01; done ;;
  birth-drift|birth-drift-failure7)
    printf '%s\twrong-birth\t%s\n' "$pid" "$root" > "$FM_TEST_PROCESS_REGISTRY" ;;
  missing-registry) rm -f "$FM_TEST_PROCESS_REGISTRY" ;;
esac
case "$PROOF_MODE" in failure7|birth-drift-failure7) exit 7 ;; esac
exit 0
'''

def state(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
    return result.stdout.strip()

def running(pid):
    value = state(pid)
    return bool(value) and 'Z' not in value

for mode in ['success', 'failure7', 'substitution', 'exited', 'cwd-departure', 'birth-drift', 'birth-drift-failure7', 'missing-registry', 'invalid-root']:
    case = base / mode
    case.mkdir()
    env = os.environ.copy()
    env.update(PROOF_LIB=str(workspace / 'tests/lib.sh'), PROOF_CASE=str(case), PROOF_MODE=mode,
               TMPDIR=str(case), FM_HOME=str(workspace / '.test-phase-home'))
    unrelated = subprocess.Popen(['bash', '-c', 'while [ ! -e "$1" ]; do sleep 0.05; done', '_', str(case / 'other-release')], cwd=case, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pid = None
    try:
        result = subprocess.run(['bash'], input=producer, cwd=workspace, env=env, capture_output=True, text=True, timeout=60)
        pid = int((case / 'pid').read_text())
        root = pathlib.Path((case / 'root').read_text().strip())
        refused = mode in ['cwd-departure', 'birth-drift', 'birth-drift-failure7', 'missing-registry', 'invalid-root']
        expected_rc = 7 if mode in ['failure7', 'birth-drift-failure7'] else 1 if refused else 0
        observed = dict(scenario=mode, producer_exit=result.returncode, child_pid=pid, child_state=state(pid),
                        fixture_preserved=root.exists(), unrelated_pid=unrelated.pid, unrelated_alive=unrelated.poll() is None,
                        refused='REFUSED:' in result.stderr, released_at_observation=(case / 'release').exists(), expired=(case / 'expired').exists())
        print(json.dumps(observed, sort_keys=True), flush=True)
        if result.stderr: print(result.stderr.strip(), flush=True)
        assert result.returncode == expected_rc, observed
        assert root.exists() == refused, observed
        assert running(pid) == refused, observed
        assert observed['unrelated_alive'], observed
        assert observed['refused'] == refused, observed
        assert not observed['released_at_observation'] and not observed['expired'], observed
    finally:
        (case / 'release').touch()
        (case / 'other-release').touch()
        unrelated.wait(timeout=60)
        if pid:
            deadline = time.monotonic() + 60
            while running(pid) and time.monotonic() < deadline: time.sleep(0.05)
            assert not running(pid), 'cooperative release failed for ' + mode
print('All manual ownership observations passed; every holder was terminal before harness cleanup.', flush=True)
