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

track_ordinary_child_release() {
  ORDINARY_CHILD_RELEASES+=("$1")
  ORDINARY_CHILD_PIDFILES+=("$2")
}

cleanup_ordinary_child_releases() {
  local index release pid tries refused=0
  for release in "${ORDINARY_CHILD_RELEASES[@]+"${ORDINARY_CHILD_RELEASES[@]}"}"; do
    : > "$release" || refused=1
  done
  for index in "${!ORDINARY_CHILD_RELEASES[@]}"; do
    release=${ORDINARY_CHILD_RELEASES[$index]}
    pid=$(sed -n '1p' "${ORDINARY_CHILD_PIDFILES[$index]}" 2>/dev/null) || pid=
    case "$pid" in ''|*[!0-9]*|0|1) refused=1; continue ;; esac
    tries=0
    while fm_test_process_running "$pid" && [ "$tries" -lt 600 ]; do
      sleep 0.1
      tries=$((tries + 1))
    done
    if fm_test_process_running "$pid"; then
      refused=1
    else
      wait "$pid" 2>/dev/null || true
    fi
    [ ! -e "$release.expired" ] || refused=1
  done
  if [ "$refused" = 1 ]; then
    printf 'REFUSED: fixture release or termination unproved; preserving roots\n' >&2
    return 1
  fi
}

ordinary_child_cleanup_exit() {
  local rc=$1
  trap - EXIT
  trap '' HUP INT TERM QUIT
  if ! cleanup_ordinary_child_releases; then
    [ "$rc" -ne 0 ] || rc=1
    exit "$rc"
  fi
  fm_test_cleanup_exit "$rc"
}

own_ordinary_child_releases() {
  ORDINARY_CHILD_RELEASES=()
  ORDINARY_CHILD_PIDFILES=()
  trap 'ordinary_child_cleanup_exit "$?"' EXIT
  trap 'ordinary_child_cleanup_exit 130' INT
  trap 'ordinary_child_cleanup_exit 143' TERM
  trap 'ordinary_child_cleanup_exit 129' HUP
  trap 'ordinary_child_cleanup_exit 131' QUIT
}

own_ordinary_child_releases

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

assert_ordinary_child_terminal() {
  local pid=$1 state
  kill -0 "$pid" 2>/dev/null || return 0
  state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$state" in *Z*) return 0 ;; esac
  kill -0 "$pid" 2>/dev/null || return 0
  printf 'not ok - ordinary fixture child %s survived terminal return\n' "$pid" >&2
  return 1
}

