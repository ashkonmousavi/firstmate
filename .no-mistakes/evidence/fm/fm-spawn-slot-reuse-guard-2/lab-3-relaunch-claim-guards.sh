#!/usr/bin/env bash
# Live lab phase 3: relaunch guards against a LIVE claude worker (lab-t1).
#  a) the copy's claim names an unfinished, alive task -> refuse, worker untouched
#  b) another process holds the Treehouse project lock -> refuse, worker untouched
#  c) the claim names a finished scout -> re-claim with a note, relaunch, and the
#     project lock is released before the launch finishes
set -u
. /home/tegris/.no-mistakes/evidence/01M3VZF72MYDKFSVPWF8SMTY11/lab-env.sh
cd "$WT" || exit 1
SLOT1=$LAB/pool/.treehouse/demo-55bf35/1/demo
CLAIM1=$LAB/pool/.treehouse/demo-55bf35/1/.fm-slot-owner
agent_of() { labtmux display-message -p -t "firstmate:fm-$1" '#{pane_current_command} pane_pid=#{pane_pid}'; }
agent_pids() { pgrep -P "$(labtmux display-message -p -t "firstmate:fm-$1" '#{pane_pid}')" | tr '\n' ' '; }
LOCK=$(fm bash -c '. bin/fm-wake-lib.sh; fm_treehouse_project_lock_path "$1"' _ "$PROJ")
echo "project lock path: $LOCK"

step "a) claim on lab-t1's copy names lab-t2 (unfinished scout, worker alive)"
printf 'task=lab-t2\nhome=%s\n' "$LAB" > "$CLAIM1"
echo "lab-t1 before: $(agent_of lab-t1) children=$(agent_pids lab-t1)"
fm bin/fm-control.sh lab-t1 relaunch --note "Lab guard a" 2>&1 | tail -3; echo "rc=${PIPESTATUS[0]}"
echo "lab-t1 after:  $(agent_of lab-t1) children=$(agent_pids lab-t1)"
echo "claim after: $(tr '\n' ' ' < "$CLAIM1")"
ls "$LAB/state/lab-t1.control-relaunch"* 2>/dev/null || echo "no relaunch journal written"
printf 'task=lab-t1\nhome=%s\n' "$LAB" > "$CLAIM1"

step "b) another process holds the Treehouse project lock"
rm -f "$LAB/lock-held" "$LAB/lock-release"
fm bash -c '. bin/fm-wake-lib.sh; fm_lock_try_acquire "$1" || exit 1; echo "holder pid $$" > "$2/lock-held"; until [ -e "$2/lock-release" ]; do sleep 0.2; done; fm_lock_release "$1"' _ "$LOCK" "$LAB" &
holder=$!
until [ -e "$LAB/lock-held" ]; do sleep 0.1; done
cat "$LAB/lock-held"; echo "lock pid file: $(cat "$LOCK/pid" 2>/dev/null)"
echo "lab-t1 before: $(agent_of lab-t1) children=$(agent_pids lab-t1)"
fm bin/fm-control.sh lab-t1 relaunch --note "Lab guard b" 2>&1 | tail -3; echo "rc=${PIPESTATUS[0]}"
echo "lab-t1 after:  $(agent_of lab-t1) children=$(agent_pids lab-t1)"
echo "claim after: $(tr '\n' ' ' < "$CLAIM1")"
touch "$LAB/lock-release"; wait "$holder"
[ -e "$LOCK" ] && echo "lock still present" || echo "lock released by its holder"

step "c) lab-t2 finishes (stopped, report written); lab-t1's claim names it"
fm bin/fm-control.sh lab-t2 exit 2>&1 | tail -2
printf '# Report\nLab scout report.\n' > "$LAB/data/lab-t2/report.md"
echo "lab-t2 endpoint: $(agent_of lab-t2)"
printf 'task=lab-t2\nhome=%s\n' "$LAB" > "$CLAIM1"
old_children=$(agent_pids lab-t1)
echo "lab-t1 before: $(agent_of lab-t1) children=$old_children"
( while :; do if [ -e "$LOCK" ]; then echo "$(date +%T.%N) lock HELD"; else echo "$(date +%T.%N) lock free"; fi; sleep 0.25; done ) > "$LAB/lock-poll.txt" &
poller=$!
fm bin/fm-control.sh lab-t1 relaunch --note "Lab guard c" 2>&1 | tail -4; echo "rc=${PIPESTATUS[0]}"
kill "$poller"
echo "lock polls during relaunch: held=$(grep -c HELD "$LAB/lock-poll.txt") free=$(grep -c free "$LAB/lock-poll.txt")"
echo "lab-t1 after:  $(agent_of lab-t1) children=$(agent_pids lab-t1) (before: $old_children)"
echo "claim after: $(tr '\n' ' ' < "$CLAIM1")"
