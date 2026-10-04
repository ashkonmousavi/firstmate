#!/usr/bin/env bash
# Public CLI fixtures: real origin/PR graphs, trusted tools and isolated state.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-q-premerge)
fm_git_identity
repo="$TMP_ROOT/pc/Q"
fm_git_init_commit "$repo"
package=docs/ssot/q-v2
mkdir -p "$repo/$package/tools" "$repo/ops/bin" "$repo/ops/lib/q-v2"
cat > "$repo/$package/tools/check_plan.py" <<'PY'
import json, pathlib, sys
import os, subprocess
args = sys.argv
repo = pathlib.Path(args[args.index('--repo') + 1]) if '--repo' in args else pathlib.Path(args[args.index('--head-repo') + 1])
mode = (repo / 'mode').read_text().strip()
if mode == 'hang-' + args[1]:
    import time
    subprocess.Popen([sys.executable, '-I', '-c', os.environ['FM_Q_PREMERGE_CHILD_CODE']])
    print('{"fresh": true}', flush=True)
    time.sleep(60)
def snapshot_bytes(root, ref):
    for name in ('byte-witness.bin', 'format-witness.txt'):
        expected = subprocess.check_output(['git', '-C', str(repo), 'show', f'{ref}:{name}'])
        assert (root / name).read_bytes() == expected
    assert os.access(root / 'format-witness.txt', os.X_OK)
    assert (root / 'safe-link').is_symlink()
    assert os.readlink(root / 'safe-link') == 'format-witness.txt'
    assert (root / 'safe-link').read_bytes() == (root / 'format-witness.txt').read_bytes()
snapshot_bytes(repo, 'HEAD')
if args[1] == 'check-union':
    # Verify actual scratch history and snapshots, not just freshness output.
    base = args[args.index('--base-ref') + 1]
    head = args[args.index('--head-ref') + 1]
    assert subprocess.check_output(['git', '-C', str(repo), 'merge-base', base, head]).decode().strip() == base
    identity_format = '--format=%an%x00%ae%x00%cn%x00%ce'
    assert subprocess.check_output(['git', '-C', str(repo), 'show', '-s', identity_format, base]) == subprocess.check_output(['git', '-C', str(repo), 'show', '-s', identity_format, head])
    for flag in ('--base-repo', '--ancestor-repo'):
        root = pathlib.Path(args[args.index(flag)+1])
        assert (root / 'mode').is_file()
        snapshot_bytes(root, base)
    print(json.dumps({'fresh': mode != 'union'}))
    sys.exit(2 if mode == 'union' else 0)
if mode == 'bad': print('not JSON "fresh": true'); sys.exit(0)
if mode == 'quoted': print(json.dumps('"fresh": true')); sys.exit(0)
if mode == 'empty': sys.exit(0)
if mode == 'timeout': print('{"fresh": true}', flush=True); sys.exit(124)
if mode == 'hang':
    import time
    print('{"fresh": true}', flush=True); time.sleep(10)
print(json.dumps({'fresh': mode != 'stale'}))
sys.exit(1 if mode in ('stale', 'nonzero') else 0)
PY
cat > "$repo/$package/tools/build_plan_views.py" <<'PY'
import os, pathlib, subprocess, sys
repo = pathlib.Path(sys.argv[sys.argv.index('--repo')+1])
if (repo / 'mode').read_text().strip() == 'hang-view':
    import time
    subprocess.Popen([sys.executable, '-I', '-c', os.environ['FM_Q_PREMERGE_CHILD_CODE']])
    print('plan views: fresh', flush=True)
    time.sleep(60)
for name in ('byte-witness.bin', 'format-witness.txt'):
    assert (repo / name).read_bytes() == subprocess.check_output(['git', '-C', str(repo), 'show', f'HEAD:{name}'])
