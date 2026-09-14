#!/usr/bin/env bash
# tests/fm-watch-gate-nudge.test.sh - the watcher's gate-nudge ladder
# (bin/fm-watch.sh's gate_nudge_check, over bin/fm-classify-lib.sh's
# crew_gate_class).
#
# A crew parked at a no-mistakes gate, or holding a green PR whose done: report
# is still outstanding, is idle because nothing pushed the gate to it. These
# cases drive a real fm-watch.sh subprocess against a canned current-state
# verdict and a static fake pane, and assert the behavioral contract: the worker
# is rung first through a fire-and-forget steering-inbox record, rung a second
# time if it stays idle, and only then escalated to firstmate with a gate-nudged
# reason. A busy pane, an open decision firstmate owns, and a secondmate are
# never rung, a pane whose agent has exited goes straight to recovery, and a new
# task worktree head re-arms a spent budget.
#
# The general watcher triage matrix lives in fm-watch-triage.test.sh; the
# steering-inbox record format and re-ring ladder in fm-task-inbox.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-gate-nudge-tests)

# Local copies of the three fixture verbs the watcher suites each keep for
# themselves (reap and set_mtime are already held that way by
# fm-inactive-reconcile.test.sh and fm-wake-drain-outcome-backstop.test.sh).
# Status priming goes through wake-helpers' prime_status_seen, which uses the
# production signature owner rather than a second copy of it.

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Portable mtime in epoch seconds.
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Set <file>'s mtime to exactly <epoch> seconds (touch -t takes a local-time
# stamp, not an epoch, on both platforms).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# Wait until <pid>'s watcher has completed a whole poll cycle, or exited first.
# The liveness beacon is touched at the TOP of every poll, so this drops any
# stale beacon, waits for this watcher to write one, then waits for it to
# advance; the cycle in between is what the caller's assertions describe.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Present and acknowledge everything a stopped watcher queued, exactly as a
# handling turn does. Without it the next watcher in the same fixture wakes
# immediately on the recovery resurface instead of reaching its stale scan.
ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

record_pi_busy() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source pi-ext --event agent-start
}

PARKED_VERDICT='state: parked · source: run-step · parked at review: 3 finding(s)'
CI_GREEN_VERDICT='state: done · source: run-step · checks green: PR ready for review (still monitoring for merge/close)'

# Stage one idle, already-stale pane for task <id> on window <window>: the
# metadata, a primed status log, and the staleness backbone's own markers
# recorded as if a previous poll had already seen this exact pane content. The
# hash marker is backdated so the pane reads as idle for well over any
# FM_GATE_NUDGE_SECS a case sets. Echoes the derived window key.
stage_idle_pane() {  # <state> <id> <window> <capture-file> <kind> [worktree]
  local state=$1 id=$2 window=$3 capture=$4 kind=$5 wt=${6:-} key
  printf 'idle prompt, waiting for input' > "$capture"
  {
    printf 'window=%s\nkind=%s\nharness=claude\n' "$window" "$kind"
    [ -z "$wt" ] || printf 'worktree=%s\n' "$wt"
  } > "$state/$id.meta"
  printf 'working: implementation committed\n' > "$state/$id.status"
  prime_status_seen "$state" "$state/$id.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'idle prompt, waiting for input')" > "$state/.hash-$key"
  set_mtime "$(( $(date +%s) - 600 ))" "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$key"
}

