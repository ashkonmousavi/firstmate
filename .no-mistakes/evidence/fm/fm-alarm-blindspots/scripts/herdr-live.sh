#!/usr/bin/env bash
# Live herdr lab scenarios for fm/fm-alarm-blindspots (run from the gate worktree).
set -u
ROOT=$(pwd)
BASE=9a7089ba430c9e4990d866357c8d588e551d0463
fail() { printf 'FAIL - %s\n' "$1"; cleanup_all; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
SESSION="fm-lab-alarm-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-alarm-herdr.XXXXXX")
cleanup_all() { rm -rf "$SCRATCH"; herdr_safe_stop_and_delete "$SESSION"; }
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "prepare lab"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "source herdr"
echo "# herdr: $(herdr --version | head -1); lab session $SESSION"
fm_backend_herdr_events_capable "$SESSION" || fail "events capability"
C_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container"
C=${C_RAW%%$'\t'*}; SEED=${C_RAW#*$'\t'}
mk() { local ids; ids=$(fm_backend_herdr_create_task "$C" "$1" /tmp "$2") || return 1; set -- $ids; printf '%s' "$2"; }
LIVE=$(mk fm-live "$SEED") || fail "create live"
CUR=$(mk fm-cursor "") || fail "create cursor"
GONE=$(mk fm-gone "") || fail "create gone"
echo "# panes: live=$LIVE cursor=$CUR gone=$GONE"
fm_herdr_lab_cli "$SESSION" pane report-agent "$LIVE" --source fm-alarm-test --agent claude --state idle >/dev/null 2>&1 || fail "live idle"
fm_herdr_lab_cli "$SESSION" pane report-agent "$CUR" --source fm-alarm-test --agent cursor --state idle >/dev/null 2>&1 || fail "cursor idle"
fm_herdr_lab_cli "$SESSION" pane close "$GONE" >/dev/null 2>&1 || fail "close gone pane"
SOCK=$(fm_backend_herdr_socket_path "$SESSION"); [ -n "$SOCK" ] || fail "socket"

echo
echo "## S-gone-pane: reader subscribes [gone, live] (a task record that outlived its pane)"
git show "$BASE:bin/backends/herdr-eventwait.py" > "$SCRATCH/base-eventwait.py"
python3 "$SCRATCH/base-eventwait.py" "$SOCK" 2 "$GONE" "$LIVE" > "$SCRATCH/b.out" 2> "$SCRATCH/b.err"; brc=$?
echo "base reader ($BASE): exit=$brc stdout=[$(tr '\n' ' ' < "$SCRATCH/b.out")]"
python3 "$ROOT/bin/backends/herdr-eventwait.py" "$SOCK" 2 "$GONE" "$LIVE" > "$SCRATCH/n.out" 2> "$SCRATCH/n.err"; nrc=$?
echo "branch reader: exit=$nrc stdout=[$(tr '\n' ' ' < "$SCRATCH/n.out")] stderr=[$(tr '\n' ' ' < "$SCRATCH/n.err")]"
[ "$brc" = 3 ] || fail "base reader was expected to reject the whole subscription (exit 3), got $brc"
grep -qx '@subscribed' "$SCRATCH/n.out" || fail "branch reader did not subscribe the live pane"
grep -q "dropped gone pane(s) $GONE" "$SCRATCH/n.err" || fail "branch reader did not name the dropped pane"
ok "base reader exits 3 on one gone pane; branch reader drops it and subscribes the live pane"

STATE="$SCRATCH/state"; mkdir -p "$STATE"
FUT=$(date -u -d '+2 hours' +%Y-%m-%dT%H:%MZ)
printf 'window=%s\nbackend=herdr\nkind=ship\nharness=claude\n' "$SESSION:$LIVE" > "$STATE/live.meta"
printf 'paused: 8 research agents running; resume when they report, until %s\n' "$FUT" > "$STATE/live.status"
printf 'window=%s\nbackend=herdr\nkind=ship\nharness=cursor-agent\n' "$SESSION:$CUR" > "$STATE/cur.meta"
printf 'paused: waiting on upstream, until %s\n' "$FUT" > "$STATE/cur.status"
printf 'window=%s\nbackend=herdr\nkind=ship\nharness=claude\n' "$SESSION:$GONE" > "$STATE/gone.meta"

echo
echo "## S-push-live-past-gone: the watcher's wait over [gone, cursor, live] delivers live's blocked edge"
( fm_backend_herdr_wait_transition "$SESSION" 10 "$STATE" "$SESSION:$GONE" "$SESSION:$CUR" "$SESSION:$LIVE" > "$SCRATCH/w.out"; echo $? > "$SCRATCH/w.rc" ) &
WP=$!; sleep 1.5
fm_herdr_lab_cli "$SESSION" pane report-agent "$LIVE" --source fm-alarm-test --agent claude --state blocked >/dev/null 2>&1 || fail "live blocked"
wait "$WP"; REC=$(cat "$SCRATCH/w.out"); WRC=$(cat "$SCRATCH/w.rc")
echo "wait_transition rc=$WRC record=[$REC]"
[ "$WRC" = 0 ] && [ "$(fm_transition_pane_id "$REC")" = "$LIVE" ] && [ "$(fm_transition_to_status "$REC")" = blocked ] \
  || fail "wait_transition did not return live's blocked edge"
ok "fm_backend_herdr_wait_transition returns the live pane's blocked transition though a recorded pane is gone"

echo
echo "## S-blocked-under-paused-until (claude): handle_push_transition wakes firstmate"
export FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT"
. "$ROOT/bin/fm-push-transition-lib.sh"
wake() { printf 'WAKE: %s\n' "$*" >> "$SCRATCH/wakes"; }
handle_push_transition herdr "$SESSION" "$REC"
echo "status: $(cat "$STATE/live.status")"
echo "wake-queue:"; sed 's/^/  /' "$STATE/.wake-queue" 2>/dev/null
echo "wakes:"; sed 's/^/  /' "$SCRATCH/wakes" 2>/dev/null
grep -q "herdr: agent blocked - waiting on human" "$STATE/.wake-queue" 2>/dev/null || fail "no durable blocked wake under paused-until"
grep -q "stale: $SESSION:$LIVE" "$SCRATCH/wakes" 2>/dev/null || fail "firstmate was not woken"
ok "a claude pane's real herdr blocked edge under a future paused-until wakes firstmate"

echo
echo "## S-cursor-family-absorbed: a cursor-agent pane's blocked edge under paused-until is not a question"
: > "$SCRATCH/wakes"; cp "$STATE/.wake-queue" "$SCRATCH/q.before"
( fm_backend_herdr_wait_transition "$SESSION" 10 "$STATE" "$SESSION:$CUR" "$SESSION:$GONE" > "$SCRATCH/c.out"; echo $? > "$SCRATCH/c.rc" ) &
WP=$!; sleep 1.5
fm_herdr_lab_cli "$SESSION" pane report-agent "$CUR" --source fm-alarm-test --agent cursor --state blocked >/dev/null 2>&1 || fail "cursor blocked"
wait "$WP"; CREC=$(cat "$SCRATCH/c.out")
echo "wait_transition rc=$(cat "$SCRATCH/c.rc") record=[$CREC]"
[ "$(fm_transition_pane_id "$CREC")" = "$CUR" ] || fail "no cursor transition"
handle_push_transition herdr "$SESSION" "$CREC"
echo "triage: $(grep 'absorbed push' "$STATE/.watch-triage.log")"
[ ! -s "$SCRATCH/wakes" ] || fail "cursor-agent blocked woke firstmate: $(cat "$SCRATCH/wakes")"
cmp -s "$SCRATCH/q.before" "$STATE/.wake-queue" || fail "cursor-agent blocked was queued"
ok "a cursor-agent pane's blocked edge is absorbed (logged, no wake, no queue row)"

echo
echo "## S-all-gone (adversarial): a subscription naming only gone panes still fails closed"
python3 "$ROOT/bin/backends/herdr-eventwait.py" "$SOCK" 2 "$GONE" > "$SCRATCH/g.out" 2> "$SCRATCH/g.err"; grc=$?
echo "reader [gone] exit=$grc stderr=[$(tr '\n' ' ' < "$SCRATCH/g.err")]"
fm_backend_herdr_wait_transition "$SESSION" 3 "$STATE" "$SESSION:$GONE" > /dev/null; arc=$?
echo "wait_transition [gone] rc=$arc"
[ "$grc" = 3 ] && [ "$arc" = 2 ] || fail "only-gone subscription did not fail closed"
ok "only-gone panes exit 3 from the reader and rc 2 from the wait, so polling fallback still triggers"