print('plan views: fresh')
sys.exit(2 if (repo / 'mode').read_text().strip() == 'view' else 0)
PY
printf 'good\n' > "$repo/mode"
printf 'original\n' > "$repo/shared.txt"
printf '\000\377\r\n' > "$repo/byte-witness.bin"
printf '$Format:%%H$\r\noriginal\n' > "$repo/format-witness.txt"
chmod +x "$repo/format-witness.txt"
ln -s format-witness.txt "$repo/safe-link"
printf 'format-witness.txt export-subst\nbyte-witness.bin export-ignore\n' > "$repo/.gitattributes"
touch "$repo/$package/tools/build_current_baseline.py" "$repo/ops/bin/q-v2-tool-scopes" "$repo/ops/lib/q-v2/q_agent_api.py"
python3 - "$repo/$package/tools/tool-closure.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({'schema':'q-plan-tool-closure/1','members':[
'docs/ssot/q-v2/tools/check_plan.py','docs/ssot/q-v2/tools/build_plan_views.py',
'docs/ssot/q-v2/tools/build_current_baseline.py','ops/bin/q-v2-tool-scopes','ops/lib/q-v2/q_agent_api.py']}))
PY
git -C "$repo" add .
git -C "$repo" commit -qm tools
O=$(git -C "$repo" rev-parse HEAD)
printf 'main\n' > "$repo/shared.txt"
git -C "$repo" add .
git -C "$repo" commit -qm base
B=$(git -C "$repo" rev-parse HEAD)
fm_git_add_origin "$repo" "$TMP_ROOT/origin.git"
git clone -q "$TMP_ROOT/origin.git" "$TMP_ROOT/server-Q"
cli="${FM_PREMERGE_CHECK_CLI:-$ROOT/bin/fm-q-premerge-plan-check.sh}"
make_head() {
  git -C "$repo" checkout -q --detach "$O"
  printf '%s\n' "$1" > "$repo/mode"
  printf '%s\n' "$1" > "$repo/candidate.txt"
  printf '$Format:%%H$\r\n%s\n' "$1" > "$repo/format-witness.txt"
  git -C "$repo" add .
  git -C "$repo" commit -qm candidate
  H=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" push -q origin "$H:refs/pull/7/head" --force
}
run_check() {
  local expected=$1 clone=${2:-$repo} number=${3:-7} rc=0 prior
  prior=$(git -C "$clone" show-ref; git -C "$clone" status --porcelain; git -C "$clone" rev-parse HEAD; git -C "$clone" config --local --list)
  output=$(bash "$cli" "$clone" "$number" 2>&1) || rc=$?
  expect_code "$expected" "$rc" "$4"
  assert_equals "$prior" "$(git -C "$clone" show-ref; git -C "$clone" status --porcelain; git -C "$clone" rev-parse HEAD; git -C "$clone" config --local --list)" "$4 leaves source unchanged"
}
make_head good
T=$(git -C "$repo" merge-tree --write-tree "$B" "$H")
run_check 0 "$repo" 7 happy
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'exact resolved identities'
run_check 0 "$TMP_ROOT/server-Q" 7 portable
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'same result from independent home'
pass 'portable valid merged tree'
git clone -q --bare "$TMP_ROOT/origin.git" "$TMP_ROOT/other-origin.git"
git -C "$repo" checkout -q --detach "$B"
printf 'other base\n' > "$repo/other-base.txt"
git -C "$repo" add .
git -C "$repo" commit -qm other-base
other_base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" push -q "$TMP_ROOT/other-origin.git" HEAD:refs/heads/main
git -C "$repo" checkout -q --detach "$H"
printf 'other head\n' > "$repo/other-head.txt"
git -C "$repo" add .
git -C "$repo" commit -qm other-head
other_head=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" push -q --force "$TMP_ROOT/other-origin.git" HEAD:refs/pull/7/head
assert_not_contains "$other_base" "$B" 'origin main identities differ'
assert_not_contains "$other_head" "$H" 'origin PR identities differ'
alias_url='premerge-origin-alias'
git -C "$repo" remote set-url origin "$alias_url"
git -C "$repo" config "url.$TMP_ROOT/origin.git.insteadOf" "$alias_url"
git -C "$repo" config "url.$TMP_ROOT/other-origin.git.insteadOf" "$TMP_ROOT/origin.git"
source_refs=$(git -C "$repo" ls-remote origin refs/heads/main refs/pull/7/head)
assert_contains "$source_refs" "$B" 'source fetch resolves intended main'
assert_contains "$source_refs" "$H" 'source fetch resolves intended PR'
run_check 0 "$repo" 7 'rewrite chain uses source origin'
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'origin rewrites exactly once'
git -C "$repo" remote set-url origin ../../origin.git
source_refs=$(git -C "$repo" ls-remote origin refs/heads/main refs/pull/7/head)
assert_contains "$source_refs" "$B" 'unrewritten relative origin resolves intended main'
assert_contains "$source_refs" "$H" 'unrewritten relative origin resolves intended PR'
run_check 0 "$repo" 7 'relative normalization cannot introduce a rewrite'
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'unmatched rules cannot redirect normalized path'
git -C "$repo" config --unset-all "url.$TMP_ROOT/origin.git.insteadOf"
git -C "$repo" config --unset-all "url.$TMP_ROOT/other-origin.git.insteadOf"
git -C "$repo" remote set-url origin ../../origin.git
run_check 0 "$repo" 7 'relative local origin'
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'relative origin uses source directory'
git -C "$repo" remote set-url origin "$alias_url"
git -C "$repo" config 'url.../../origin.git.insteadOf' "$alias_url"
run_check 0 "$repo" 7 'relative rewrite destination'
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'relative rewrite uses source directory'
git -C "$repo" config --unset-all 'url.../../origin.git.insteadOf'
git -C "$repo" remote set-url origin "$alias_url/origin.git"
git -C "$repo" config 'url.../../.insteadOf' "$alias_url/"
run_check 0 "$repo" 7 'relative rewrite prefix with suffix'
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'rewrite directory separator preserved'
git -C "$repo" config --unset-all 'url.../../.insteadOf'
git -C "$repo" remote set-url origin "$alias_url"
git -C "$repo" config "url.$TMP_ROOT/origin.git.insteadOf" "$alias_url"
git -C "$repo" config --add remote.origin.url "$TMP_ROOT/other-origin.git"
run_check 0 "$repo" 7 'first configured fetch URL'
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'multiple URLs preserve first origin'
git -C "$repo" config --unset-all remote.origin.url
git -C "$repo" config --add remote.origin.url "$alias_url"
git -C "$repo" config --unset-all "url.$TMP_ROOT/origin.git.insteadOf"
git config --file "$TMP_ROOT/source-global" 'url.../../origin.git.insteadOf' "$alias_url"
GIT_CONFIG_GLOBAL="$TMP_ROOT/source-global" run_check 0 "$repo" 7 'global relative rewrite rule'
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'global rules retain source-relative semantics'
GIT_CONFIG_NOSYSTEM=0 GIT_CONFIG_SYSTEM="$TMP_ROOT/source-global" \
  run_check 0 "$repo" 7 'system relative rewrite rule'
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'system rules retain source-relative semantics'
git -C "$repo" config include.path "$TMP_ROOT/source-global"
run_check 0 "$repo" 7 'included relative rewrite rule'
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'included rules retain source-relative semantics'
git -C "$repo" config --unset include.path
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0='url.../../origin.git.insteadOf' GIT_CONFIG_VALUE_0="$alias_url" \
  run_check 0 "$repo" 7 'environment relative rewrite rule'
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'environment rules retain source-relative semantics'
GIT_CONFIG_PARAMETERS="'url.../../origin.git.insteadof=$alias_url'" \
  run_check 0 "$repo" 7 'parameter relative rewrite rule'
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'parameter rules retain source-relative semantics'
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0="url.$TMP_ROOT/origin.git.insteadOf" GIT_CONFIG_VALUE_0="$alias_url" \
  GIT_CONFIG_KEY_1="url.$TMP_ROOT/other-origin.git.insteadOf" GIT_CONFIG_VALUE_1="$TMP_ROOT/origin.git" \
  run_check 0 "$repo" 7 'environment rewrite chain'
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'environment rules expand exactly once'
git -C "$repo" remote set-url origin "$TMP_ROOT/origin.git"
pass 'origin rewriting, relative paths and URL selection'
cat > "$repo/fnmatch.py" <<'PY'
from pathlib import Path
Path(__file__).with_name('candidate-imported').touch()
raise SystemExit(0)
PY
(
  cd "$repo"
  run_check 0 "$repo" 7 'candidate cwd imports isolated'
  assert_equals "fresh base=$B head=$H tree=$T" "$output" 'cwd shadow cannot skip checking'
)
PYTHONPATH="$repo" run_check 0 "$repo" 7 'ambient module imports isolated'
assert_equals "fresh base=$B head=$H tree=$T" "$output" 'PYTHONPATH shadow cannot skip checking'
[ ! -e "$repo/candidate-imported" ] || fail 'candidate module executed'
rm "$repo/fnmatch.py"
mkdir "$TMP_ROOT/no-python"
bash_bin=$(command -v bash)
rc=0
output=$(PATH="$TMP_ROOT/no-python" "$bash_bin" "$cli" "$repo" 7 2>&1) || rc=$?
expect_code 2 "$rc" 'missing Python is unavailable'
assert_equals 'plan check unavailable: python3' "$output" 'missing Python diagnostic'
pass 'isolated bootstrap and missing interpreter refusal'
for mode in stale nonzero bad quoted empty timeout union view; do
  make_head "$mode"
  expected=2
  case "$mode" in stale|union|view) expected=1;; esac
  run_check "$expected" "$repo" 7 "$mode refusal"
