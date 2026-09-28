#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status i owner
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  i=0
  while [ -e "$home/state/.watch.lock/pid" ] && [ "$i" -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ -e "$home/state/.watch.lock/pid" ]; then
    owner=$(cat "$home/state/.watch.lock/pid")
    printf 'quiet timeout lock owner: %s; stderr: %s\n' "$owner" "$(cat "$err")" >&2
    ps -o pid=,ppid=,pgid=,stat=,comm=,args= -p "$owner" >&2 || true
    fail 'watch lock pid survived quiet checkpoint timeout'
  fi
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_consecutive_quiet_checkpoints_stay_quiet() {
  local home status round
  home=$(make_home quiet-succession)
  for round in 1 2; do
    status=0
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
      "$CHECKPOINT" --seconds 2 >"$home/out-$round.txt" 2>"$home/err-$round.txt" || status=$?
    expect_code 124 "$status" "quiet checkpoint $round: $(cat "$home/out-$round.txt" "$home/err-$round.txt")"
    assert_contains "$(cat "$home/out-$round.txt")" 'checkpoint: no actionable wake within 2s' \
      "quiet checkpoint $round did not reach its bound"
    assert_not_contains "$(cat "$home/out-$round.txt")" 'check: rearm-resurface' \
      "quiet checkpoint $round falsely reported watcher downtime"
  done
  assert_absent "$home/state/.watcher-down" 'normal quiet succession left a recovery marker'
  pass 'successive bounded quiet checkpoints do not manufacture downtime'
}

test_outer_timeout_after_lock_acquisition_is_failure() {
  local home out err status owner
  home=$(make_home post-lock-timeout)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_CHECK_TIMEOUT=1 \
    FM_TEST_WATCHER_POST_LOCK_DELAY=20 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "post-lock outer timeout checkpoint exit"
  assert_contains "$(cat "$err")" 'watcher exceeded the quiet bound without a clean close' \
    'an interrupted watcher was misreported as a normal quiet checkpoint'
  if [ -e "$home/state/.watch.lock/pid" ]; then
    owner=$(cat "$home/state/.watch.lock/pid")
    printf 'lock owner after timeout: %s\n' "$owner" >&2
    ps -o pid=,ppid=,pgid=,stat=,comm=,args= -p "$owner" >&2 || true
    fail 'timeout left the acquired watcher lock behind'
  fi
  [ -f "$home/state/.watcher-down" ] || fail 'an interrupted watcher did not publish downtime'
  pass "an outer timeout after lock acquisition fails and preserves downtime"
}

test_killed_watcher_is_reclaimed_by_checkpoint() {
  local home out err status checkpoint owner i
  home=$(make_home killed-watcher)
  out="$home/out.txt"
  err="$home/err.txt"
  fm_test_track_watcher_state "$home/state"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_TEST_WATCHER_POST_LOCK_DELAY=5 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" &
  checkpoint=$!
  i=0
  while [ ! -s "$home/state/.watch.lock/pid" ] && [ "$i" -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$home/state/.watch.lock/pid" ] || fail 'fixture watcher never acquired its lock'
  owner=$(cat "$home/state/.watch.lock/pid")
  kill -KILL "$owner" || fail 'could not kill the exact fixture watcher'
  status=0
  wait "$checkpoint" || status=$?
  [ "$status" -ne 0 ] || fail 'a killed watcher returned a successful checkpoint'
  assert_absent "$home/state/.watch.lock/pid" 'killed watcher left a stale lock after checkpoint returned'
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 3 >"$home/recovery-out.txt" 2>"$home/recovery-err.txt" || status=$?
  expect_code 0 "$status" "genuine watcher loss recovery: $(cat "$home/recovery-out.txt" "$home/recovery-err.txt")"
  assert_contains "$(cat "$home/recovery-out.txt")" 'check: rearm-resurface' \
    'a killed watcher did not surface real downtime on the next checkpoint'
  pass 'checkpoint reclaims a dead fixture watcher without claiming supervision'
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

# A crew signal just before the bound must not hold the watcher in its default
# 30-second coalescing linger past the outer backstop.
test_signal_near_bound_closes_before_backstop() {
  local home out err status
  home=$(make_home signal-near-bound)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 2
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  env -u FM_SIGNAL_GRACE FM_HOME="$home" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_CHECK_TIMEOUT=1 \
    "$CHECKPOINT" --seconds 4 >"$out" 2>"$err" || status=$?
  wait
  case "$status" in
    0) assert_contains "$(cat "$out")" 'signal:' 'the near-bound signal was not passed through' ;;
    124) assert_absent "$home/state/.watcher-down" 'a quiet close near the bound manufactured downtime' ;;
    *) fail "signal near the bound failed the checkpoint ($status): $(cat "$out" "$err")" ;;
  esac
  pass 'a signal near the checkpoint bound lingers only until the bound'
}

