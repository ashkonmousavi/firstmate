#!/usr/bin/env bash
# tests/fm-supervision-events.test.sh - unit tests for the watcher's native
# event-wait splice (event_wait_or_sleep in bin/fm-watch.sh and
# handle_push_transition in bin/fm-push-transition-lib.sh). The watcher's source
# guard lets this file source it to load
# the functions WITHOUT acquiring the singleton lock or entering the blocking
# loop; wake/sleep and the backend dispatchers are overridden so the exemptions,
# capability memo, and fail-closed disable are asserted deterministically with no
# real herdr, watcher process, or blocking sleeps.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-supervision-events)
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"

# Source the watcher with an isolated state/home. The guard returns before the
# lock/loop, so only the functions load.
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
# Production modules are independently linted canonical roots. Keep this test's
# ShellCheck context local while preserving its unchanged runtime source path.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

# Overrides: capture wake reasons and neutralize real sleeps (POLL is 15s).
WAKE_LOG="$TMP/wakes"
SLEEP_LOG="$TMP/sleeps"
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; return 0; }
sleep() { printf 'SLEEP\n' >> "$SLEEP_LOG"; }

reset_state() {
  rm -f "$STATE_DIR"/*.meta "$STATE_DIR"/*.status "$STATE_DIR"/.wake-queue \
    "$STATE_DIR"/.wake-queue.seq "$STATE_DIR"/.watch-triage.log \
    "$STATE_DIR"/.herdr-escalated-* "$STATE_DIR"/.push-fallback-* \
    "$STATE_DIR"/.paused-* "$STATE_DIR"/.stale-* "$TMP"/panes "$TMP"/wtcalls "$TMP"/wtcalled 2>/dev/null || true
  : > "$WAKE_LOG"
  : > "$SLEEP_LOG"
  _event_cap_key=""
  _event_cap_ok=0
  _event_cap_fails=0
}

mkrec() {  # <pane_id> <status>
  fm_transition_record "$1" "wG" "" "$2" claude
}

# --- handle_push_transition: enqueue + wake for a non-paused blocked crew -----

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
[ -e "$STATE_DIR/.wake-queue" ] || fail "handle_push_transition should enqueue a wake for a blocked crew"
grep -q 'stale' "$STATE_DIR/.wake-queue" || fail "the enqueued wake must be a stale record: $(cat "$STATE_DIR/.wake-queue")"
grep -q 'default:wG:pQ' "$STATE_DIR/.wake-queue" || fail "the stale record must name the crew's window"
grep -q 'herdr: agent blocked' "$STATE_DIR/.wake-queue" || fail "the stale payload must name the herdr-blocked cause"
[ -s "$WAKE_LOG" ] || fail "handle_push_transition must wake the supervisor for a blocked crew"
[ -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "handle_push_transition must commit dedupe only after enqueue"
pass "handle_push_transition: a blocked crew enqueues a stale wake naming its window and wakes the supervisor"

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
(
  # shellcheck disable=SC2329 # Runtime override called by the isolated production owner.
  fm_wake_append() { return 1; }
  handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
) >/dev/null 2>&1 || true
[ ! -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "a failed durable enqueue must leave the blocked edge eligible for reconnect reconciliation"
pass "handle_push_transition: enqueue failure cannot commit the Herdr dedupe marker"

# --- handle_push_transition: a question on screen outranks a declared wait ----
# A blocked agent is waiting on a human, and a declaration only accounts for
# quiet: neither a declared pause nor a captain-held transfer answers it.

for declared in 'paused: waiting on the upstream release, until 2099-01-01T00:00Z' \
  'captain-held [key=route]: tracked by task-decision-route'; do
  reset_state
  fm_write_meta "$STATE_DIR/tk2.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
  printf '%s\n' "$declared" > "$STATE_DIR/tk2.status"
  handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
  grep -q 'herdr: agent blocked - waiting on human' "$STATE_DIR/.wake-queue" 2>/dev/null \
    || fail "a blocked crew under '$declared' must be durably queued: $(cat "$STATE_DIR/.wake-queue" 2>/dev/null)"
  [ -s "$WAKE_LOG" ] || fail "a blocked crew under '$declared' must wake the supervisor"
  [ -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "the escalated edge under '$declared' must commit its dedupe marker"
done
pass "handle_push_transition: a blocked crew wakes the supervisor under a declared pause or captain-held transfer"

# --- surface_nonterminal_stale: a future paused-until silences only quiet ------
# The poll loop's sighting of a live stale pane under a `paused: ... until
# <future>` is silent, unless the backend reports its agent waiting on a human:
# that sighting wakes once and is then held to the pause cadence.

reset_state
fm_write_meta "$STATE_DIR/tk7.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
printf 'paused: 8 research agents running; resume when they report, until 2099-01-01T00:00Z\n' > "$STATE_DIR/tk7.status"
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
fm_backend_question_waiting() { return 1; }
surface_nonterminal_stale default:wG:pQ h1
[ ! -s "$WAKE_LOG" ] || fail "a quiet pane under a future paused-until must stay silent: $(cat "$WAKE_LOG")"
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
fm_backend_question_waiting() { [ "$1" = herdr ] && [ "$2" = default:wG:pQ ]; }
surface_nonterminal_stale default:wG:pQ h2
grep -Fx 'stale: default:wG:pQ (a permission or question prompt is waiting in the pane)' "$WAKE_LOG" >/dev/null \
  || fail "a pane waiting on a human under a future paused-until must wake: $(cat "$WAKE_LOG")"
grep -q 'a permission or question prompt is waiting in the pane' "$STATE_DIR/.wake-queue" 2>/dev/null \
  || fail "the question sighting must be durably queued: $(cat "$STATE_DIR/.wake-queue" 2>/dev/null)"
: > "$WAKE_LOG"
surface_nonterminal_stale default:wG:pQ h3
[ ! -s "$WAKE_LOG" ] || fail "a repeat question sighting inside the pause cadence must be absorbed: $(cat "$WAKE_LOG")"
pass "surface_nonterminal_stale: a future paused-until silences a quiet pane, never a pane waiting on a human"

# --- event_wait_or_sleep: secondmate windows are excluded from the pane list --

reset_state
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
fm_write_meta "$STATE_DIR/sm1.meta" "window=default:wA:pS" "backend=herdr" "kind=secondmate"
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() { shift 4; printf '%s\n' "$*" > "$TMP/panes"; return 1; }
event_wait_or_sleep
PANES=$(cat "$TMP/panes" 2>/dev/null || true)
case "$PANES" in *"default:wG:pQ"*) : ;; *) fail "the ship window must be in the event pane list, got '$PANES'" ;; esac
case "$PANES" in *"default:wA:pS"*) fail "a kind=secondmate window must be EXCLUDED from the event pane list, got '$PANES'" ;; *) : ;; esac
pass "event_wait_or_sleep: herdr windows go on the event pane list, but kind=secondmate endpoints are excluded"

reset_state
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
CAP_CALLS=0
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { CAP_CALLS=$((CAP_CALLS + 1)); return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() {
  [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" = 1 ] || fail "cached capability verdict was not passed to the wait"
  return 1
}
event_wait_or_sleep
event_wait_or_sleep
[ "$CAP_CALLS" = 1 ] || fail "capability probe must be memoized across waits, got $CAP_CALLS calls"
pass "event_wait_or_sleep: one cached capability probe owns validation across bounded waits"

# --- event_wait_or_sleep: a tmux-only home never runs the event path ----------

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"   # no backend= -> tmux
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
fm_backend_wait_transition() { printf 'CALLED\n' > "$TMP/wtcalled"; return 1; }
event_wait_or_sleep
[ ! -e "$TMP/wtcalled" ] || fail "a tmux-only home must never invoke the event wait path"
grep -q 'SLEEP' "$SLEEP_LOG" || fail "a tmux-only home must sleep POLL exactly as before"
pass "event_wait_or_sleep: a home with no push-capable window is inert (sleeps POLL, never touches the event path)"

# --- event_wait_or_sleep: runtime failures disable the event path (fail-closed)

reset_state
fm_write_meta "$STATE_DIR/tk5.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
export EVENT_CAP_FAIL_MAX=2
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() { printf 'WT\n' >> "$TMP/wtcalls"; return 2; }
: > "$TMP/wtcalls"
event_wait_or_sleep   # fails=1
event_wait_or_sleep   # fails=2 -> disable
event_wait_or_sleep   # disabled: sleeps without calling wait_transition
WTN=$(wc -l < "$TMP/wtcalls" | tr -d '[:space:]')
[ "$WTN" = 2 ] || fail "after EVENT_CAP_FAIL_MAX connect failures the event path must be disabled for the process (expected 2 wait_transition calls, got $WTN)"
DISABLED=$(grep -c 'push fast-path disabled' "$STATE_DIR/.watch-triage.log" 2>/dev/null || true)
[ "$DISABLED" = 1 ] || fail "disabling the push fast-path must write exactly one triage line, got ${DISABLED:-0}: $(cat "$STATE_DIR/.watch-triage.log" 2>/dev/null)"
grep -q 'check: push fast-path lost for herdr:default (disabled after 2 consecutive' "$STATE_DIR/.wake-queue" 2>/dev/null \
  || fail "the runtime disable must queue a check wake: $(cat "$STATE_DIR/.wake-queue" 2>/dev/null)"
[ "$(grep -c 'push fast-path lost' "$WAKE_LOG")" = 1 ] || fail "the runtime disable must wake firstmate exactly once: $(cat "$WAKE_LOG")"
pass "event_wait_or_sleep: consecutive event-path failures disable the fast-path and revert to pure polling (fail-closed)"

# --- event_wait_or_sleep: a failed capability probe is logged once ------------

reset_state
fm_write_meta "$STATE_DIR/tk6.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 1; }
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
fm_backend_wait_transition() { printf 'CALLED\n' > "$TMP/wtcalled"; return 1; }
event_wait_or_sleep
event_wait_or_sleep
[ ! -e "$TMP/wtcalled" ] || fail "an incapable backend must never reach the event wait"
UNAVAILABLE=$(grep -c 'push fast-path unavailable' "$STATE_DIR/.watch-triage.log" 2>/dev/null || true)
[ "$UNAVAILABLE" = 1 ] || fail "a failed capability probe must write exactly one triage line, got ${UNAVAILABLE:-0}: $(cat "$STATE_DIR/.watch-triage.log" 2>/dev/null)"
grep -q 'check: push fast-path lost for herdr:default (capability probe failed)' "$STATE_DIR/.wake-queue" 2>/dev/null \
  || fail "a failed capability probe must queue a check wake: $(cat "$STATE_DIR/.wake-queue" 2>/dev/null)"
[ "$(grep -c 'push fast-path lost' "$WAKE_LOG")" = 1 ] || fail "a failed capability probe must wake firstmate exactly once: $(cat "$WAKE_LOG")"
pass "event_wait_or_sleep: a failed capability probe falls back to polling and says so once"

# --- event_wait_or_sleep: one fallback wake per episode across relaunches -----
# Every handled wake relaunches the watcher, which re-probes. The same episode
# must not wake again, and a working event wait closes it.

: > "$WAKE_LOG"
_event_cap_key=""; _event_cap_ok=0; _event_cap_fails=0
event_wait_or_sleep
[ ! -s "$WAKE_LOG" ] || fail "a relaunched watcher in the same fallback episode must not wake again: $(cat "$WAKE_LOG")"
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
fm_backend_wait_transition() { return 1; }
_event_cap_key=""; _event_cap_ok=0; _event_cap_fails=0
event_wait_or_sleep
[ ! -e "$STATE_DIR/.push-fallback-herdr_default" ] || fail "a working event wait must close the fallback episode"
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 1; }
_event_cap_key=""; _event_cap_ok=0; _event_cap_fails=0
event_wait_or_sleep
[ "$(grep -c 'push fast-path lost' "$WAKE_LOG")" = 1 ] || fail "a new fallback episode must wake firstmate once: $(cat "$WAKE_LOG")"
pass "event_wait_or_sleep: a polling fallback wakes firstmate once per episode, not once per relaunch"

echo "# fm-supervision-events.test.sh: all assertions passed"