# Count the durable steering-inbox records the ladder has written for <id>.
nudge_record_count() {  # <state> <id>
  local f n=0
  for f in "$1/$2.inbox"/*.msg; do
    [ -e "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}

# Wait until <id> has at least <want> steering-inbox records, or <pid> exits.
wait_nudge_records() {  # <state> <id> <want> <pid> [limit-ticks]
  local state=$1 id=$2 want=$3 pid=$4 limit=${5:-150} i=0
  while [ "$i" -lt "$limit" ]; do
    [ "$(nudge_record_count "$state" "$id")" -ge "$want" ] && return 0
    is_live_non_zombie "$pid" || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- pure classifier (fm-classify-lib.sh) -----------------------------------

test_crew_gate_class_reads_only_run_step_gates() {
  local dir fakebin
  dir=$(make_case gate-class); fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE

  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 3 finding(s)'
  [ "$(crew_gate_class a)" = "parked$(printf '\t')parked at review: 3 finding(s)" ] \
    || fail "a parked run-step gate was not classified as a gate: $(crew_gate_class a)"
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  [ "$(crew_gate_class a)" = "ci-green$(printf '\t')checks green: PR ready for review" ] \
    || fail "a green-CI run-step verdict was not classified as a gate: $(crew_gate_class a)"
  # A done reconciled from the status log means the worker already reported.
  FM_FAKE_CREW_STATE='state: done · source: status-log · done: PR ...  ·  run still monitoring PR'
  [ "$(crew_gate_class a)" = none ] \
    || fail "a status-log done was read as a gate the worker still owes"
  FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'
  [ "$(crew_gate_class a)" = none ] || fail "an active run was read as a gate"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  [ "$(crew_gate_class a)" = none ] || fail "a failed run was read as a gate"
  FM_FAKE_CREW_STATE='state: parked · source: pane · idle prompt'
  [ "$(crew_gate_class a)" = none ] || fail "a pane verdict was read as a gate"
  FM_FAKE_CREW_STATE='not a state line at all'
  [ "$(crew_gate_class a)" = none ] || fail "an unreadable verdict was read as a gate"
  [ "$(crew_gate_class "")" = none ] || fail "an empty id was read as a gate"

  unset FM_FAKE_CREW_STATE FM_CREW_STATE_BIN
  pass "crew_gate_class: only a run-step parked or green-CI verdict is a gate"
}

# --- behavior (bin/fm-watch.sh) ---------------------------------------------

test_first_nudge_rings_the_worker_without_waking_firstmate() {
  local dir state fakebin out capture window id pid body
  dir=$(make_case gate-nudge-first); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  id=gatefirst; window="test:fm-$id"
  stage_idle_pane "$state" "$id" "$window" "$capture" ship >/dev/null

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE="$PARKED_VERDICT" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_GATE_NUDGE_SECS=30 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_nudge_records "$state" "$id" 1 "$pid" \
    || { reap "$pid"; fail "a parked gate did not ring the worker: $(cat "$out")"; }
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "the first gate nudge woke firstmate instead of holding the pane: $(cat "$out")"; }

  [ ! -s "$out" ] || { reap "$pid"; fail "a single gate nudge printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a single gate nudge enqueued a durable wake record"; }
  [ "$(nudge_record_count "$state" "$id")" -eq 1 ] \
    || { reap "$pid"; fail "the ladder rang more than once inside one nudge interval"; }
  body=$(cat "$state/$id.inbox/001.msg")
  reap "$pid"

  case "$body" in
    *"delivery=fire-and-forget"*) ;;
    *) fail "the gate nudge was not written as a fire-and-forget record: $body" ;;
  esac
  case "$body" in
    *"parked at review: 3 finding(s)"*) ;;
    *) fail "the gate nudge did not name the gate step and finding count: $body" ;;
  esac
  case "$body" in
    *"no-mistakes axi status"*) ;;
    *) fail "the gate nudge did not name the exact next command: $body" ;;
  esac
  pass "a parked gate rings the worker first and leaves firstmate asleep"
}

test_ci_green_awaiting_the_done_report_rings_the_worker() {
  local dir state fakebin out capture window id pid body
  dir=$(make_case gate-nudge-ci-green); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  id=gateci; window="test:fm-$id"
  stage_idle_pane "$state" "$id" "$window" "$capture" ship >/dev/null

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE="$CI_GREEN_VERDICT" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_GATE_NUDGE_SECS=30 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_nudge_records "$state" "$id" 1 "$pid" \
    || { reap "$pid"; fail "a green PR awaiting its done: report did not ring the worker: $(cat "$out")"; }
  body=$(cat "$state/$id.inbox/001.msg")
  reap "$pid"

  case "$body" in
    *"done: PR <full https URL> checks green"*) ;;
    *) fail "the green-CI nudge did not name the report the worker owes: $body" ;;
  esac
  pass "a green PR whose done: report is outstanding rings the worker"
}

test_worker_that_already_reported_done_is_never_rung() {
  local dir state fakebin out capture window id pid
  dir=$(make_case gate-nudge-done-reported); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  id=gatedone; window="test:fm-$id"
  stage_idle_pane "$state" "$id" "$window" "$capture" ship >/dev/null
  printf 'working: implementation committed\ndone: PR https://example.invalid/pr/7 checks green\n' \
    > "$state/$id.status"
  prime_status_seen "$state" "$state/$id.status"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE="$CI_GREEN_VERDICT" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_GATE_NUDGE_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 150 >/dev/null
  reap "$pid"

  [ "$(nudge_record_count "$state" "$id")" -eq 0 ] \
    || fail "a worker that already reported done: was rung to report again"
  pass "a green PR whose done: report already landed is never rung"
}

test_ladder_escalates_only_after_two_unanswered_nudges() {
  local dir state fakebin out capture window id pid rc
  dir=$(make_case gate-nudge-ladder); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  id=gateladder; window="test:fm-$id"
  stage_idle_pane "$state" "$id" "$window" "$capture" ship >/dev/null

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE="$PARKED_VERDICT" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_GATE_NUDGE_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_nudge_records "$state" "$id" 2 "$pid" \
    || { reap "$pid"; fail "the ladder did not ring a second time on a still-idle pane: $(cat "$out")"; }
  rc=0
  wait_for_exit "$pid" 200 || rc=$?
  reap "$pid"

  [ "$rc" -ne 124 ] || fail "the ladder never escalated after two unanswered nudges"
  [ "$(nudge_record_count "$state" "$id")" -eq 2 ] \
    || fail "the ladder spent a budget other than exactly two rings: $(nudge_record_count "$state" "$id")"
  grep -F "stale: $window" "$out" >/dev/null \
    || fail "the spent ladder did not emit the ordinary stale wake: $(cat "$out")"
  grep -F "gate-nudged x2" "$out" >/dev/null \
    || fail "the spent ladder's stale wake did not carry the gate-nudged marker: $(cat "$out")"
  grep -F "gate-nudged x2" "$state/.wake-queue" >/dev/null \
    || fail "the spent ladder did not queue the gate-nudged stale wake durably"
  pass "two unanswered nudges precede the ordinary stale wake, which names them"
}

test_busy_pane_is_never_nudged() {
  local dir state fakebin out capture window id pid
  dir=$(make_case gate-nudge-busy); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  id=gatebusy; window="test:fm-$id"
  stage_idle_pane "$state" "$id" "$window" "$capture" ship >/dev/null
  # Re-declare the pane as a pi worker with an exact semantic busy verdict, the
  # same fixture the busy-pane triage cases use.
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/$id.meta"
  record_pi_busy "$state" "$id"
  printf 'Working... (12.3s)' > "$capture"
  printf '%s' "$(hash_text 'Working... (12.3s)')" > "$state/.hash-$(printf '%s' "$window" | tr ':/.' '___')"
  set_mtime "$(( $(date +%s) - 600 ))" "$state/.hash-$(printf '%s' "$window" | tr ':/.' '___')"
  prime_status_seen "$state" "$state/$id.status"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE="$PARKED_VERDICT" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_GATE_NUDGE_SECS=1 FM_BUSY_TURN_MAX_SECS=999 FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "a busy pane exited the watcher instead of staying absorbed: $(cat "$out")"; }
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "a busy pane exited the watcher on its second cycle: $(cat "$out")"; }
  reap "$pid"

  [ "$(nudge_record_count "$state" "$id")" -eq 0 ] \
    || fail "a busy pane was rung about its gate"
  pass "a busy pane is never rung, however its run reads"
}

test_open_decision_is_left_to_firstmate() {
  local dir state fakebin out capture window id pid
  dir=$(make_case gate-nudge-open-decision); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  id=gatedecision; window="test:fm-$id"
  stage_idle_pane "$state" "$id" "$window" "$capture" ship >/dev/null
  printf 'working: implementation committed\nneeds-decision: widen the rename or keep it narrow [key=rename-scope]\n' \
    > "$state/$id.status"
  prime_status_seen "$state" "$state/$id.status"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE="$PARKED_VERDICT" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_GATE_NUDGE_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 >/dev/null
  reap "$pid"

  [ "$(nudge_record_count "$state" "$id")" -eq 0 ] \
    || fail "a task with an open decision firstmate owns was rung anyway"
  grep -F "gate-nudged" "$out" >/dev/null \
    && fail "an open decision was escalated through the gate-nudge ladder: $(cat "$out")"

  # The same holds for a worker that escalated without choosing a key, which is
  # the shape this suppression must cover for the comment above it to be true.
  rm -f "$state/.gate-nudge-$id" "$state/.$id.open-decisions-cursor"
  ack_stopped_cycle "$state" || fail "the keyed round's wakes could not be acknowledged"
  printf 'working: implementation committed\nneeds-decision: widen the rename or keep it narrow\n' \
    > "$state/$id.status"
  prime_status_seen "$state" "$state/$id.status"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE="$PARKED_VERDICT" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_GATE_NUDGE_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/unkeyed.out" &
  pid=$!
  wait_for_exit "$pid" 60 >/dev/null
  reap "$pid"
  [ "$(nudge_record_count "$state" "$id")" -eq 0 ] \
    || fail "a task whose open decision carries no key was rung anyway"
  pass "an open decision firstmate owns, keyed or not, suppresses the ring entirely"
}

test_declared_wait_is_left_to_the_pause_cadence() {
  local dir state fakebin out capture window id pid
  dir=$(make_case gate-nudge-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  id=gatepaused; window="test:fm-$id"
  stage_idle_pane "$state" "$id" "$window" "$capture" ship >/dev/null
  printf 'working: implementation committed\npaused: waiting on the upstream release\n' \
    > "$state/$id.status"
  prime_status_seen "$state" "$state/$id.status"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE="$PARKED_VERDICT" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_GATE_NUDGE_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 60 >/dev/null
  reap "$pid"

  [ "$(nudge_record_count "$state" "$id")" -eq 0 ] \
    || fail "a task on a declared external wait was rung by the gate-nudge ladder"
  grep -F "gate-nudged" "$out" >/dev/null \
    && fail "a declared external wait was escalated through the gate-nudge ladder: $(cat "$out")"
  pass "a declared external wait stays on the bounded pause cadence, unprobed"
}

test_secondmate_is_outside_the_ladder() {
  local dir state fakebin out capture window id pid
  dir=$(make_case gate-nudge-secondmate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  id=gatemate; window="test:fm-$id"
  stage_idle_pane "$state" "$id" "$window" "$capture" secondmate >/dev/null

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE="$PARKED_VERDICT" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_GATE_NUDGE_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "an idle secondmate pane exited the watcher: $(cat "$out")"; }
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "an idle secondmate pane exited the watcher on its second cycle: $(cat "$out")"; }
  reap "$pid"

  [ "$(nudge_record_count "$state" "$id")" -eq 0 ] \
    || fail "a secondmate was rung about a gate"
  pass "a secondmate's idle endpoint stays outside the ladder"
}

test_dead_endpoint_is_never_rung() {
  local dir state fakebin out capture window id pid
  dir=$(make_case gate-nudge-dead); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  id=gatedead; window="test:fm-$id"
  stage_idle_pane "$state" "$id" "$window" "$capture" ship >/dev/null

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE="$PARKED_VERDICT" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_GATE_NUDGE_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 >/dev/null
  reap "$pid"

  [ "$(nudge_record_count "$state" "$id")" -eq 0 ] \
    || fail "a pane whose agent has exited was rung about its gate"
  grep -F "gate-nudged" "$out" >/dev/null \
    && fail "a dead endpoint was escalated through the gate-nudge ladder: $(cat "$out")"
  pass "a positively dead endpoint goes straight to the ordinary recovery path"
}

# The budget is bound to a gate identity that includes the task worktree head,
# so a later fix round reporting the same step and the same finding count still
# earns its own rings. The control is the same restart WITHOUT a new commit.
test_new_worktree_head_rearms_a_spent_budget() {
  local dir state fakebin out capture window id wt pid rc before
  dir=$(make_case gate-nudge-head); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  id=gatehead; window="test:fm-$id"
  wt="$dir/worktree"
  mkdir -p "$wt"
  git -C "$wt" init -q
  git -C "$wt" config user.email fixture@example.invalid
  git -C "$wt" config user.name fixture
  printf 'one\n' > "$wt/f.txt"
  git -C "$wt" add f.txt
  git -C "$wt" commit -q -m 'first round'
  stage_idle_pane "$state" "$id" "$window" "$capture" ship "$wt" >/dev/null

  # Spend the whole budget once.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE="$PARKED_VERDICT" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_GATE_NUDGE_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  rc=0
  wait_for_exit "$pid" 250 || rc=$?
  reap "$pid"
  [ "$rc" -ne 124 ] || fail "the ladder never spent its budget on the first round"
  before=$(nudge_record_count "$state" "$id")
  [ "$before" -eq 2 ] || fail "the first round did not spend exactly two rings: $before"

  # Control: the same gate, the same head, a fresh watcher, left running for
  # several probe windows. A spent budget neither rings again nor re-escalates:
  # firstmate has been woken about this gate once and owns the pane from here.
  ack_stopped_cycle "$state" || fail "the first round's wakes could not be acknowledged"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE="$PARKED_VERDICT" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_GATE_NUDGE_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/control.out" &
  pid=$!
  wait_for_exit "$pid" 60 >/dev/null
  reap "$pid"
  [ "$(nudge_record_count "$state" "$id")" -eq "$before" ] \
    || fail "a spent budget rang again on an unchanged worktree head"
  grep -F "stale: $window" "$dir/control.out" >/dev/null \
    || fail "the spent ladder did not hand the pane back to the unchanged triage: $(cat "$dir/control.out")"
  grep -F "gate-nudged" "$dir/control.out" >/dev/null \
    && fail "a spent budget escalated the same gate a second time: $(cat "$dir/control.out")"

  # A fix round commits, so the head moves and the same-looking gate is a new one.
  printf 'two\n' > "$wt/f.txt"
  git -C "$wt" add f.txt
  git -C "$wt" commit -q -m 'fix round'
  ack_stopped_cycle "$state" || fail "the control round's wakes could not be acknowledged"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE="$PARKED_VERDICT" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_GATE_NUDGE_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_nudge_records "$state" "$id" "$((before + 1))" "$pid" \
    || { reap "$pid"; fail "a new worktree head did not re-arm the gate-nudge budget: $(cat "$out")"; }
  reap "$pid"
  pass "a new task worktree head re-arms a spent gate-nudge budget"
}

test_crew_gate_class_reads_only_run_step_gates
test_first_nudge_rings_the_worker_without_waking_firstmate
test_ci_green_awaiting_the_done_report_rings_the_worker
test_worker_that_already_reported_done_is_never_rung
test_ladder_escalates_only_after_two_unanswered_nudges
test_busy_pane_is_never_nudged
test_open_decision_is_left_to_firstmate
test_declared_wait_is_left_to_the_pause_cadence
test_secondmate_is_outside_the_ladder
test_dead_endpoint_is_never_rung
test_new_worktree_head_rearms_a_spent_budget
