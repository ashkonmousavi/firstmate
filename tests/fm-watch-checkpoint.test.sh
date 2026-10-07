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
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
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

# A home opted into the supervision host whose checkpoint runs a stub host in
# a fixture code root: the stub records the bound it was given, then closes
# the way $FM_HOME/host-kind says.
make_host_home() {  # <name>
  local home
  home=$(make_home "$1")
  mkdir -p "$home/root/bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/root/bin/fm-supervision-engine-lib.sh"
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
  local home f
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
  # Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
  # QUIET), so the checkpoint keeps its attended bound beside it.
  for f in fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh; do cp "$ROOT/bin/$f" "$home/root/bin/$f"; done
  rm -f "$home/state/.afk-contract"
  FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "fixture: could not record quiet mode"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a park beside a quiet record that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/host-env")" 'park=5' "beside a quiet record the host must park for the attended bound"
  pass "checkpoint: an opted-in home runs the host for the checkpoint's bound, raised only while away"
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

# The Codex owner stays file-gated: without config/supervision-host, or with
# config/supervision-host-off, the checkpoint never runs the host.
test_host_checkpoint_needs_the_file_and_honors_off() {
  local home line
  home=$(make_host_home host-gate)
  for line in - off; do
    rm -f "$home/config/supervision-host" "$home/config/supervision-host-off" "$home/host-env"
    [ "$line" = - ] || : > "$home/config/supervision-host-off"
    run_host_checkpoint "$home" boundary --seconds 1
    [ ! -e "$home/host-env" ] || fail "a Codex home whose config/supervision-host is ${line/-/absent} ran the supervision host"
  done
  pass "checkpoint: a Codex home without config/supervision-host, or with an off file, never runs the host"
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
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$fakebin/codex" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$0" --seconds 4
  ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 124 "$status" "a quiet host checkpoint: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 4s" "the real host's boundary must read as the quiet line"
  assert_grep '	boundary	' "$home/state/.supervision-host.log" "the host must have ended its own park"
  if [ -e "$home/state/.watch.lock/pid" ] && kill -0 "$(cat "$home/state/.watch.lock/pid")" 2>/dev/null; then
    fail "a host checkpoint left its watcher running"
  fi
  pass "checkpoint: the real host ends its park at the checkpoint bound as a quiet checkpoint"
}

# Real checkpoint and queue; only the terminal read is controlled. Each read
# finishes in one second, so a long inventory exposes aggregate deadline loss
# independently of a hung backend, registered checks, or competing lock.
make_sweep_home() {  # <name> <lanes>
  local home i id
  home=$(make_home "$1")
  mkdir -p "$home/fakebin"
  touch "$home/state/.last-check" "$home/state/.last-heartbeat" "$home/state/home-summary.json"
  for ((i=1; i<=$2; i++)); do
    printf -v id 'lane-%03d' "$i"
    printf 'kind=ship\nbackend=tmux\nharness=codex\nwindow=fixture:%s\n' "$id" > "$home/state/$id.meta"
  done
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  capture-pane)
    printf '%s\n' "$*" >> "$FM_HOME/captures"
    case "$*" in *fixture:lane-001*) sleep "${FM_FIXTURE_FIRST_CAPTURE_DELAY:-${FM_FIXTURE_CAPTURE_DELAY:-1}}" ;; *) sleep "${FM_FIXTURE_CAPTURE_DELAY:-1}" ;; esac
    exit 1 ;;
esac
exit 1
SH
  chmod +x "$home/fakebin/tmux"
  printf '%s\n' "$home"
}

run_sweep_checkpoint() {  # <home> [seconds]
  local home=$1 seconds=${2:-3}
  SWEEP_RC=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_POLL=1 FM_CHECK_TIMEOUT=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$CHECKPOINT" --seconds "$seconds" \
    > "$home/out.txt" 2> "$home/err.txt" || SWEEP_RC=$?
}

test_recorded_sweep_closes_at_checkpoint_budget() {
  local home count
  for count in 1 18; do
    home=$(make_sweep_home "sweep-$count" "$count")
    run_sweep_checkpoint "$home"
    expect_code 124 "$SWEEP_RC" "recorded sweep ($count lanes): $(cat "$home/err.txt")"
    assert_contains "$(cat "$home/out.txt")" 'checkpoint: no actionable wake within 3s' 'sweep did not close cleanly'
    assert_absent "$home/state/.watch.lock/pid" 'quiet sweep retained singleton'
    [ -s "$home/captures" ] || fail 'sweep control never reached a pane read'
  done
  [ "$(wc -l < "$home/captures")" -lt 18 ] || fail 'long sweep ignored deadline and visited every lane'
  pass 'checkpoint bounds long recorded sweeps and preserves the short control'
}

test_slow_pane_read_obeys_remaining_budget() {
  local home
  home=$(make_sweep_home stuck-read 1)
  FM_FIXTURE_CAPTURE_DELAY=30 run_sweep_checkpoint "$home"
  expect_code 124 "$SWEEP_RC" "slow pane read: $(cat "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" 'checkpoint: no actionable wake within 3s' 'slow read missed clean close'
  pass 'checkpoint bounds one stalled pane read without an outer-watchdog failure'
}

