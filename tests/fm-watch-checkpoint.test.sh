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

test_short_signal_checkpoint_delivers_once() {
  local kind home status grace expected drained source
  for kind in turn-ended status mixed exact-grace fractional-grace; do
    home=$(make_home "short-signal-$kind")
    grace=default
    expected=1
    case "$kind" in
      turn-ended) printf 'finished\n' > "$home/state/demo.turn-ended" ;;
      mixed)
        printf 'finished\n' > "$home/state/demo.turn-ended"
        printf 'done: synthetic wake\n' > "$home/state/demo.status"
        expected=2
        ;;
      *) printf 'done: synthetic wake\n' > "$home/state/demo.status" ;;
    esac
    case "$kind" in exact-grace) grace=3 ;; fractional-grace) grace=2.5 ;; esac
    status=0
    if [ "$grace" = default ]; then
      fm_run_timed 10 env -u FM_SIGNAL_GRACE FM_HOME="$home" FM_POLL=1 FM_CHECK_TIMEOUT=1 \
        FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$CHECKPOINT" --seconds 3 \
        > "$home/out.txt" 2> "$home/err.txt" || status=$?
    else
      fm_run_timed 10 env FM_SIGNAL_GRACE="$grace" FM_HOME="$home" FM_POLL=1 FM_CHECK_TIMEOUT=1 \
        FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$CHECKPOINT" --seconds 3 \
        > "$home/out.txt" 2> "$home/err.txt" || status=$?
    fi
    expect_code 0 "$status" "short $kind signal: $(cat "$home/err.txt")"
    assert_contains "$(cat "$home/out.txt")" 'signal:' "short $kind signal did not surface"
    ack_checkpoint_wakes "$home"
    [ "$(awk -F '\t' '$3 == "signal" && ($4 == "demo.status" || $4 == "demo.turn-ended") {n++} END {print n+0}' "$home/drained")" -eq "$expected" ] \
      || fail "short $kind signal did not deliver each file exactly once"
    for source in "$home/state"/demo.*; do
      case "$source" in
        *.status) [ "$(cat "$source")" = 'done: synthetic wake' ] || fail 'signal delivery changed status bytes' ;;
        *.turn-ended) [ "$(cat "$source")" = finished ] || fail 'signal delivery changed turn-end bytes' ;;
      esac
    done
    status=0
    fm_run_timed 10 env -u FM_SIGNAL_GRACE FM_HOME="$home" FM_POLL=1 FM_CHECK_TIMEOUT=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$CHECKPOINT" --seconds 3 \
      > "$home/repeat.out" 2> "$home/repeat.err" || status=$?
    expect_code 124 "$status" "acknowledged $kind signal repeated"
    drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
    assert_not_contains "$drained" $'\tsignal\t' "acknowledged $kind signal was queued twice"
  done
  pass 'short checkpoints deliver status and bare turn-end signals once without spending their deadline on grace'
}

