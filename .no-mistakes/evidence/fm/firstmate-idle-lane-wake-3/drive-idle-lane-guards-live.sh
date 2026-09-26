#!/usr/bin/env bash
# Live driver: the real bin/fm-watch.sh with the real tasks-axi backlog (no fakes), exercising
# the idle-lane guards: wake once, no repeat for an unchanged ready set, re-wake on a changed set,
# stay quiet when every writing lane is occupied, and ignore public follow-up obligations.
set -u
ROOT=$1 H=$2
rm -rf "$H"; mkdir -p "$H/config" "$H/data" "$H/state"
printf '2\n' > "$H/config/writing-lane-cap"
printf '# Backlog\n\n## Queued\n- [ ] lab-ready-one - Lab dispatchable item (kind: ship)\n' > "$H/data/backlog.md"
run() {  # <label> ; prints wake or QUIET within 8s
  local out="$H/watch.out" pid i=0
  : > "$out"
  FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_IDLE_LANE_CHECK_INTERVAL=0 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$ROOT/bin/fm-watch.sh" > "$out" 2>>"$H/watch.err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 16 ]; do sleep 0.5; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; wait "$pid" 2>/dev/null; echo "[$1] QUIET (no wake in 8s)"
  else wait "$pid" 2>/dev/null; echo "[$1] WAKE: $(cat "$out")"; fi
}
run "1 free lanes + 1 ready item"
run "2 same state again (repeat guard)"
printf '%s\n' '- [ ] lab-ready-two - Second dispatchable item (kind: ship)' >> "$H/data/backlog.md"
run "3 ready set changed"
printf 'window=lab:one\nkind=ship\n' > "$H/state/one.meta"; printf 'window=lab:two\nkind=ship\n' > "$H/state/two.meta"
run "4 both lanes occupied by ship crews"
echo "    marker after full cap: $(test -e "$H/state/.last-idle-lane-wake" && echo present || echo removed)"
rm -f "$H/state/one.meta" "$H/state/two.meta"
printf '# Backlog\n\n## Queued\n' > "$H/data/backlog.md"
run "5 free lanes but empty backlog"
echo "--- durable wake queue rows:"; cat "$H/state/.wake-queue"