done
make_head hang
FM_Q_PREMERGE_TIMEOUT=2 run_check 2 "$repo" 7 'actual timeout with partial fresh output'
child_code=$(cat <<'PY'
import os, pathlib, signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(os.environ['FM_Q_PREMERGE_CHILD_PID']).write_text(str(os.getpid()))
time.sleep(60)
PY
)
assert_child_stopped() {
  python3 -I - "$1" <<'PY'
import os, pathlib, signal, subprocess, sys, time
pid = int(pathlib.Path(sys.argv[1]).read_text())
for _ in range(100):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
    state = result.stdout.strip()
    if result.returncode or not state or state.startswith('Z'):
        sys.exit(0)
    time.sleep(0.01)
os.kill(pid, signal.SIGKILL)
sys.exit('timed-out descendant remains running')
PY
}
for phase in check check-union view; do
  make_head "hang-$phase"
  FM_Q_PREMERGE_CHILD_CODE="$child_code" FM_Q_PREMERGE_CHILD_PID="$TMP_ROOT/child-$phase" \
    FM_Q_PREMERGE_TIMEOUT=2 run_check 2 "$repo" 7 "$phase descendants bounded"
  assert_not_contains "$output" 'fresh base=' "$phase timeout cannot produce receipt"
  assert_child_stopped "$TMP_ROOT/child-$phase"
