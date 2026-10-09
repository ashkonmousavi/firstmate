#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

write_ordinary_child_fixture() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
set -u
cd "$1" || exit 1
release=$2
deadline=$((SECONDS + 300))
while [ ! -e "$release" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then : > "$release.expired"; exit 0; fi
  sleep 0.1
done
SH
}

release_ordinary_child() {
  local pid=$1 release=$2 tries=0
  assert_absent "$release.expired" "fixture child expired before observation finished"
  : > "$release"
  while fm_test_process_running "$pid" && [ "$tries" -lt 600 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  if fm_test_process_running "$pid"; then fail 'released fixture child did not exit'; fi
}

test_ordinary_children_are_gone_before_fixture_removal() {
  local harness repo mode rc pid root state observed="" bad=0
  harness=$(fm_test_tmproot fm-test-child-terminal)
  repo="$harness/runner"
  mkdir -p "$repo/bin" "$repo/tests" "$harness/tmp"
  write_ordinary_child_fixture "$harness/child.sh"
  cp "$ROOT/bin/fm-test-run.sh" "$repo/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cat > "$repo/tests/fm-test-run.test.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$CHILD_LIB"
root=$(fm_test_tmproot fm-test-child-producer)
mkdir -p "$root"
bash "$CHILD_HOLDER" "$root" "$CHILD_RECEIPT.release" </dev/null >/dev/null 2>&1 &
pid=$!
printf '%s\n%s\n' "$pid" "$root" > "$CHILD_RECEIPT"
# The original helper has no ordinary-child registration interface.
if declare -F fm_test_track_process >/dev/null; then
  fm_test_track_process "$pid" "$root" || fail 'owned child registration failed'
fi
if [ "$CHILD_OUTCOME" = failure ]; then fail 'original assertion failure'; fi
SH
  for mode in success failure; do
    rc=0
    CHILD_LIB="$LIB" CHILD_RECEIPT="$harness/$mode.receipt" CHILD_OUTCOME="$mode" \
      CHILD_HOLDER="$harness/child.sh" \
      TMPDIR="$harness/tmp" bash "$repo/bin/fm-test-run.sh" --jobs 1 \
      tests/fm-test-run.test.sh > "$harness/$mode.log" 2>&1 || rc=$?
    if [ "$mode" = success ]; then
      expect_code 0 "$rc" "ordinary child cleanup changed the successful verdict"
    else
      expect_code 1 "$rc" "ordinary child cleanup changed the failing verdict"
      assert_grep 'original assertion failure' "$harness/$mode.log" "original failure was lost"
    fi
    pid=$(sed -n '1p' "$harness/$mode.receipt")
    root=$(sed -n '2p' "$harness/$mode.receipt")
    state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
    case "$state" in
      ''|*Z*) ;;
      *) bad=1; observed="$observed $mode:pid=$pid state=$state root=$root" ;;
    esac
    assert_absent "$harness/$mode.receipt.release.expired" "natural expiry falsely satisfied terminal cleanup"
    release_ordinary_child "$pid" "$harness/$mode.receipt.release"
    assert_absent "$root" "registered fixture root survived proven terminal cleanup"
  done
  if [ "$bad" = 1 ]; then
    fail "ordinary fixture children survived terminal return/root deletion:$observed"
  fi
  pass "public runner retains success/failure verdicts and terminalizes ordinary children before root removal"
}

test_ordinary_child_ownership_controls() {
  local harness mode rc pid root other state expected
  harness=$(fm_test_tmproot fm-test-child-controls)
  mkdir -p "$harness/tmp"
  write_ordinary_child_fixture "$harness/child.sh"
  cat > "$harness/producer.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$CHILD_LIB"
root=$(fm_test_tmproot fm-test-child-owned)
mkdir -p "$root"
printf '%s\n' "$root" > "$CHILD_RECEIPT.root"
if [ "$CHILD_CONTROL" = exited ]; then
  (cd "$root" && exit 0) &
  pid=$!
  wait "$pid"
  fm_test_track_process "$pid" "$root" || fail 'already-exited registration refused'
  exit 0
fi
bash "$CHILD_HOLDER" "$root" "$CHILD_RECEIPT.release" </dev/null >/dev/null 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$CHILD_RECEIPT.pid"
if [ "$CHILD_CONTROL" = substitution ]; then
  registered=$(fm_test_track_process "$pid" "$root") || fail 'substitution registration refused'
  [ -z "$registered" ] || fail 'registration unexpectedly wrote stdout'
elif [ "$CHILD_CONTROL" != unregistered ]; then
  fm_test_track_process "$pid" "$root" || fail 'registration refused'
fi
case "$CHILD_CONTROL" in
  unrelated)
    bash "$CHILD_HOLDER" "$CHILD_EXTERNAL" "$CHILD_RECEIPT.other-release" </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$CHILD_RECEIPT.other" ;;
  birth)
    # Corrupt only this isolated ownership receipt, representing a reused PID.
    printf '%s\twrong-birth\t%s\n' "$pid" "$root" > "$FM_TEST_PROCESS_REGISTRY" ;;
  cwd) fm_test_process_cwd() { return 1; } ;;
  stat-live)
    fm_test_process_cwd() { return 1; }
    ps() {
      if [ "$*" = "-p $pid -o stat=" ]; then return 1; else command ps "$@"; fi
    } ;;
  missing) rm -f "$FM_TEST_PROCESS_REGISTRY" ;;
  unregistered)
    fm_test_track_process "$pid" "$CHILD_EXTERNAL" \
      && fail 'unregistered cwd was accepted' ;;
