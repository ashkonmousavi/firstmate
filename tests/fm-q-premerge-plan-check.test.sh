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
args = sys.argv
repo = pathlib.Path(args[args.index('--repo') + 1]) if '--repo' in args else pathlib.Path(args[args.index('--head-repo') + 1])
mode = (repo / 'mode').read_text().strip()
if args[1] == 'check-union':
    # Verify actual scratch history and snapshots, not just freshness output.
    import subprocess
    base = args[args.index('--base-ref') + 1]
    head = args[args.index('--head-ref') + 1]
    assert subprocess.check_output(['git', '-C', str(repo), 'merge-base', base, head]).decode().strip() == base
    for flag in ('--base-repo', '--ancestor-repo'):
        assert (pathlib.Path(args[args.index(flag)+1]) / 'mode').is_file()
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
import pathlib, sys
repo = pathlib.Path(sys.argv[sys.argv.index('--repo')+1])
print('plan views: fresh')
sys.exit(2 if (repo / 'mode').read_text().strip() == 'view' else 0)
PY
printf 'good\n' > "$repo/mode"
printf 'original\n' > "$repo/shared.txt"
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
for mode in stale nonzero bad quoted empty timeout union view; do
  make_head "$mode"
  expected=2
  case "$mode" in stale|union|view) expected=1;; esac
  run_check "$expected" "$repo" 7 "$mode refusal"
done
make_head hang
FM_Q_PREMERGE_TIMEOUT=2 run_check 2 "$repo" 7 'actual timeout with partial fresh output'
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
before=$(git -C "$repo" show-ref; git -C "$repo" status --porcelain; git -C "$repo" rev-parse HEAD)
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
assert_equals "$before" "$(git -C "$repo" show-ref; git -C "$repo" status --porcelain; git -C "$repo" rev-parse HEAD)" 'parallel source unchanged'
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
make_head good
# The declared closure cannot silently degrade to the legacy path.
git -C "$repo" checkout -q --detach "$B"
git -C "$repo" rm -q "$package/tools/tool-closure.json"
git -C "$repo" commit -qm legacy
git -C "$repo" push -q --force origin HEAD:refs/heads/main
run_check 0 "$repo" 7 'legacy undeclared BASE'
pass 'legacy BASE and redacted transport failure'
