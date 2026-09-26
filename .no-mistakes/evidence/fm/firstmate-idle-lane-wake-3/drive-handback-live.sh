#!/usr/bin/env bash
# Live driver: native-launched fm-supervise-daemon.sh whose watcher cannot start because a
# non-watcher process holds the watcher lock. Supervisor pane is a real Claude Code pane in an
# fm-lab-* Herdr session. FM_WEDGE_ALARM_CHANNEL is unset, so the Linux + Herdr "auto" default applies.
# A thin herdr shim records `notification show` calls and pins them to the lab session, forwarding to real herdr.
set -u
ROOT=$1 S=$2 PANE=$3 H=$4
rm -rf "$H"; mkdir -p "$H/state" "$H/shim"
REAL=$(command -v herdr)
cat > "$H/shim/herdr" <<SH
#!/usr/bin/env bash
if [ "\$1" = notification ]; then
  printf '%s\n' "\$*" >> "$H/herdr-notifications.log"
  exec "$REAL" "\$@" --session "$S"
fi
exec "$REAL" "\$@"
SH
chmod +x "$H/shim/herdr"
sleep 300 & PEER=$!
echo "$PEER" > "$H/peer.pid"
mkdir -p "$H/state/.watch.lock"; printf '%s\n' "$PEER" > "$H/state/.watch.lock/pid"
touch "$H/state/.last-watcher-beat"
date '+%s' > "$H/state/.afk"
printf 'none\t-\tnative\n' > "$H/state/.afk-daemon-terminal"
printf 'needs-decision: lab held choice\n' > "$H/state/.subsuper-escalations"
date '+%s' > "$H/state/.subsuper-escalations.since"
echo "--- before: .afk=$(test -e "$H/state/.afk" && echo present) buffer=$(cat "$H/state/.subsuper-escalations")"
start=$(date +%s)
PATH="$H/shim:$PATH" HERDR_SESSION="$S" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" \
FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$S:$PANE" \
FM_ESCALATE_BATCH_SECS=99999 FM_HOUSEKEEPING_TICK=1 FM_POLL=1 \
FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_STALE_ESCALATE_SECS=999999 \
  timeout 60 "$ROOT/bin/fm-supervise-daemon.sh" > "$H/daemon.out" 2>&1
rc=$?
echo "--- daemon exited rc=$rc after $(( $(date +%s) - start ))s (124 would mean it kept holding supervision)"
echo "--- daemon stdout/stderr:"; cat "$H/daemon.out"
echo "--- after: .afk $(test -e "$H/state/.afk" && echo STILL PRESENT || echo cleared)"
echo "--- after: escalation buffer: '$(cat "$H/state/.subsuper-escalations" 2>/dev/null)'"
echo "--- durable wake queue:"; cat "$H/state/.wake-queue" 2>/dev/null
echo "--- real herdr notification calls (lab session):"; cat "$H/herdr-notifications.log" 2>/dev/null
echo "--- daemon log:"; cat "$H/state/.supervise-daemon.log"
kill "$PEER" 2>/dev/null
