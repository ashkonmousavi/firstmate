#!/usr/bin/env bash
# Live driver: real fm-supervise-daemon.sh (native launch record) + its real fm-watch.sh child,
# real tasks-axi backlog, injecting into a real Claude Code pane in an fm-lab-* Herdr session.
set -u
ROOT=$1 S=$2 PANE=$3 H=$4
rm -rf "$H"; mkdir -p "$H/config" "$H/data" "$H/state"
printf '2\n' > "$H/config/writing-lane-cap"
printf '# Backlog\n\n## Queued\n- [ ] lab-ready-one - Lab dispatchable item (kind: ship)\n' > "$H/data/backlog.md"
echo "--- tasks-axi ready (the backlog the watcher reads) ---"
FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" ready
date '+%s' > "$H/state/.afk"
printf 'none\t-\tnative\n' > "$H/state/.afk-daemon-terminal"
HERDR_SESSION="$S" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" \
FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$S:$PANE" \
FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_IDLE_LANE_CHECK_INTERVAL=2 \
FM_STALE_ESCALATE_SECS=999999 \
  nohup "$ROOT/bin/fm-supervise-daemon.sh" > "$H/daemon.out" 2> "$H/daemon.err" &
echo "$!" > "$H/daemon.pid"
echo "daemon pid $(cat "$H/daemon.pid")"