test_ordinary_children_are_gone_before_fixture_removal() {
  local cleanup=${1:-production} harness repo mode rc pid root receipt terminal_rc expected_terminal=0
  if [ "$cleanup" = disabled ]; then expected_terminal=1; fi
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
if [ "$CHILD_CLEANUP" = disabled ]; then
  fm_test_reap_processes() { return 0; }
fi
root=$(fm_test_tmproot fm-test-child-producer)
mkdir -p "$root"
bash "$CHILD_HOLDER" "$root" "$CHILD_RECEIPT.release" </dev/null >/dev/null 2>&1 &
pid=$!
printf '%s\n%s\n' "$pid" "$root" > "$CHILD_RECEIPT"
# The original helper has no ordinary-child registration interface.
if declare -F fm_test_track_process >/dev/null; then
  fm_test_track_process "$pid" "$root" || fail 'owned child registration failed'
  cp "$FM_TEST_PROCESS_REGISTRY" "$CHILD_RECEIPT.provenance"
fi
if [ "$CHILD_OUTCOME" = failure ]; then fail 'original assertion failure'; fi
SH
  for mode in success failure; do
    receipt="$harness/$cleanup-$mode.receipt"
    track_ordinary_child_release "$receipt.release" "$receipt"
    rc=0
    CHILD_LIB="$LIB" CHILD_RECEIPT="$receipt" CHILD_OUTCOME="$mode" \
      CHILD_CLEANUP="$cleanup" CHILD_HOLDER="$harness/child.sh" \
      TMPDIR="$harness/tmp" bash "$repo/bin/fm-test-run.sh" --jobs 1 \
      tests/fm-test-run.test.sh > "$harness/$cleanup-$mode.log" 2>&1 || rc=$?
    if [ "$mode" = success ]; then
      expect_code 0 "$rc" "ordinary child cleanup changed the successful verdict"
    else
      expect_code 1 "$rc" "ordinary child cleanup changed the failing verdict"
      assert_grep 'original assertion failure' "$harness/$cleanup-$mode.log" "original failure was lost"
    fi
    pid=$(sed -n '1p' "$receipt")
    root=$(sed -n '2p' "$receipt")
    terminal_rc=0
    assert_ordinary_child_terminal "$pid" > "$receipt.terminal.log" 2>&1 || terminal_rc=$?
    assert_absent "$receipt.release" "a release owner masked the terminal observation"
    assert_absent "$receipt.release.expired" "natural expiry falsely satisfied terminal cleanup"
    assert_absent "$root" "registered fixture root survived terminal return"
    expect_code "$expected_terminal" "$terminal_rc" "ordinary child terminal assertion ignored $cleanup cleanup"
    if [ "$cleanup" = disabled ]; then
      assert_grep 'survived terminal return' "$receipt.terminal.log" "counterfactual failed outside the terminal assertion"
    fi
    printf 'FM_TEST_CHILD_TERMINAL cleanup=%s outcome=%s runner_exit=%s terminal_assertion_exit=%s released_at_observation=false expired=false\n' \
      "$cleanup" "$mode" "$rc" "$terminal_rc"
    cat "$receipt.provenance" "$receipt.terminal.log"
    release_ordinary_child "$pid" "$receipt.release"
  done
  if [ "$cleanup" = disabled ]; then
    pass "shared-cleanup counterfactual fails both terminal assertions before outer release"
  else
    pass "public runner retains success/failure verdicts and terminalizes ordinary children before root removal"
  fi
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
    if [ "$mode" != exited ]; then
      track_ordinary_child_release "$harness/$mode.release" "$harness/$mode.pid"
    fi
    if [ "$mode" = unrelated ]; then
      track_ordinary_child_release "$harness/$mode.other-release" "$harness/$mode.other"
    fi
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
      track_ordinary_child_release "$receipt.release" "$receipt.pid"
      track_ordinary_child_release "$receipt.other-release" "$receipt.other"
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

test_ordinary_child_release_owner_on_failure_and_signal() {
  local harness repo site outcome receipt rc expected other pid tries state
  harness=$(fm_test_tmproot fm-test-child-release-owner)
  repo="$harness/runner"
  mkdir -p "$repo/bin" "$repo/tests" "$harness/tmp" "$harness/fakebin"
  cp "$ROOT/bin/fm-test-run.sh" "$repo/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  write_ordinary_child_fixture "$harness/child.sh"
  cat > "$harness/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
set -u
if [ -z "${CHILD_POLLER_RELEASE:-}" ]; then exec "$REAL_SLEEP" "$@"; fi
printf '%s\n' "$$" > "$CHILD_POLLER_RELEASE.poller"
deadline=$((SECONDS + 300))
while [ ! -e "$CHILD_POLLER_RELEASE" ] && [ "$SECONDS" -lt "$deadline" ]; do "$REAL_SLEEP" 0.1; done
[ -e "$CHILD_POLLER_RELEASE" ] || : > "$CHILD_POLLER_RELEASE.expired"
SH
  cat > "$harness/fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  if [ "$arg" = "$(cat "$CHILD_RECEIPT.root" 2>/dev/null)" ]; then
    for file in "$CHILD_RECEIPT.pid" "$CHILD_RECEIPT.release.poller"; do
      pid=$(cat "$file")
      state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
      printf '%s\t%s\t%s\n' "$file" "$pid" "$state" >> "$CHILD_RECEIPT.before-removal"
      case "$state" in ''|*Z*) ;; *) : > "$CHILD_RECEIPT.live-before-removal" ;; esac
    done
    state=$(ps -p "$CHILD_OTHER_PID" -o stat= 2>/dev/null || true)
    case "$state" in ''|*Z*) : > "$CHILD_RECEIPT.unrelated-stopped" ;; esac
  fi