# A check sweep that reaches the bound defers its unrun checks instead of
# running every check past the outer backstop.
test_check_sweep_stops_at_bound() {
  local home out err status i ran
  home=$(make_home check-sweep-bound)
  out="$home/out.txt"
  err="$home/err.txt"
  for i in 01 02 03 04 05 06 07 08 09 10; do
    cat > "$home/state/slow-$i.check.sh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "$i" >> "$home/checks-ran"
sleep 2
SH
    chmod 0700 "$home/state/slow-$i.check.sh"
    FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" "slow-$i" >/dev/null \
      || fail "could not register slow check $i"
  done
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=3 \
    "$CHECKPOINT" --seconds 3 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "check sweep at the bound: $(cat "$out" "$err")"
  assert_absent "$home/state/.watcher-down" 'a check sweep at the bound manufactured downtime'
  ran=$(wc -l < "$home/checks-ran" 2>/dev/null || echo 0)
  [ "$ran" -ge 1 ] && [ "$ran" -lt 10 ] || fail "expected a partial sweep, ran $ran checks"
  pass 'a check sweep stops starting checks at the checkpoint bound'
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# A watcher that already surfaced its wake has consumed it, so a checkpoint
# that then fails to settle must still show that wake before failing.
test_unsettled_checkpoint_still_shows_its_wake() {
  local home status
  home=$(make_home unsettled-wake)
  mkdir -p "$home/root/bin"
  cp "$CHECKPOINT" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" "$home/root/bin/"
  cat > "$home/root/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
mkdir "$FM_HOME/state/.watch.lock"
printf '%s\n' "$FM_TEST_LIVE_OWNER" > "$FM_HOME/state/.watch.lock/pid"
printf 'signal: demo.status\n'
SH
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-watch.sh"
  status=0
  FM_HOME="$home" FM_TEST_LIVE_OWNER=$$ "$home/root/bin/fm-watch-checkpoint.sh" --seconds 5 \
    >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "a checkpoint that cannot settle the watcher lock fails"
  assert_contains "$(cat "$home/out.txt")" "signal: demo.status" "the surfaced wake was dropped"
  assert_contains "$(cat "$home/err.txt")" "watcher lock still has a live or unverified owner" \
    "the unsettled watcher lock was not reported"
  pass "checkpoint: a surfaced wake still passes through when the checkpoint cannot settle"
}

# A home opted into the supervision host whose checkpoint runs a stub host in
# a fixture code root: the stub records the bound it was given, then closes
# the way $FM_HOME/host-kind says.
make_host_home() {  # <name>
  local home
  home=$(make_home "$1")
  mkdir -p "$home/root/bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" "$home/root/bin/"
  cat > "$home/root/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\nprimary=%s\npark=%s\nlimit=%s\n' "$*" "${FM_SUPERVISION_HOST_PRIMARY:-}" \
  "${FM_SUPERVISION_HOST_PARK_SECONDS:-}" "${FM_SUPERVISION_HOST_PARK_LIMIT:-}" > "$FM_HOME/host-env"
case "$(cat "$FM_HOME/host-kind")" in
  boundary) printf 'supervision-host: cycle boundary - fixture\n' ;;
  handback)
    printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
    printf 'signal: demo.status\nsupervision-host: the away session could not take this wake: fixture; this wake is yours\n'
    ;;
  stood-down) printf 'supervision-host stood down: this session no longer owns supervision\n' ;;