done
make_head good
cat > "$TMP_ROOT/transport.py" <<'PY'
import os, subprocess, sys, time
subprocess.Popen([sys.executable, '-I', '-c', os.environ['FM_Q_PREMERGE_CHILD_CODE']])
time.sleep(60)
PY
python_bin=$(command -v python3)
git -C "$repo" config core.sshCommand "$python_bin -I $TMP_ROOT/transport.py"
git -C "$repo" remote set-url origin "$(basename "$TMP_ROOT"):fixture"
GIT_SSH_VARIANT=ssh FM_Q_PREMERGE_CHILD_CODE="$child_code" FM_Q_PREMERGE_CHILD_PID="$TMP_ROOT/child-fetch" \
  FM_Q_PREMERGE_TIMEOUT=2 run_check 2 "$repo" 7 'fetch descendants bounded'
assert_not_contains "$output" 'fresh base=' 'fetch timeout cannot produce receipt'
assert_child_stopped "$TMP_ROOT/child-fetch"
git -C "$repo" remote set-url origin "$TMP_ROOT/origin.git"
git -C "$repo" config --unset core.sshCommand
pass 'timeouts terminate checker and transport descendants'
pass 'every required checker condition refuses independently'
make_head stale
printf 'print("{\"fresh\": true}")\n' > "$repo/$package/tools/check_plan.py"
git -C "$repo" add .
git -C "$repo" commit -qm malicious-checker
git -C "$repo" push -q --force origin HEAD:refs/pull/7/head
run_check 1 "$repo" 7 'BASE checker cannot be replaced by candidate'
make_head good
printf 'candidate\n' > "$repo/shared.txt"
git -C "$repo" add .
git -C "$repo" commit -qm conflict
H=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" push -q --force origin HEAD:refs/pull/7/head
rc=0
counterexample=$(git -C "$repo" merge-tree --write-tree "$B" "$H") || rc=$?
expect_code 1 "$rc" 'real merge-tree conflict'
first=${counterexample%%$'\n'*}
[ ${#first} = 40 ] || fail 'conflict still produces a tree hash'
run_check 1 "$repo" 7 'conflict must precede freshness'
pass 'real conflict tree hash does not imply success'
for target in /outside ../../outside .git/config; do
  make_head good
  ln -s "$target" "$repo/unsafe-link"
  git -C "$repo" add .
  git -C "$repo" commit -qm unsafe-link
  git -C "$repo" push -q --force origin HEAD:refs/pull/7/head
  run_check 2 "$repo" 7 'unsafe snapshot symlink refused'
done
make_head good
git -C "$repo" update-index --add --cacheinfo "160000,$O,unsupported-submodule"
git -C "$repo" commit -qm unsupported-submodule
git -C "$repo" push -q --force origin HEAD:refs/pull/7/head
run_check 2 "$repo" 7 'unsupported snapshot entry refused'
pass 'raw snapshots preserve bytes and refuse unsafe entries'
make_head good
# Each malformed BASE closure is published by the local fixture only.
for fault in malformed escaped duplicate missing absent-checker; do
  git -C "$repo" checkout -q --detach "$B"
  case "$fault" in
    malformed) printf '{' > "$repo/$package/tools/tool-closure.json";;
    escaped|duplicate|missing)
      python3 - "$repo/$package/tools/tool-closure.json" "$fault" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); b = json.loads(p.read_text())