test_deferred_later_lane_survives_and_is_delivered_once() {
  local home i before after drained seq generation
  home=$(make_sweep_home fair-sweep 8)
  mkdir -p "$home/state/lane-008.inbox/handled"
  printf 'preserve pending instruction\n' > "$home/state/lane-008.inbox/001.msg"
  # A fresh message stays below the inbox ladder deadline during this test.
  printf '%s 4242\n' "$(date +%s)" > "$home/state/lane-008.prompt-waiting"
  before=$(cat "$home/state/lane-008.meta" "$home/state/lane-008.inbox/001.msg")
  run_sweep_checkpoint "$home"
  expect_code 124 "$SWEEP_RC" 'the first budget must defer the later lane'
  for i in 1 2 3 4 5 6 7 8; do
    run_sweep_checkpoint "$home"
    [ "$SWEEP_RC" -ne 0 ] || break
    expect_code 124 "$SWEEP_RC" "deferred cycle $i failed"
  done
  expect_code 0 "$SWEEP_RC" 'later lane was starved across repeated checkpoints'
  assert_contains "$(cat "$home/out.txt")" 'stale: fixture:lane-008 (a permission or question prompt is waiting in the pane)' 'wrong later-lane witness'
  after=$(cat "$home/state/lane-008.meta" "$home/state/lane-008.inbox/001.msg")
  [ "$before" = "$after" ] || fail 'budget exhaustion mutated lane custody or pending inbox'
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2> "$home/drain.err")
  [ "$(printf '%s\n' "$drained" | grep -c $'\tstale\tfixture:lane-008\t')" -eq 1 ] || fail 'later wake was not queued exactly once'
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$home/drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$home/drain.err")
  [ -n "$seq" ] && [ -n "$generation" ] || fail 'missing generation-bound acknowledgement'
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" >/dev/null || fail 'acknowledgement failed'
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
  assert_not_contains "$drained" $'\tstale\tfixture:lane-008\t' 'acknowledged witness replayed'
  FM_FIXTURE_CAPTURE_DELAY=0 run_sweep_checkpoint "$home"
  expect_code 124 "$SWEEP_RC" 'ordinary complete sweep replayed the surfaced later-lane wake'
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
  assert_not_contains "$drained" $'\tstale\tfixture:lane-008\t' 'complete sweep requeued acknowledged witness'
  pass 'deferred later lane retains custody and delivers one generation-bound wake'
}

# Duplicate recorded targets are already supported by the inventory's dedup.
# A stalled endpoint must not pin continuation to its first metadata alias.
test_duplicate_target_cannot_pin_sweep_continuation() {
  local home i
  home=$(make_sweep_home duplicate-target 3)
  cp "$home/state/lane-001.meta" "$home/state/lane-002.meta"
  printf '%s 4242\n' "$(date +%s)" > "$home/state/lane-003.prompt-waiting"
  for i in 1 2 3 4; do
    FM_FIXTURE_FIRST_CAPTURE_DELAY=30 run_sweep_checkpoint "$home"
    [ "$SWEEP_RC" -ne 0 ] || break
    expect_code 124 "$SWEEP_RC" "duplicate target checkpoint $i"
  done
  expect_code 0 "$SWEEP_RC" 'duplicate metadata pinned continuation before the later lane'
  assert_contains "$(cat "$home/out.txt")" 'stale: fixture:lane-003 (a permission or question prompt is waiting in the pane)' 'duplicate-target witness missing'
  pass 'duplicate recorded targets cannot pin checkpoint continuation'
}

# A pane read can finish promptly while its dependent crew-state read stalls.
# Preseed stable pane observations through their public state format so this
# cycle reaches real stale triage without waiting for three poll cycles.
test_slow_crew_read_defers_without_false_stale() {
  local home hash
  home=$(make_sweep_home slow-crew 1)
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in capture-pane) printf 'idle pane\n'; exit 0 ;; esac
exit 1
SH
  cat > "$home/fakebin/crew-state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/crew-reads"
sleep 30
printf 'state: working · source: run-step · delayed verdict\n'
SH
  chmod +x "$home/fakebin/crew-state"
  if command -v md5 >/dev/null 2>&1; then hash=$(printf 'idle pane' | md5 -q); else hash=$(printf 'idle pane' | md5sum | cut -d' ' -f1); fi
  printf '%s' "$hash" > "$home/state/.hash-fixture_lane-001"
  printf '2\n' > "$home/state/.count-fixture_lane-001"
  # The three-second sweep fixture can legitimately expire before this seam.
  # Twelve seconds leaves setup headroom (including a controlled four-second
  # setup delay in the causal check); the thirty-second read still exceeds it.
  FM_CREW_STATE_BIN="$home/fakebin/crew-state" run_sweep_checkpoint "$home" 12
  expect_code 124 "$SWEEP_RC" "slow crew read: $(cat "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" 'checkpoint: no actionable wake within 12s' 'crew read missed clean close'
  [ -s "$home/crew-reads" ] || fail 'dependent read was never exercised'
  [ ! -s "$home/state/.wake-queue" ] || fail 'exhausted read became an actionable verdict'
  assert_absent "$home/state/.stale-fixture_lane-001" 'exhausted read suppressed the unclassified pane'
  pass 'checkpoint defers a slow dependent crew read without inventing a stale verdict'
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_host_checkpoint_bounds_the_park_by_posture
test_host_checkpoint_passes_a_handback_and_reports_a_stand_down
test_host_checkpoint_needs_the_file_and_honors_off
test_real_host_checkpoint_ends_quietly_at_its_bound

test_recorded_sweep_closes_at_checkpoint_budget
test_slow_pane_read_obeys_remaining_budget
test_deferred_later_lane_survives_and_is_delivered_once

test_slow_crew_read_defers_without_false_stale

test_duplicate_target_cannot_pin_sweep_continuation