esac
SH
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-supervision-host.sh"
  : > "$home/config/supervision-host"
  printf '%s\n' "$home"
}

run_host_checkpoint() {  # <home> <kind> [checkpoint args...]; sets STATUS
  local home=$1
  printf '%s\n' "$2" > "$home/host-kind"
  shift 2
  STATUS=0
  FM_HOME="$home" "$home/root/bin/fm-watch-checkpoint.sh" "$@" >"$home/out.txt" 2>"$home/err.txt" || STATUS=$?
}

test_host_checkpoint_bounds_the_park_by_posture() {
  local home
  home=$(make_host_home host-bound)
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a host park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 5s" "the boundary must read as the ordinary quiet line"
  assert_contains "$(cat "$home/host-env")" $'args=park\nprimary=codex\npark=5\nlimit=1235' \
    "attended, the host must park for the checkpoint's own bound with the codex pin and a turn limit past it"
  : > "$home/state/.afk-contract"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "an away park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 3600s" "away, the bound must be raised"
  assert_contains "$(cat "$home/host-env")" 'park=3600' "away, the host must park for the away bound"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 5
  assert_contains "$(cat "$home/host-env")" 'park=900' "the away bound must be configurable"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 1000
  assert_contains "$(cat "$home/host-env")" 'park=1000' "the away bound must never shorten a longer checkpoint"
  pass "checkpoint: an opted-in home runs the host for the checkpoint's bound, raised while away"
}

test_host_checkpoint_passes_a_handback_and_reports_a_stand_down() {
  local home
  home=$(make_host_home host-handback)
  run_host_checkpoint "$home" handback --seconds 5
  expect_code 0 "$STATUS" "a handed-back wake is an actionable checkpoint"
  assert_contains "$(cat "$home/out.txt")" $'signal: demo.status\nsupervision-host: the away session could not take this wake' \
    "the wake and its host line must pass through"
  assert_not_contains "$(cat "$home/out.txt")" "watcher: started" "the host's cycle status is not part of the wake"
  run_host_checkpoint "$home" stood-down --seconds 5
  expect_code 1 "$STATUS" "a host that stood down is a failed checkpoint"
  assert_contains "$(cat "$home/out.txt")" "supervision-host stood down" "the stand-down must be shown"
  pass "checkpoint: a handed-back wake passes through, and a host stand-down is a failure"
}

# The real host under a fake Codex harness that holds the home's session lock.
# shellcheck disable=SC2016 # the fake harness's script expands in its own shell
test_real_host_checkpoint_ends_quietly_at_its_bound() {
  local home fakebin status
  home=$(make_home host-real)
  : > "$home/config/supervision-host"
  fakebin="$TMP_ROOT/host-real-bin"
  mkdir -p "$fakebin"
  ln -s /bin/bash "$fakebin/codex"
  status=0
  CODEX_SESSION_ID=fixture-checkpoint FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$fakebin/codex" -c '
    "$1/bin/fm-lock.sh" >/dev/null || exit 1
    "$0" --seconds 4
  ' "$CHECKPOINT" "$ROOT" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 124 "$status" "a quiet host checkpoint: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 4s" "the real host's boundary must read as the quiet line"
  assert_grep '	boundary	' "$home/state/.supervision-host.log" "the host must have ended its own park"
  if [ -e "$home/state/.watch.lock/pid" ] && kill -0 "$(cat "$home/state/.watch.lock/pid")" 2>/dev/null; then
    fail "a host checkpoint left its watcher running"
  fi
  pass "checkpoint: the real host ends its park at the checkpoint bound as a quiet checkpoint"
}

test_quiet_checkpoint_exits_124_cleanly
test_consecutive_quiet_checkpoints_stay_quiet
test_outer_timeout_after_lock_acquisition_is_failure
test_killed_watcher_is_reclaimed_by_checkpoint
test_signal_passes_through_and_exits_zero
test_signal_near_bound_closes_before_backstop
test_check_sweep_stops_at_bound
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_unsettled_checkpoint_still_shows_its_wake
test_host_checkpoint_bounds_the_park_by_posture
test_host_checkpoint_passes_a_handback_and_reports_a_stand_down
test_real_host_checkpoint_ends_quietly_at_its_bound