done
exec "$REAL_RM" "$@"
SH
  chmod +x "$harness/fakebin/sleep" "$harness/fakebin/rm"
  cat > "$repo/tests/fm-test-run.test.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$CHILD_LIB"
SH
  declare -f track_ordinary_child_release cleanup_ordinary_child_releases \
    ordinary_child_cleanup_exit own_ordinary_child_releases \
    write_ordinary_child_fixture >> "$repo/tests/fm-test-run.test.sh"
  cat >> "$repo/tests/fm-test-run.test.sh" <<'SH'
own_ordinary_child_releases
cd "$CHILD_EXTERNAL" || exit 1
root=$(fm_test_tmproot fm-test-release-subject)
printf '%s\n' "$root" > "$CHILD_RECEIPT.root"
write_ordinary_child_fixture "$root/child.sh"
track_ordinary_child_release "$CHILD_RECEIPT.release" "$CHILD_RECEIPT.pid"
CHILD_POLLER_RELEASE="$CHILD_RECEIPT.release" \
  bash "$root/child.sh" "$root" "$CHILD_RECEIPT.release" </dev/null >/dev/null 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$CHILD_RECEIPT.pid"
tries=0
while [ ! -s "$CHILD_RECEIPT.release.poller" ] && [ "$tries" -lt 600 ]; do
  "$REAL_SLEEP" 0.1
  tries=$((tries + 1))
done
[ -s "$CHILD_RECEIPT.release.poller" ] || fail 'holder did not start its polling descendant'
printf '%s\n%s\n%s\n' "$$" "$(fm_test_process_birth "$$")" "$(pwd -P)" > "$CHILD_RECEIPT.subject"
printf '%s\n%s\n' "$(fm_test_process_birth "$pid")" "$(fm_test_process_cwd "$pid")" > "$CHILD_RECEIPT.provenance"
case "$CHILD_SITE" in
  ordinary-success|ordinary-failure|ownership-owned|lookup-owned)
    fm_test_track_process "$pid" "$root" || fail 'release-control registration failed' ;;
esac
case "$CHILD_SITE" in
  ownership-owned) printf '%s\twrong-birth\t%s\n' "$pid" "$root" > "$FM_TEST_PROCESS_REGISTRY" ;;
  lookup-owned) fm_test_process_cwd() { return 1; } ;;