test_signal_grace_keeps_trailing_signals() {
  local mode home status real_sleep
  real_sleep=$(command -v sleep) || fail 'sleep is unavailable'
  for mode in checkpoint watcher; do
    home=$(make_home "signal-coalesce-$mode")
    mkdir -p "$home/fakebin"
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
    cat > "$home/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "$1" = 1 ] && [ ! -e "$FM_HOME/grace-entered" ]; then
  : > "$FM_HOME/grace-entered"
  printf 'working: trailing bookkeeping\n' >> "$FM_HOME/state/demo.status"
  printf 'finished\n' > "$FM_HOME/state/demo.turn-ended"
fi
exec "$FM_REAL_SLEEP" "$@"
SH
    chmod +x "$home/fakebin/sleep"
    status=0
    if [ "$mode" = checkpoint ]; then
      fm_run_timed 12 env PATH="$home/fakebin:$PATH" FM_REAL_SLEEP="$real_sleep" \
        FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
        "$CHECKPOINT" --seconds 8 > "$home/out.txt" 2> "$home/err.txt" || status=$?
    else
      fm_run_timed 12 env -u FM_WATCH_CHECKPOINT_SECONDS -u FM_CHECKPOINT_DEADLINE \
        PATH="$home/fakebin:$PATH" FM_REAL_SLEEP="$real_sleep" FM_HOME="$home" \
        FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
        "$ROOT/bin/fm-watch.sh" > "$home/out.txt" 2> "$home/err.txt" || status=$?
    fi
    expect_code 0 "$status" "$mode signal coalescing failed: $(cat "$home/err.txt")"
    [ -f "$home/grace-entered" ] || fail "$mode skipped an affordable grace"
    ack_checkpoint_wakes "$home"
    [ "$(awk -F '\t' '$3 == "signal" && $4 == "demo.status" {n++} END {print n+0}' "$home/drained")" -eq 1 ] \
      || fail "$mode lost or duplicated the done status behind its trailing working note"
    [ "$(awk -F '\t' '$3 == "signal" && $4 == "demo.turn-ended" {n++} END {print n+0}' "$home/drained")" -eq 1 ] \
      || fail "$mode lost or duplicated the second discovery pass's turn-end"
  done
  pass 'affordable checkpoint grace and ordinary watcher grace coalesce trailing signals without hiding done'
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

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

make_mate_checkpoint_home() {
  local home
  home=$(make_sweep_home "$1" 0)
  mkdir -p "$home/child/state"
  printf 'mate\n' > "$home/child/.fm-secondmate-home"
  printf 'kind=secondmate\nbackend=tmux\nharness=codex\nwindow=fixture:mate\nhome=%s/child\n' "$home" > "$home/state/mate.meta"
  printf '100\t7\tcheck\trouted\tcheck: retained child row\n' > "$home/child/state/.wake-queue"
  printf '%s\t100-7\n' "$(( $(date +%s) - 5 ))" > "$home/state/.secondmate-wake-progress-mate"
  touch "$home/state/.secondmate-liveness-tick"
  printf '%s\n' "$home"
}

run_mate_checkpoint() {
  local home=$1
  shift
  MATE_RC=0
  fm_run_timed 18 env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_POLL=1 FM_CHECK_TIMEOUT=1 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_WAKE_STALL_SECS=1 "$CHECKPOINT" "$@" > "$home/out.txt" 2> "$home/err.txt" || MATE_RC=$?
}

ack_checkpoint_wakes() {
  local home=$1 seq generation
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" > "$home/drained" 2> "$home/drain.err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$home/drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$home/drain.err")
  [ -n "$seq" ] && [ -n "$generation" ] || fail 'missing generation-bound recovery acknowledgement'
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" >/dev/null || fail 'recovery acknowledgement failed'
}

test_secondmate_stall_read_is_bounded_and_resumes() {
  local home before started elapsed i
  home=$(make_mate_checkpoint_home sibling-stall)
  before=$(cat "$home/state/mate.meta" "$home/child/state/.wake-queue" "$home/state/.secondmate-wake-progress-mate")
  started=$SECONDS
  FM_FIXTURE_CAPTURE_DELAY=30 run_mate_checkpoint "$home" --seconds 3
  elapsed=$((SECONDS - started))
  expect_code 124 "$MATE_RC" "secondmate stall checkpoint: $(cat "$home/err.txt")"
  [ "$elapsed" -le 6 ] || fail "stall read exceeded independent close bound: ${elapsed}s"
  assert_contains "$(cat "$home/out.txt")" 'checkpoint: no actionable wake within 3s' 'stall read missed the quiet contract'
  [ -s "$home/captures" ] || fail 'the stall capture was never entered'
  [ "$before" = "$(cat "$home/state/mate.meta" "$home/child/state/.wake-queue" "$home/state/.secondmate-wake-progress-mate")" ] || fail 'timed-out observation changed child custody or progress'
  [ ! -s "$home/state/.wake-queue" ] || fail 'unknown stalled observation produced a wake'
  assert_absent "$home/state/.secondmate-wake-stall-mate" 'unknown stalled observation completed the tick'
  for i in 1 2 3 4; do
    FM_FIXTURE_CAPTURE_DELAY=0 run_mate_checkpoint "$home" --seconds 3
    [ "$MATE_RC" -ne 0 ] || break
    expect_code 124 "$MATE_RC" 'resumed stall observation failed'
  done
  expect_code 0 "$MATE_RC" 'the restored stall owner never resumed'
  assert_contains "$(cat "$home/out.txt")" 'secondmate wake-loop stalled: mate=mate row=7' 'restored owner lost its row'
  [ "$(awk -F '\t' '$3 == "check" && $4 == "secondmate-wake-loop-mate-100-7" { n++ } END { print n+0 }' "$home/state/.wake-queue")" -eq 1 ] || fail 'restored stall row was not delivered exactly once'
  ack_checkpoint_wakes "$home"
  FM_FIXTURE_CAPTURE_DELAY=0 run_mate_checkpoint "$home" --seconds 3
  expect_code 124 "$MATE_RC" 'acknowledged stall was replayed'
  pass 'secondmate capture exhaustion preserves the row and resumes one acknowledged wake'
}

test_short_checkpoint_hands_relaunch_to_foreground_owner_once() {
  local home before i
  home=$(make_mate_checkpoint_home sibling-relaunch)
  rm -f "$home/state/.secondmate-liveness-tick" "$home/child/state/.wake-queue"
  mkdir -p "$home/fixture-root/bin"
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in list-windows) printf 'main\n'; exit 0 ;; esac
exit 1
SH
  cat > "$home/fixture-root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/spawn-entered"
sleep 1
exit 0
SH
  chmod +x "$home/fixture-root/bin/fm-spawn.sh"
  before=$(cat "$home/state/mate.meta")
  FM_ROOT_OVERRIDE="$home/fixture-root" run_mate_checkpoint "$home" --seconds 3
  expect_code 0 "$MATE_RC" "short recovery admission: $(cat "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" 'recovery cycle required for relaunch mate' 'short checkpoint failed to hand back the owed recovery'
  assert_absent "$home/spawn-entered" 'short checkpoint started the indivisible spawn'
  assert_absent "$home/state/.secondmate-relaunch-mate" 'deferral consumed a relaunch attempt'
  assert_absent "$home/state/.secondmate-liveness-tick" 'deferral completed liveness cadence'
  [ "$before" = "$(cat "$home/state/mate.meta")" ] || fail 'deferral changed ownership'
  FM_ROOT_OVERRIDE="$home/fixture-root" run_mate_checkpoint "$home" --seconds 3
  expect_code 0 "$MATE_RC" 'a repeated short checkpoint bypassed its owed recovery'
  assert_absent "$home/spawn-entered" 'repeated short checkpoint admitted the spawn'
  for i in 1 2; do
    FM_ROOT_OVERRIDE="$home/fixture-root" run_mate_checkpoint "$home" --recover
    expect_code 0 "$MATE_RC" "foreground recovery cycle $i: $(cat "$home/err.txt")"
  done
  [ "$(wc -l < "$home/spawn-entered")" -eq 1 ] || fail 'the recovery owner spawned more than once'
  [ "$(awk -F '\t' '$2 == "attempt" {n++} END {print n+0}' "$home/state/.secondmate-relaunch-mate")" -eq 1 ] || fail 'wrong relaunch attempt count'
  [ "$(awk -F '\t' '$2 == "relaunched" {n++} END {print n+0}' "$home/state/.secondmate-relaunch-mate")" -eq 1 ] || fail 'missing exactly one successful relaunch outcome'
  [ "$(awk -F '\t' '$3 == "check" && $4 ~ /^secondmate-relaunch-mate-/ {n++} END {print n+0}' "$home/state/.wake-queue")" -eq 1 ] || fail 'wrong successful recovery wake count'
  ack_checkpoint_wakes "$home"
  FM_ROOT_OVERRIDE="$home/fixture-root" run_mate_checkpoint "$home" --seconds 3
  expect_code 124 "$MATE_RC" 'handled recovery did not return to ordinary quiet supervision'
  pass 'short checkpoints preserve recovery and the explicit foreground owner completes it once'
}