if sys.argv[2] == 'escaped': b['members'].append('../escape')
if sys.argv[2] == 'duplicate': b['members'].append(b['members'][0])
if sys.argv[2] == 'missing': b['members'].pop()
p.write_text(json.dumps(b))
PY
      ;;
    absent-checker) git -C "$repo" rm -q "$package/tools/check_plan.py";;
  esac
  git -C "$repo" add .
  git -C "$repo" commit -qm "$fault"
  git -C "$repo" push -q --force origin HEAD:refs/heads/main
  run_check 2 "$repo" 7 "$fault closure refused"
done
git -C "$repo" push -q --force origin "$B:refs/heads/main"
make_head good
H7=$H
T7=$(git -C "$repo" merge-tree --write-tree "$B" "$H")
git -C "$repo" checkout -q --detach "$O"
printf 'second\n' > "$repo/second.txt"
git -C "$repo" add .
git -C "$repo" commit -qm second
H8=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" push -q origin HEAD:refs/pull/8/head
T8=$(git -C "$repo" merge-tree --write-tree "$B" "$H8")
before=$(git -C "$repo" show-ref; git -C "$repo" status --porcelain; git -C "$repo" rev-parse HEAD; git -C "$repo" config --local --list)
bash "$cli" "$repo" 7 > "$TMP_ROOT/seven" &
p7=$!
bash "$cli" "$repo" 8 > "$TMP_ROOT/eight" &
p8=$!
rc7=0; rc8=0
wait "$p7" || rc7=$?
wait "$p8" || rc8=$?
expect_code 0 "$rc7" 'concurrent seven exits'
expect_code 0 "$rc8" 'concurrent eight exits'
assert_equals "fresh base=$B head=$H7 tree=$T7" "$(cat "$TMP_ROOT/seven")" 'concurrent seven'
assert_equals "fresh base=$B head=$H8 tree=$T8" "$(cat "$TMP_ROOT/eight")" 'concurrent eight'
assert_equals "$before" "$(git -C "$repo" show-ref; git -C "$repo" status --porcelain; git -C "$repo" rev-parse HEAD; git -C "$repo" config --local --list)" 'parallel source unchanged'
run_check 2 "$repo" 999 'missing PR'
run_check 2 "$repo" '-7' 'invalid PR'
run_check 2 "$repo" '7;echo secret' 'command-shaped PR'
git -C "$TMP_ROOT/origin.git" update-ref -d refs/heads/main
run_check 2 "$repo" 7 'missing main'
git -C "$TMP_ROOT/origin.git" update-ref refs/heads/main "$B"
# Caller-owned untracked content survives both pass and transport failure.
printf 'caller-owned\n' > "$repo/keep"
before=$(git -C "$repo" show-ref; git -C "$repo" status --porcelain; git -C "$repo" rev-parse HEAD)
run_check 0 "$repo" 7 restored
assert_equals "$before" "$(git -C "$repo" show-ref; git -C "$repo" status --porcelain; git -C "$repo" rev-parse HEAD)" 'source refs/HEAD/status unchanged'
assert_equals caller-owned "$(cat "$repo/keep")" 'caller-owned file survives'
pass 'parallel identities and source isolation'
git -C "$repo" remote set-url origin "$TMP_ROOT/missing-private-origin"
run_check 2 "$repo" 7 'transport failure'
assert_not_contains "$output" "$TMP_ROOT/missing-private-origin" 'transport detail suppressed'
git -C "$repo" remote set-url origin "file://$TMP_ROOT/origin.git"
make_head good
mkdir -p "$repo/ops/lib/q-v2"
printf '{"backup_library":["candidate.txt"],"manual_only":[]}' > "$repo/ops/lib/q-v2/deploy.json"
printf 'ops/lib/q-v2/deploy.json export-ignore\n' >> "$repo/.gitattributes"
git -C "$repo" add .
git -C "$repo" commit -qm manual-warning
git -C "$repo" push -q --force origin HEAD:refs/pull/7/head
run_check 0 "$repo" 7 'manual warning separate from verdict'
assert_contains "$output" 'MANUAL INSTALL after merge' 'manual path warning retained'
printf '{' > "$repo/ops/lib/q-v2/deploy.json"
git -C "$repo" add .
git -C "$repo" commit -qm warning-unavailable
git -C "$repo" push -q --force origin HEAD:refs/pull/7/head
run_check 0 "$repo" 7 'unavailable warning does not change acceptance'
assert_contains "$output" 'MANUAL INSTALL warning unavailable' 'warning diagnostic'
git -C "$repo" checkout -q --detach "$B"
mkdir -p "$repo/ops/lib/q-v2" "$repo/backup" "$repo/manual"
printf '{"backup_library":["backup/source.txt","backup/destination.txt"],"manual_only":["manual/*"]}' > "$repo/ops/lib/q-v2/deploy.json"
for owner in backup manual; do
  printf 'covered %s\n' "$owner" > "$repo/$owner/source.txt"
  printf 'unlisted %s\n' "$owner" > "$repo/$owner-away.txt"
