#!/usr/bin/env bash
# Idle writing-capacity wake through the executable watcher and tasks-axi ready.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-idle-lane-wake)

run_watch() {  # <home> <output>
  local home=$1 output=$2
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_IDLE_LANE_CHECK_INTERVAL=0 FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_CREW_STATE_BIN="$home/fakebin/crew-state" \
    "$WATCH" > "$output" 2> "$home/watch.err" &
  WATCH_PID=$!
}

stop_quiet_watch() {  # <output>
  local output=$1
  sleep 2
  if ! is_live_non_zombie "$WATCH_PID"; then
    wait "$WATCH_PID" 2>/dev/null || true
    fail "watcher surfaced a wake when none was due: $(cat "$output")"
  fi
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  [ ! -s "$output" ] || fail "quiet watcher printed an actionable wake: $(cat "$output")"
}

test_idle_capacity_wake() {
  local home state out
  home=$(make_case idle-capacity)
  state="$home/state"; out="$home/watch.out"
  mkdir -p "$home/config" "$home/data"
  cat > "$home/fakebin/crew-state" <<'SH'
#!/usr/bin/env bash
if [ -e "$FM_HOME/state/$1.busy" ]; then
  printf 'state: working · source: pane · fixture\n'
else
  printf 'state: working · source: status-log · stale fixture\n'
fi
SH
  chmod +x "$home/fakebin/crew-state"
  printf '2\n' > "$home/config/writing-lane-cap"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  run_watch "$home" "$out"
  stop_quiet_watch "$out"

  printf '%s\n' '- [ ] ready-one - One dispatchable item (kind: ship)' >> "$home/data/backlog.md"
  run_watch "$home" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "idle capacity did not wake with ready work"
  grep -F '0/2 active, 1 ready: ready-one' "$out" >/dev/null \
    || fail "idle wake omitted the configured cap or ready id: $(cat "$out")"
  [ -s "$state/.wake-queue" ] || fail "idle wake was not durable"

  : > "$out"
  run_watch "$home" "$out"
  stop_quiet_watch "$out"

  printf '%s\n' '- [ ] ready-two - Another dispatchable item with a deliberately long title that makes the ready listing wrap onto a continuation line before the next item is listed (kind: ship)' >> "$home/data/backlog.md"
  run_watch "$home" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "a changed ready set did not wake"
  grep -F '0/2 active, 2 ready: ready-one,ready-two' "$out" >/dev/null \
    || fail "changed ready set was not named: $(cat "$out")"

  printf 'window=fixture:one\nkind=ship\n' > "$state/one.meta"
  printf 'working: writing\n' > "$state/one.status"
  prime_status_seen "$state" "$state/one.status"
  printf 'window=fixture:two\nkind=ship\n' > "$state/two.meta"
  printf 'working: writing\n' > "$state/two.status"
  prime_status_seen "$state" "$state/two.status"
  printf '%s\n' '- [ ] ready-three - A third dispatchable item (kind: ship)' >> "$home/data/backlog.md"
  : > "$out"
  run_watch "$home" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "stale working statuses hid free capacity"
  grep -F '0/2 active, 3 ready:' "$out" >/dev/null \
    || fail "stale working statuses counted as active lanes: $(cat "$out")"

  : > "$state/one.busy"
  : > "$state/two.busy"
  : > "$out"
  run_watch "$home" "$out"
  stop_quiet_watch "$out"
  [ ! -e "$state/.last-idle-lane-wake" ] || fail "full writing cap retained the capacity wake marker"
  pass "watcher wakes once for configured free writing lanes and a changed ready set, not for empty or full capacity"
}

test_idle_capacity_wake
