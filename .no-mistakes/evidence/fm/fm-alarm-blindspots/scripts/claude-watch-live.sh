#!/usr/bin/env bash
# Live incident reproduction: a real Claude worker under `paused: ... until <future>`
# raises a permission dialog; the real watcher (base vs branch) must or must not wake.
set -u
ROOT=$(pwd)
BASE=9a7089ba430c9e4990d866357c8d588e551d0463
EV=/home/tegris/.no-mistakes/evidence/01M3VJ827V1V4KV5VH7MFFQQ8N
. "$ROOT/tests/fixtures.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
SOCKET="fm-alarm-$$"; SESSION=fleet; WIN=fm-prompt-live
cleanup() {
  [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  chmod -R u+w "$LAB" 2>/dev/null || true; rm -rf "$LAB"
}
trap cleanup EXIT
fail() { printf 'FAIL - %s\n' "$1"; tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$WIN" 2>/dev/null | tail -25; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

HOME_DIR="$LAB/home"
"$ROOT/bin/fm-lab-home.sh" create "$HOME_DIR" >/dev/null || fail "lab home"
ID=prompt-live; PROJ="$LAB/project"; WT="$LAB/wt"
FAKEBIN=$(make_spawn_fakebin "$LAB/fake" claude)
fm_test_spawn_home "$HOME_DIR" claude
fm_git_worktree "$PROJ" "$WT" wt-prompt-live
fm_test_spawn_brief "$HOME_DIR" "$ID"
out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$ID" "$PROJ" --mode no-mistakes --yolo off) || fail "fixture spawn: $out"
STATE="$HOME_DIR/state"; MARKER="$STATE/$ID.prompt-waiting"
echo "# claude $(claude --version | head -1); spawn wrote hooks: $(jq -c '.hooks | keys' "$WT/.claude/settings.local.json")"
mkdir -p "$WT/scr/trees"; : > "$WT/scr/trees/keep"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -n "$WIN" -c "$WT" -x 200 -y 50 \
  "claude --dangerously-skip-permissions --model haiku" || fail "start claude"
SOCK_PATH=$(tmux -L "$SOCKET" display -p '#{socket_path}')
# Point the task record at the real pane.
sed -i "s|^window=.*|window=$SESSION:$WIN|; s|^backend=.*|backend=tmux|" "$STATE/$ID.meta"
grep -q '^backend=' "$STATE/$ID.meta" || echo backend=tmux >> "$STATE/$ID.meta"
echo "# task meta: $(tr '\n' ' ' < "$STATE/$ID.meta" | grep -o 'window=[^ ]*\|harness=[^ ]*\|backend=[^ ]*' | tr '\n' ' ')"
cap() { tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$WIN"; }
n=0
while [ "$n" -lt 30 ]; do
  pane=$(cap)
  if printf '%s' "$pane" | grep -q 'Yes, I trust this folder'; then
    printf '%s' "$pane" | grep -q '❯ No, exit' && tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" Down && sleep 1
    tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" Enter; sleep 5
  elif printf '%s' "$pane" | grep -q 'bypass permissions'; then break; fi
  sleep 2; n=$((n + 1))
done
sleep 4
FUT=$(date -u -d '+2 hours' +%Y-%m-%dT%H:%MZ)
printf 'paused: 8 research agents running; resume when they report, until %s\n' "$FUT" > "$STATE/$ID.status"
echo "# status: $(cat "$STATE/$ID.status")"

watch_env() {
  ${WEXEC:-} env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$HOME_DIR" TMUX="$SOCK_PATH,0,0" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 "$@"
}
run_for() {  # <watch-bin> <secs> <out> -> 0 if exited (woke), 1 if still running
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

echo "## settle: let the watcher absorb the fresh paused status before the dialog (no marker yet)"
for a in 1 2 3 4 5; do
  if run_for "$ROOT/bin/fm-watch.sh" 20 "$LAB/settle.out"; then
    echo "settle run $a woke: $(cat "$LAB/settle.out" | tr '\n' ' ')"; ack_all || fail "ack"
  else
    echo "settle run $a: quiet for 20s"; break
  fi
done

tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" -l 'Use the Bash tool to run exactly this command and nothing else, then stop: S=$PWD/scr; cd $S; rm -f trees/*'
sleep 2; tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" Enter
i=0; while [ "$i" -lt 60 ] && [ ! -s "$MARKER" ]; do sleep 2; i=$((i+1)); done
[ -s "$MARKER" ] || fail "no prompt marker"
sleep 3
cap > "$EV/claude-dialog-pane.txt"
grep -q 'Do you want to proceed' "$EV/claude-dialog-pane.txt" || fail "dialog not on screen"
echo "# marker: $(cat "$MARKER"); dialog on screen (pane saved to claude-dialog-pane.txt)"

echo
echo "## S-incident-base: base watcher ($BASE) with the dialog on screen under paused-until"
mkdir -p "$LAB/base"; git archive "$BASE" | tar -x -C "$LAB/base"
if run_for "$LAB/base/bin/fm-watch.sh" 40 "$LAB/base.out"; then
  echo "base watcher woke: $(cat "$LAB/base.out")"; BASE_SILENT=0
else
  echo "base watcher still silent after 40s; queue=[$(cat "$STATE/.wake-queue" 2>/dev/null)]"
  echo "base triage tail:"; tail -5 "$STATE/.watch-triage.log" 2>/dev/null | sed 's/^/  /'; BASE_SILENT=1
fi
# Same state continues: the base watcher never writes the prompt-surfaced or push-fallback markers.

echo
echo "## S-incident-branch: branch watcher with the same dialog under paused-until"
if run_for "$ROOT/bin/fm-watch.sh" 40 "$LAB/branch.out"; then
  echo "branch watcher output: $(cat "$LAB/branch.out")"
else
  fail "branch watcher did not wake within 40s: $(cat "$LAB/branch.out")"
fi
grep -Fxq "stale: $SESSION:$WIN (a permission or question prompt is waiting in the pane)" "$LAB/branch.out" || fail "wrong wake reason"
echo "wake-queue: $(cat "$STATE/.wake-queue")"
ok "branch watcher wakes firstmate with the prompt reason through a future paused-until"

echo
echo "## S-once-per-marker: acknowledged, relaunched watcher does not re-wake for the same dialog"
ack_all || fail "ack"
if run_for "$ROOT/bin/fm-watch.sh" 30 "$LAB/again.out"; then
  fail "relaunched watcher re-woke for the same marker: $(cat "$LAB/again.out")"
fi
ok "the same marker does not wake again across a relaunch (30s, dialog still on screen)"
tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" Escape; sleep 3
[ -e "$WT/scr/trees/keep" ] || fail "dismissed command ran"
[ "$BASE_SILENT" = 1 ] && ok "base watcher stayed silent with the dialog on screen (incident reproduced)" || echo "note - base watcher was not silent"
