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

test_codex_routes_to_checkpoint_supervision_and_fresh_handoff_is_healthy() {
  local home model verdict
  home=$(make_home codex-model)
  model=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_supervision_model' _ \
    "$ROOT/bin/fm-wake-lib.sh")
  [ "$model" = checkpoint ] \
    || fail "Codex ancestry must select checkpoint supervision, got: $model"
  touch "$home/state/.last-watcher-beat"
  verdict=$(FM_STATE_OVERRIDE="$home/state" FM_SUPERVISION_MODEL=checkpoint bash -c '
    . "$1"
    fm_watcher_supervision_verdict "$2/state" "$1/../fm-watch.sh" 300 "$2" "$1/.."
    printf "%s %s\n" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home")
  [ "$verdict" = "true stale-beacon" ] \
    || fail "a fresh completed Codex checkpoint must be a healthy bounded handoff, got: $verdict"
  pass "Codex startup selects checkpoint supervision and a fresh bounded handoff is healthy"
}

test_pause_preserves_pending_event_and_resume_handles_it_once() {
  local home out status drained first_count queued_before queued_after
  home=$(make_home pause-resume)
  FM_HOME="$home" "$CHECKPOINT" pause --seconds 30 >/dev/null \
    || fail "could not deliberately pause checkpoint supervision"
  printf 'done: pending through pause\n' > "$home/state/pending.status"
  status=0
  FM_HOME="$home" "$CHECKPOINT" --seconds 1 >"$home/paused.out" 2>"$home/paused.err" || status=$?
  expect_code 75 "$status" "paused checkpoint exit"
  assert_absent "$home/state/.wake-queue" "a paused checkpoint consumed the pending event"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" resume --seconds 8 >"$home/resume.out" 2>"$home/resume.err" || status=$?
  expect_code 0 "$status" "resume checkpoint exit"
  out=$(cat "$home/resume.out")
  assert_contains "$out" "signal:" "resume did not surface the pending event"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  first_count=$(printf '%s\n' "$drained" | grep -c $'\tsignal\tpending.status\t' || true)
  [ "$first_count" -eq 1 ] || fail "resume must queue the pending event exactly once, got $first_count rows"
  queued_before=$(wc -l < "$home/state/.wake-queue" | tr -d '[:space:]')

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" resume --seconds 1 >"$home/resume-second.out" 2>"$home/resume-second.err" || status=$?
  expect_code 124 "$status" "second resume checkpoint exit"
  # Contract change: drain presentation is not acknowledgement, so the original
  # durable row remains until the supervising actor runs --ack-through. Prove
  # exactly-once handling by showing the second checkpoint added no row.
  queued_after=$(wc -l < "$home/state/.wake-queue" | tr -d '[:space:]')
  [ "$queued_after" -eq "$queued_before" ] \
    || fail "a second resume re-queued an already presented event ($queued_before -> $queued_after rows)"
  pass "deliberate pause preserves an event and resume handles it exactly once"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_codex_routes_to_checkpoint_supervision_and_fresh_handoff_is_healthy
test_pause_preserves_pending_event_and_resume_handles_it_once