test_sibling_pending_observation_preserves_unknown() {
  local home corr rec
  home=$(make_mate_checkpoint_home sibling-reply)
  rm -f "$home/child/state/.wake-queue"
  corr=$(FM_HOME="$home" bash -c '. "$1"; corr=$(fm_pending_reply_create "$2" "$2/state" mate "report the retained work"); fm_pending_reply_mark_delivered "$2/state" "$corr"; printf "%s\n" "$corr"' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$home")
  rec="$home/state/pending-replies/$corr"
  FM_FIXTURE_CAPTURE_DELAY=30 run_mate_checkpoint "$home" --seconds 3
  expect_code 124 "$MATE_RC" "pending observation: $(cat "$home/err.txt")"
  [ -s "$home/captures" ] || fail 'pending-reply capture was not exercised'
  grep -Fxq 'phase=awaiting_report' "$rec" || fail 'a timed-out observation closed the expectation'
  grep -Fxq 'request_turn_completed_epoch=' "$rec" || fail 'unknown became a completed turn'
  grep -Fxq 'recovery_attempted_epoch=' "$rec" || fail 'unknown started recovery'
  [ ! -s "$home/state/.wake-queue" ] || fail 'unknown became a missed-report wake'
  pass 'pending-reply read exhaustion retains the expectation without a fabricated completion'
}

test_capacity_read_cannot_starve_later_lane() {
  local home i
  home=$(make_sweep_home sibling-capacity 0)
  printf '2\n' > "$home/config/writing-lane-cap"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/ready-entered"
sleep 30
printf 'ready[0]\n'
SH
  chmod +x "$home/fakebin/tasks-axi"
  run_mate_checkpoint "$home" --seconds 3
  expect_code 124 "$MATE_RC" "capacity read: $(cat "$home/err.txt")"
  [ -s "$home/ready-entered" ] || fail 'the capacity owner was not exercised'
  assert_absent "$home/state/.last-idle-lane-check" 'incomplete capacity read completed its cadence'
  [ ! -s "$home/state/.wake-queue" ] || fail 'unknown ready data became a capacity wake'
  printf 'kind=ship\nbackend=tmux\nharness=codex\nwindow=fixture:later\n' > "$home/state/later.meta"
  printf '%s 4242\n' "$(date +%s)" > "$home/state/later.prompt-waiting"
  for i in 1 2 3; do
    run_mate_checkpoint "$home" --seconds 3
    [ "$MATE_RC" -ne 0 ] || break
    expect_code 124 "$MATE_RC" 'deferred global read failed on continuation'
  done
  expect_code 0 "$MATE_RC" 'a hung early owner permanently starved the later lane'
  assert_contains "$(cat "$home/out.txt")" 'stale: fixture:later (a permission or question prompt is waiting in the pane)' 'later lane witness missing'
  ack_checkpoint_wakes "$home"
  pass 'an expired capacity owner leaves cadence due and cannot starve a later recorded lane'
}

test_inactive_read_shares_deadline_and_keeps_cadence_due() {
  local home
  home=$(make_sweep_home sibling-inactive 1)
  touch -t 202001010000 "$home/state/lane-001.meta"
  cat > "$home/fakebin/inactive-state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/inactive-entered"
sleep 30
printf 'state: done · source: status · delayed outcome\n'
SH
  chmod +x "$home/fakebin/inactive-state"
  FM_INACTIVE_CREW_STATE_BIN="$home/fakebin/inactive-state" run_mate_checkpoint "$home" --seconds 3
  expect_code 124 "$MATE_RC" "inactive read: $(cat "$home/err.txt")"
  [ -s "$home/inactive-entered" ] || fail 'inactive reconciliation was not exercised'
  grep -Fxq 'complete=0' "$home/state/.inactive-outcome-reconcile" || fail 'incomplete scan consumed cadence'
  [ ! -s "$home/state/.wake-queue" ] || fail 'a timed-out state read fabricated a terminal outcome'
  pass 'inactive reconciliation shares the checkpoint deadline and retains its incomplete cursor'
}

test_unknown_liveness_keeps_checkpoint_cadence_due() {
  local home
  home=$(make_mate_checkpoint_home unknown-liveness)
  rm -f "$home/state/.secondmate-liveness-tick" "$home/child/state/.wake-queue"
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/agent-reads"
exit 1
SH
  run_mate_checkpoint "$home" --seconds 3
  expect_code 124 "$MATE_RC" 'unknown liveness checkpoint'
  [ -s "$home/agent-reads" ] || fail 'unknown endpoint observation was not exercised'
  assert_absent "$home/state/.secondmate-liveness-tick" 'unknown checkpoint observation completed cadence'
  assert_absent "$home/state/.secondmate-relaunch-mate" 'unknown endpoint started recovery'
  [ ! -s "$home/state/.wake-queue" ] || fail 'unknown endpoint produced a recovery verdict'
  run_mate_checkpoint "$home" --recover
  expect_code 0 "$MATE_RC" 'ordinary recovery owner with an unknown endpoint'
  [ -e "$home/state/.secondmate-liveness-tick" ] || fail 'ordinary unbounded liveness cadence changed'
  assert_absent "$home/state/.secondmate-relaunch-mate" 'ordinary unknown endpoint started recovery'
  pass 'unknown checkpoint observations leave cadence due without changing ordinary supervision'
}

test_queue_contention_preserves_park_and_surfaces_known_sibling() {
  local home now i
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK FM_HOME FM_STATE_OVERRIDE
  home=$(make_sweep_home queue-contention 0)
  FM_HOME=$home
  FM_STATE_OVERRIDE="$home/state"
  printf 'kind=secondmate\nbackend=tmux\nharness=codex\nwindow=unreadable:unknown\n' > "$home/state/a-unknown.meta"
  printf 'kind=secondmate\nbackend=tmux\nharness=codex\nwindow=fixture:mate\n' > "$home/state/mate.meta"
  now=$(date +%s)
  for i in 1 2 3; do printf '%s\tattempt\n' "$now" >> "$home/state/.secondmate-relaunch-mate"; done
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows)
    case "$*" in *unreadable*) exit 1 ;; esac
    printf 'main\n'; exit 0 ;;