esac
SH
  for mode in exited substitution unrelated birth cwd stat-live missing unregistered; do
    rc=0
    CHILD_LIB="$LIB" CHILD_CONTROL="$mode" CHILD_RECEIPT="$harness/$mode" \
      CHILD_EXTERNAL="$harness" CHILD_HOLDER="$harness/child.sh" TMPDIR="$harness/tmp" \
      bash "$harness/producer.sh" > "$harness/$mode.log" 2>&1 || rc=$?
    root=$(cat "$harness/$mode.root")
    case "$mode" in
      birth|cwd|stat-live|missing|unregistered) expected=1 ;;
      *) expected=0 ;;
    esac
    expect_code "$expected" "$rc" "ordinary-child ownership control $mode changed its verdict"
    if [ "$expected" = 1 ]; then
      assert_grep REFUSED "$harness/$mode.log" "control $mode hid its ownership refusal"
      assert_present "$root" "control $mode erased its diagnostic fixture on refusal"
      pid=$(cat "$harness/$mode.pid")
      state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
      case "$state" in ''|*Z*) fail "control $mode signalled a child without proved ownership" ;; esac
      release_ordinary_child "$pid" "$harness/$mode.release"
    else
      assert_absent "$harness/$mode.release.expired" "control $mode ended by natural expiry"
      assert_absent "$root" "control $mode retained a safely cleaned fixture"
      if [ "$mode" = unrelated ]; then
        other=$(cat "$harness/$mode.other")
        state=$(ps -p "$other" -o stat= 2>/dev/null || true)
        case "$state" in ''|*Z*) fail 'ordinary cleanup signalled the unrelated child' ;; esac
        release_ordinary_child "$other" "$harness/$mode.other-release"
      fi
    fi
  done
  pass "ordinary-child cleanup persists registration across substitutions, permits exited children, and refuses missing or changed ownership without signalling unrelated children"
}

test_ordinary_child_exit_during_ownership_lookup() {
  local harness mode outcome rc expected root pid other state receipt
  harness=$(fm_test_tmproot fm-test-child-lookup)
  mkdir -p "$harness/tmp"
  write_ordinary_child_fixture "$harness/child.sh"
  cat > "$harness/producer.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$CHILD_LIB"
root=$(fm_test_tmproot fm-test-child-race)
printf '%s\n' "$root" > "$CHILD_RECEIPT.root"
bash "$CHILD_HOLDER" "$root" "$CHILD_RECEIPT.release" </dev/null >/dev/null 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$CHILD_RECEIPT.pid"
bash "$CHILD_HOLDER" "$CHILD_EXTERNAL" "$CHILD_RECEIPT.other-release" </dev/null >/dev/null 2>&1 &
printf '%s\n' "$!" > "$CHILD_RECEIPT.other"
kill() {
  if [ "$1" != -0 ]; then printf '%s\n' "$*" >> "$CHILD_RECEIPT.signals"; fi
  builtin kill "$@"
}
exit_during_lookup() {
  local tries=0
  : > "$CHILD_RECEIPT.lookup"
  : > "$CHILD_RECEIPT.release"
  while fm_test_process_running "$pid" && [ "$tries" -lt 600 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  fm_test_process_running "$pid" && fail 'child did not exit during lookup'
  return 1
}
if [[ "$CHILD_RACE" = cleanup-* ]]; then
  fm_test_track_process "$pid" "$root" || fail 'initial registration refused'
fi
case "$CHILD_RACE" in
  registration-birth|readiness-birth|cleanup-birth)
    fm_test_process_birth() {
      if [ "$CHILD_RACE" = readiness-birth ] && [ ! -e "$CHILD_RECEIPT.first-birth" ]; then
        : > "$CHILD_RECEIPT.first-birth"
        bash -c '. "$1"; fm_codex_pid_birth "$2"' _ "$ROOT/bin/fm-session-lock-lib.sh" "$1"
      else
        exit_during_lookup
      fi
    } ;;
  readiness-timeout)
    fm_test_process_cwd() {
      local calls=0
      if [ -e "$CHILD_RECEIPT.cwd-calls" ]; then read -r calls < "$CHILD_RECEIPT.cwd-calls"; fi
      calls=$((calls + 1))
      printf '%s\n' "$calls" > "$CHILD_RECEIPT.cwd-calls"
      if [ "$calls" -eq 50 ]; then exit_during_lookup; else return 1; fi
    } ;;
  readiness-cwd|cleanup-cwd)
    fm_test_process_cwd() { exit_during_lookup; } ;;
  cleanup-stat)
    fm_test_process_cwd() { : > "$CHILD_RECEIPT.cwd-failed"; return 1; }
    ps() {
      if [ "$*" = "-p $pid -o stat=" ] && [ -e "$CHILD_RECEIPT.cwd-failed" ]; then
        local tries=0
        : > "$CHILD_RECEIPT.lookup"
        : > "$CHILD_RECEIPT.release"
        while builtin kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 600 ]; do
          sleep 0.1
          tries=$((tries + 1))
        done
        builtin kill -0 "$pid" 2>/dev/null && fail 'child did not disappear during stat lookup'
        return 1
      fi
      command ps "$@"
    } ;;
  ancestry)
    ps() {
      if [ "$*" = "-p $pid -o ppid=" ]; then exit_during_lookup; else command ps "$@"; fi
    } ;;