esac
kill() {
  if [ "$1" != -0 ]; then : > "$CHILD_RECEIPT.signalled"; fi
  builtin kill "$@"
}
: > "$CHILD_RECEIPT.ready"
if [ "$CHILD_OUTCOME" = failure ]; then fail 'original early assertion before release'; fi
deadline=$((SECONDS + 300))
while [ ! -e "$CHILD_RECEIPT.release" ] && [ "$SECONDS" -lt "$deadline" ]; do "$REAL_SLEEP" 0.1; done
if [ "$SECONDS" -ge "$deadline" ]; then fail 'termination control reached emergency deadline'; fi
SH
  for site in ordinary-success ordinary-failure ownership-owned ownership-unrelated lookup-owned lookup-unrelated; do
    for outcome in failure term; do
      receipt="$harness/$site-$outcome"
      track_ordinary_child_release "$receipt.release" "$receipt.pid"
      track_ordinary_child_release "$receipt.other-release" "$receipt.other"
      bash "$harness/child.sh" "$harness" "$receipt.other-release" </dev/null >/dev/null 2>&1 &
      other=$!
      printf '%s\n' "$other" > "$receipt.other"
      CHILD_LIB="$LIB" CHILD_SITE="$site" CHILD_OUTCOME="$outcome" \
        CHILD_RECEIPT="$receipt" CHILD_EXTERNAL="$harness" CHILD_OTHER_PID="$other" \
        REAL_SLEEP="$(command -v sleep)" REAL_RM="$(command -v rm)" \
        PATH="$harness/fakebin:$PATH" TMPDIR="$harness/tmp" \
        bash "$repo/bin/fm-test-run.sh" --jobs 1 tests/fm-test-run.test.sh > "$receipt.log" 2>&1 &
      pid=$!
      if [ "$outcome" = term ]; then
        tries=0
        while [ ! -e "$receipt.ready" ] && [ "$tries" -lt 600 ]; do
          sleep 0.1
          tries=$((tries + 1))
        done
        [ -e "$receipt.ready" ] || fail 'termination subject never became ready'
        local subject birth cwd
        subject=$(sed -n '1p' "$receipt.subject")
        birth=$(sed -n '2p' "$receipt.subject")
        cwd=$(sed -n '3p' "$receipt.subject")
        assert_equals "$birth" "$(fm_test_process_birth "$subject")" 'termination subject birth changed'
        assert_equals "$cwd" "$(fm_test_process_cwd "$subject")" 'termination subject cwd changed'
        kill -TERM "$subject" || fail 'could not terminate the owned fixture subject'
      fi
      rc=0
      wait "$pid" || rc=$?
      expect_code 1 "$rc" "public runner changed $site/$outcome failure status"
      expected=1
      if [ "$outcome" = term ]; then expected=143; fi
      assert_grep "exit=$expected " "$receipt.log" "subject changed its $site/$outcome verdict"
      if [ "$outcome" = failure ]; then
        assert_grep 'original early assertion before release' "$receipt.log" 'original failure was lost'
      fi
      assert_present "$receipt.before-removal" 'control did not observe root removal'
      assert_absent "$receipt.live-before-removal" 'holder or polling descendant survived until root removal'
      assert_absent "$receipt.unrelated-stopped" 'release cleanup stopped the unrelated child'
      assert_absent "$receipt.signalled" 'release cleanup signalled an unproved holder'
      assert_absent "$receipt.release.expired" 'holder expired before release ownership could be proved'
      assert_absent "$(cat "$receipt.root")" 'subject fixture root survived release cleanup'
      state=$(ps -p "$other" -o stat= 2>/dev/null || true)
      case "$state" in ''|*Z*) fail 'unrelated child did not survive subject exit' ;; esac
      printf 'FM_TEST_RELEASE_CONTROL site=%s outcome=%s subject_exit=%s holder_pid=%s poller_pid=%s unrelated_pid=%s unrelated_state=%s root_removed=true signalled=false expired=false\n' \
        "$site" "$outcome" "$expected" "$(cat "$receipt.pid")" "$(cat "$receipt.release.poller")" "$other" "$state"
      printf 'holder_birth=%s holder_cwd=%s\n' "$(sed -n '1p' "$receipt.provenance")" "$(sed -n '2p' "$receipt.provenance")"
      cat "$receipt.before-removal"
      release_ordinary_child "$other" "$receipt.other-release"
    done
  done
  pass "EXIT release ownership preserves failure and TERM verdicts, stops holders and polling descendants before root removal, and preserves unrelated children"
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
    cd "$1" || exit 1
    # shellcheck source=tests/lib.sh
    . "$2"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "$3"
    while :; do sleep 0.1; done
  ' _ "$harness" "$LIB" "$dirfile" &
  pid=$!
  fm_test_track_process "$pid" "$harness" || fail 'fixture child registration failed'
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
    cd "$1" || exit 1
    # shellcheck source=tests/lib.sh
    . "$2"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "$3"
    while :; do sleep 0.1; done
  ' _ "$harness" "$LIB" "$dirfile" &
  pid=$!
  fm_test_track_process "$pid" "$harness" || fail 'fixture child registration failed'
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
    export FM_TEST_SKIP_ORPHAN_REAP=1
    cd "$1" || exit 1
    # shellcheck source=tests/lib.sh
    . "$2"
    d=$(fm_test_tmproot fm-test-cleanup-gitroot)
    printf "%s\n" "$d" > "$3"
    # Hold the suite open so a concurrent add would see any root-side leak.
    while :; do sleep 0.1; done
  ' _ "$repo" "$LIB" "$dirfile" &
  pid=$!
  fm_test_track_process "$pid" "$repo" || fail 'fixture child registration failed'
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

test_ordinary_children_are_gone_before_fixture_removal disabled
test_ordinary_children_are_gone_before_fixture_removal
test_ordinary_child_ownership_controls
test_ordinary_child_exit_during_ownership_lookup
test_ordinary_child_release_owner_on_failure_and_signal
test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_registries_avoid_git_worktree_root