esac
exit 1
SH
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$FM_WAKE_QUEUE_LOCK" || fail 'could not hold the fixture queue'
  run_mate_checkpoint "$home" --seconds 3
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  expect_code 124 "$MATE_RC" "contended queue checkpoint: $(cat "$home/err.txt")"
  assert_absent "$home/state/.secondmate-relaunch-bound-mate" 'an unpublished wake consumed its park marker'
  assert_absent "$home/state/.secondmate-liveness-tick" 'contention completed cadence'
  [ ! -s "$home/state/.wake-queue" ] || fail 'contention fabricated a queued wake'
  for i in 1 2 3 4; do
    run_mate_checkpoint "$home" --seconds 3
    [ "$MATE_RC" -ne 0 ] || break
    expect_code 124 "$MATE_RC" 'queue contention continuation failed'
  done
  expect_code 0 "$MATE_RC" 'restored queue suppressed the known sibling wake'
  assert_contains "$(cat "$home/out.txt")" 'auto-relaunch paused after 3 attempts' 'known sibling wake missing'
  [ -e "$home/state/.secondmate-relaunch-bound-mate" ] || fail 'durable known wake lacks its park marker'
  assert_absent "$home/state/.secondmate-liveness-tick" 'unknown sibling completed checkpoint cadence'
  [ "$(awk -F '\t' '$3 == "check" && $4 == "secondmate-relaunch-bound-mate" {n++} END {print n+0}' "$home/state/.wake-queue")" -eq 1 ] || fail 'known sibling wake was not queued once'
  [ "$(awk -F '\t' '$2 == "attempt" {n++} END {print n+0}' "$home/state/.secondmate-relaunch-mate")" -eq 3 ] || fail 'contention consumed an extra recovery attempt'
  ack_checkpoint_wakes "$home"
  pass 'contended startup preserves ownership and an unknown sibling cannot suppress a durable known wake'
}

