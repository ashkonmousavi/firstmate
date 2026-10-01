#!/usr/bin/env bash
# Live: the real watcher in a herdr lab home whose only recorded pane is gone.
# The push path fails every cycle; base falls back to polling silently, branch
# wakes firstmate once per fallback episode.
set -u
ROOT=$(pwd)
BASE=9a7089ba430c9e4990d866357c8d588e551d0463
fail() { printf 'FAIL - %s\n' "$1"; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
SESSION="fm-lab-fallback-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
WPID=
cleanup() { [ -n "$WPID" ] && kill "$WPID" 2>/dev/null; rm -rf "$LAB"; HERDR_SESSION="$SESSION" herdr_safe_stop_and_delete "$SESSION"; }
trap cleanup EXIT
HERDR_SESSION="$SESSION" fm_herdr_lab_prepare "$SESSION" || fail "prepare"
( export HERDR_SESSION="$SESSION"; . "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr
  C_RAW=$(fm_backend_herdr_container_ensure /tmp) || exit 1
  ids=$(fm_backend_herdr_create_task "${C_RAW%%$'\t'*}" fm-gone /tmp "${C_RAW#*$'\t'}") || exit 1
  set -- $ids; printf '%s' "$2" ) > "$LAB/pane" || fail "create pane"
GONE=$(cat "$LAB/pane")
fm_herdr_lab_cli "$SESSION" pane close "$GONE" >/dev/null 2>&1 || fail "close pane"
echo "# herdr $(herdr --version|head -1); lab session $SESSION; recorded pane $GONE closed (task record outlives its pane)"
HOME_DIR="$LAB/home"; "$ROOT/bin/fm-lab-home.sh" create "$HOME_DIR" >/dev/null || fail "lab home"
mkdir -p "$LAB/tmux"; touch "$HOME_DIR/state/.last-watcher-beat"
STATE="$HOME_DIR/state"
printf 'window=%s\nbackend=herdr\nkind=ship\nharness=claude\n' "$SESSION:$GONE" > "$STATE/gone.meta"
printf 'working: implementing the change\n' > "$STATE/gone.status"

watch_env() {
  ${WEXEC:-} env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE -u HERDR_SESSION \
    TMUX_TMPDIR="$LAB/tmux" FM_HOME="$HOME_DIR" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 "$@"
}
run_for() {
  WEXEC=exec watch_env "$1" > "$3" 2>&1 & WPID=$!
  local t=0; while [ "$t" -lt "$2" ]; do kill -0 "$WPID" 2>/dev/null || { wait "$WPID"; WPID=; return 0; }; sleep 1; t=$((t+1)); done
  kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=; return 1
}
ack_all() {
  watch_env "$ROOT/bin/fm-wake-drain.sh" > "$LAB/drain.out" 2> "$LAB/drain.err"
  local seq; seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1 \2/p' "$LAB/drain.err")
  [ -n "$seq" ] || return 0
  set -- $seq
  watch_env "$ROOT/bin/fm-wake-drain.sh" --ack-through "$1" --recovery-generation "$2" >/dev/null 2>&1
}
mkdir -p "$LAB/base"; git archive "$BASE" | tar -x -C "$LAB/base"

echo "## settle with the base watcher (it has no fallback wake) until a quiet 20s run"
for a in 1 2 3 4 5; do
  if run_for "$LAB/base/bin/fm-watch.sh" 20 "$LAB/settle.out"; then
    echo "settle run $a woke: $(tr '\n' ' ' < "$LAB/settle.out")"; ack_all || fail ack
  else echo "settle run $a: quiet for 20s"; break; fi
done

echo
echo "## S-fallback-base: base watcher, push path failing every cycle"
if run_for "$LAB/base/bin/fm-watch.sh" 30 "$LAB/base.out"; then
  echo "base woke: $(cat "$LAB/base.out")"
else
  echo "base watcher silent for 30s; push-related triage lines: $(grep -c 'push fast-path' "$STATE/.watch-triage.log" 2>/dev/null || echo 0)"
fi

echo
echo "## S-fallback-branch: branch watcher, same home"
run_for "$ROOT/bin/fm-watch.sh" 40 "$LAB/branch.out" || fail "branch watcher stayed silent: $(cat "$LAB/branch.out")"
echo "branch watcher output: $(cat "$LAB/branch.out")"
grep -q "^check: push fast-path lost for herdr:$SESSION (disabled after 3 consecutive event-path failures); polling every 2s" "$LAB/branch.out" || fail "unexpected wake"
echo "wake-queue: $(cat "$STATE/.wake-queue")"
echo "triage: $(grep 'push fast-path' "$STATE/.watch-triage.log")"
ls "$STATE"/.push-fallback-* >/dev/null 2>&1 || fail "no episode marker"
echo "episode marker: $(basename "$(ls "$STATE"/.push-fallback-*)")"
ok "the branch watcher wakes firstmate once the push path is disabled"

echo
echo "## S-fallback-once-per-episode: acknowledged, relaunched watcher in the same episode stays quiet"
ack_all || fail ack
if run_for "$ROOT/bin/fm-watch.sh" 30 "$LAB/again.out"; then fail "re-woke: $(cat "$LAB/again.out")"; fi
echo "triage disable lines now: $(grep -c 'push fast-path disabled' "$STATE/.watch-triage.log")"
ok "no second wake within 30s for the same fallback episode"