done
git -C "$repo" add .
git -C "$repo" commit -qm warning-baseline
warning_base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" push -q --force origin HEAD:refs/heads/main
for owner in backup manual; do
  for action in rename-out rename-in delete modify add copy-out; do
    git -C "$repo" checkout -q --detach "$warning_base"
    expected_path="$owner/source.txt"
    case "$action" in
      rename-out) git -C "$repo" mv "$owner/source.txt" "$owner-renamed.txt";;
      rename-in)
        git -C "$repo" mv "$owner-away.txt" "$owner/destination.txt"
        expected_path="$owner/destination.txt";;
      delete) git -C "$repo" rm -q "$owner/source.txt";;
      modify) printf 'changed\n' >> "$repo/$owner/source.txt";;
      add)
        printf 'new\n' > "$repo/$owner/destination.txt"
        expected_path="$owner/destination.txt";;
      copy-out) cp "$repo/$owner/source.txt" "$repo/$owner-copy.txt";;
    esac
    git -C "$repo" add .
    git -C "$repo" commit -qm "$owner-$action"
    H=$(git -C "$repo" rev-parse HEAD)
    T=$(git -C "$repo" merge-tree --write-tree "$warning_base" "$H")
    git -C "$repo" push -q --force origin HEAD:refs/pull/7/head
    if [ "$action" = rename-out ] || [ "$action" = rename-in ]; then
      assert_contains "$(git -C "$repo" diff --name-status --find-renames "$warning_base" "$H")" R100 'real rename witness'
    fi
    run_check 0 "$repo" 7 "$owner $action warning inventory"
    assert_contains "$output" "fresh base=$warning_base head=$H tree=$T" 'warning preserves exact verdict'
    if [ "$action" = copy-out ]; then
      assert_not_contains "$output" 'MANUAL INSTALL after merge' 'unchanged covered source needs no warning'
    else
      assert_contains "$output" "MANUAL INSTALL after merge (pre-authorize fleet-ops root step): $expected_path" 'covered endpoint warns'
    fi
  done
done
git -C "$repo" push -q --force origin "$B:refs/heads/main"
pass 'manual warnings cover both rename directions and change kinds'
make_head good
# The declared closure cannot silently degrade to the legacy path.
git -C "$repo" checkout -q --detach "$B"
git -C "$repo" rm -q "$package/tools/tool-closure.json"
git -C "$repo" commit -qm legacy
git -C "$repo" push -q --force origin HEAD:refs/heads/main
run_check 0 "$repo" 7 'legacy undeclared BASE'
pass 'legacy BASE and redacted transport failure'