test_checkpoint_deadline_is_scoped_to_watch_reads() {
  local home status=0
  home=$(make_home deadline-scope)
  printf 'kind=ship\nwindow=fixture:scope\n' > "$home/state/scope.meta"
  FM_HOME="$home" FM_WATCH_CHECKPOINT_SECONDS=3 bash -c '
    . "$1/bin/fm-watch.sh"
    [ -n "$FM_CHECKPOINT_DEADLINE" ] || exit 1
    result=$(bash -c '\''[ -z "${FM_CHECKPOINT_DEADLINE:-}" ] || exit 9; . "$1"; fm_meta_get "$2" window'\'' _ "$1/bin/fm-backend.sh" "$2/state/scope.meta")
    [ "$result" = fixture:scope ] || exit 1
    captured=$(checkpoint_read fm_backend_meta_for_window fixture:scope "$2/state")
    [ "$captured" = "$2/state/scope.meta" ]
  ' _ "$ROOT" "$home" || status=$?
  expect_code 0 "$status" 'watch deadline leaked into ordinary child metadata reads or lost its bounded read context'
  pass 'watch deadlines stay scoped to observations and do not alter ordinary child consumers'
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_short_signal_checkpoint_delivers_once
test_signal_grace_keeps_trailing_signals
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

test_secondmate_stall_read_is_bounded_and_resumes
test_short_checkpoint_hands_relaunch_to_foreground_owner_once
test_sibling_pending_observation_preserves_unknown
test_capacity_read_cannot_starve_later_lane
test_inactive_read_shares_deadline_and_keeps_cadence_due

test_unknown_liveness_keeps_checkpoint_cadence_due
test_queue_contention_preserves_park_and_surfaces_known_sibling
test_checkpoint_deadline_is_scoped_to_watch_reads