esac
case "$CHILD_RACE" in
  cleanup-*) ;;
  *) fm_test_track_process "$pid" "$root" || fail 'terminal child registration refused' ;;
esac
if [ "$CHILD_OUTCOME" = failure ]; then fail 'original assertion failure'; fi
SH
  for mode in registration-birth ancestry readiness-birth readiness-cwd readiness-timeout cleanup-cwd cleanup-birth cleanup-stat; do
    for outcome in success failure; do
      receipt="$harness/$mode-$outcome"
      rc=0
      CHILD_LIB="$LIB" CHILD_RACE="$mode" CHILD_OUTCOME="$outcome" \
        CHILD_RECEIPT="$receipt" CHILD_EXTERNAL="$harness" CHILD_HOLDER="$harness/child.sh" TMPDIR="$harness/tmp" \
        bash "$harness/producer.sh" > "$receipt.log" 2>&1 || rc=$?
      expected=0
      if [ "$outcome" = failure ]; then expected=1; fi
      expect_code "$expected" "$rc" "exit during $mode changed the $outcome verdict"
      if [ "$outcome" = failure ]; then
        assert_grep 'original assertion failure' "$receipt.log" "exit during $mode lost the original failure"
      fi
      assert_present "$receipt.lookup" "control $mode did not reach the lookup race"
      if grep -q REFUSED "$receipt.log"; then fail "terminal child was refused during $mode"; fi
      root=$(cat "$receipt.root")
      assert_absent "$receipt.release.expired" "child expired before the $mode race"
      assert_absent "$root" "exit during $mode retained the fixture root"
      assert_absent "$receipt.signals" "exit during $mode sent a signal"
      pid=$(cat "$receipt.pid")
      state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
      case "$state" in ''|*Z*) ;; *) fail "child remained live after $mode" ;; esac
      other=$(cat "$receipt.other")
      state=$(ps -p "$other" -o stat= 2>/dev/null || true)
      case "$state" in ''|*Z*) fail "exit during $mode stopped the unrelated child" ;; esac
      release_ordinary_child "$other" "$receipt.other-release"
    done
  done
  pass "ownership lookup races accept terminal children without signalling and preserve success/failure verdicts"
}

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

test_registries_avoid_git_worktree_root() {
  # A TMPDIR pointed at a repository root used to place live `.fm-test-*`
  # registries beside tracked files. A concurrent git add during a suite then
  # committed them (observed on the claim-walk CI fix round). The helper must
  # keep registries and fixture roots outside that root for the whole run.
  local harness repo dirfile child_dir pid tries entry
  harness=$(fm_test_tmproot fm-test-cleanup-gitroot-harness)
  repo="$harness/repo"
  dirfile="$harness/child-dir"
  mkdir -p "$repo"
  git -C "$repo" init -q
  bash -c '
    export TMPDIR="$1"
    # shellcheck source=tests/lib.sh
    . "$2"
    d=$(fm_test_tmproot fm-test-cleanup-gitroot)
    printf "%s\n" "$d" > "$3"
    # Hold the suite open so a concurrent add would see any root-side leak.
    while :; do sleep 0.1; done
  ' _ "$repo" "$LIB" "$dirfile" &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the git-root TMPDIR child never published its fixture root"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the git-root TMPDIR child did not create a fixture root"
  case "$child_dir" in
    "$repo"|"$repo"/*)
      fail "fm_test_tmproot placed a fixture root inside the git worktree root: $child_dir"
      ;;
  esac
  for entry in "$repo"/.fm-test-cleanup.* "$repo"/.fm-test-process.* "$repo"/.fm-test-procevent.* "$repo"/.fm-test-watcher.*; do
    [ ! -e "$entry" ] || fail "a live test registry landed in the git worktree root: $entry"
  done
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  assert_absent "$child_dir" \
    "the git-root TMPDIR child's fixture root survived SIGTERM"
  pass "test registries and fixture roots stay out of a git worktree TMPDIR"
}

test_ordinary_children_are_gone_before_fixture_removal
test_ordinary_child_ownership_controls
test_ordinary_child_exit_during_ownership_lookup
test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_registries_avoid_git_worktree_root
