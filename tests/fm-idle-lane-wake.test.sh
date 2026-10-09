#!/usr/bin/env bash
# Idle writing-capacity wake through the executable watcher and tasks-axi ready.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-idle-lane-wake)

run_watch() {  # <home> <output>
  local home=$1 output=$2
  # Test recent-marker suppression independently of host clock corrections,
  # which can make a fresh mtime future-dated and intentionally due again.
  if [ -f "$home/state/.last-idle-lane-wake" ]; then
    fm_touch_epoch "$(( $(date +%s) - 60 ))" "$home/state/.last-idle-lane-wake"
  fi
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
  printf 'state: parked · source: run-step · approval gate fixture\n'
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
  grep -F '0/2 occupied, 0 working, 1 ready: ready-one' "$out" >/dev/null \
    || fail "idle wake omitted the configured cap or ready id: $(cat "$out")"
  [ -s "$state/.wake-queue" ] || fail "idle wake was not durable"

  : > "$out"
  run_watch "$home" "$out"
  stop_quiet_watch "$out"

  printf '%s\n' '- [ ] ready-two - Another dispatchable item with a deliberately long title that makes the ready listing wrap onto a continuation line before the next item is listed (kind: ship)' >> "$home/data/backlog.md"
  run_watch "$home" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "a changed ready set did not wake"
  grep -F '0/2 occupied, 0 working, 2 ready: ready-one,ready-two' "$out" >/dev/null \
    || fail "changed ready set was not named: $(cat "$out")"

  printf 'window=fixture:one\nkind=ship\n' > "$state/one.meta"
  : > "$state/one.busy"
  printf '%s\n' '- [ ] ready-three - A third dispatchable item (kind: ship)' >> "$home/data/backlog.md"
  : > "$out"
  run_watch "$home" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "one live crew under the cap hid free capacity"
  grep -F '1/2 occupied, 1 working, 3 ready:' "$out" >/dev/null \
    || fail "one working crew was not counted as an occupied lane: $(cat "$out")"

  rm -f "$state/one.busy"
  printf 'window=fixture:two\nkind=ship\n' > "$state/two.meta"
  : > "$out"
  run_watch "$home" "$out"
  stop_quiet_watch "$out"
  [ ! -e "$state/.last-idle-lane-wake" ] || fail "full writing cap retained the capacity wake marker"
  pass "watcher wakes once for configured free writing lanes and a changed ready set, not for empty capacity or a cap filled by parked crews"
}

test_public_followups_are_not_ready_work() {
  local home out real
  home=$(make_case public-followups)
  out="$home/watch.out"
  real=$(command -v tasks-axi) || fail "tasks-axi is not on PATH"
  mkdir -p "$home/config" "$home/data"
  printf '1\n' > "$home/config/writing-lane-cap"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
[ "\$1" = ready ] || exec "$real" "\$@"
printf '%s\\n' 'count: 1' \\
  'ready[1]{id,state,kind,repo,title}:' \\
  '  ready-one,queued,ship,"-",One' \\
  'ready_public_followups[1]{id,state,kind,repo,title,delivery_state}:' \\
  '  public-final-ab,queued,public-followup,"-",Promised final,ready' \\
  'help[1]:' \\
  '  - Run \`tasks-axi start <id>\` to dispatch one of these'
SH
  chmod +x "$home/fakebin/tasks-axi"
  run_watch "$home" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "idle capacity did not wake with ready work beside a public follow-up"
  grep -F '0/1 occupied, 0 working, 1 ready: ready-one' "$out" >/dev/null \
    || fail "a public follow-up obligation was reported as dispatchable work: $(cat "$out")"
  pass "watcher names only dispatchable ready rows, not public follow-up obligations"
}

test_local_completion_links_do_not_consume_release_capacity() {
  local home state out url index=0 failures=0
  for url in \
    'https://docs.example.test/setup' \
    'https://github.com/example/repo/issues/7'; do
    index=$((index + 1))
    home=$(make_case "local-completion-link-$index")
    state="$home/state"; out="$home/watch.out"
    mkdir -p "$home/config" "$home/data"
    cat > "$home/fakebin/crew-state" <<'SH'
#!/usr/bin/env bash
cat "$FM_HOME/state/$1.crew-state"
SH
    chmod +x "$home/fakebin/crew-state"
    printf '3\n' > "$home/config/writing-lane-cap"
    printf '1\n' > "$home/config/release-capacity"
    printf '# Backlog\n\n## Queued\n- [ ] repair-one - A dispatchable repair (kind: ship)\n' > "$home/data/backlog.md"
    printf 'kind=ship\nmode=local-only\n' > "$state/one.meta"
    printf 'state: done · source: status-log · local branch ready: 4646464646464646464646464646464646464646; reference: %s\n' "$url" > "$state/one.crew-state"
    run_watch "$home" "$out"
    wait_for_exit "$WATCH_PID" 100 || fail "completed local-only work with a reference did not wake: $url"
    if ! grep -F 'idle writing lanes: 1/3 occupied' "$out" >/dev/null \
      || grep -F 'lane backpressure' "$out" >/dev/null; then
      printf 'not ok - local-only reference consumed release capacity: %s: %s\n' "$url" "$(cat "$out")" >&2
      failures=$((failures + 1))
    fi
  done
  [ "$failures" -eq 0 ] || fail "$failures local-only reference cases consumed release capacity"
  pass "documentation and issue links on completed local-only lanes preserve ordinary idle wakes"
}

test_release_backpressure_names_the_bottleneck() {
  local home state out
  home=$(make_case release-backpressure)
  state="$home/state"; out="$home/watch.out"
  mkdir -p "$home/config" "$home/data"
  cat > "$home/fakebin/crew-state" <<'SH'
#!/usr/bin/env bash
if [ -e "$FM_HOME/state/$1.crew-state" ]; then
  cat "$FM_HOME/state/$1.crew-state"
else
  printf 'state: working · source: pane · writing fixture\n'
fi
SH
  chmod +x "$home/fakebin/crew-state"
  printf '3\n' > "$home/config/writing-lane-cap"
  printf '1\n' > "$home/config/release-capacity"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '%s\n' '- [ ] repair-one - A dispatchable repair (kind: ship)' >> "$home/data/backlog.md"
  printf 'kind=ship\n' > "$state/one.meta"
  run_watch "$home" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "free capacity under the release bound did not wake"
  grep -F 'idle writing lanes: 1/3 occupied' "$out" >/dev/null \
    || fail "an unpublished lane was counted as release pressure: $(cat "$out")"

  printf 'state: working · source: run-step · validating (running)\n' > "$state/one.crew-state"
  : > "$out"
  run_watch "$home" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "unpublished validation backpressure did not wake"
  grep -F 'lane backpressure: 1/1 lanes awaiting validation or release' "$out" >/dev/null \
    || fail "unpublished validation did not count as release pressure: $(cat "$out")"
  grep -F '1 ready: repair-one' "$out" >/dev/null \
    || fail "validation backpressure hid the dispatchable repair: $(cat "$out")"

  printf 'state: parked · source: run-step · parked at fix_review\n' > "$state/one.crew-state"
  : > "$out"
  run_watch "$home" "$out"
  stop_quiet_watch "$out"

  printf 'state: done · source: run-step · checks green: PR ready for review (still monitoring for merge/close): https://github.com/example/repo/pull/7\n' > "$state/one.crew-state"
  : > "$out"
  run_watch "$home" "$out"
  stop_quiet_watch "$out"

  printf 'state: done · source: run-step · run passed: PR open\n' > "$state/one.crew-state"
  : > "$out"
  run_watch "$home" "$out"
  stop_quiet_watch "$out"

  printf 'state: done · source: status-log · PR https://github.com/example/repo/pull/7 checks green\n' > "$state/one.crew-state"
  : > "$out"
  run_watch "$home" "$out"
  stop_quiet_watch "$out"

  printf 'state: failed · source: run-step · run failed\n' > "$state/one.crew-state"
  : > "$out"
  run_watch "$home" "$out"
  stop_quiet_watch "$out"

  printf 'mode=local-only\n' >> "$state/one.meta"
  printf 'state: done · source: status-log · local branch ready: 4646464646464646464646464646464646464646\n' > "$state/one.crew-state"
  : > "$out"
  run_watch "$home" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "completed local-only work did not release capacity"
  grep -F 'idle writing lanes: 1/3 occupied' "$out" >/dev/null \
    || fail "a local-only completion with no PR or run retained release pressure: $(cat "$out")"

  printf 'state: done · source: status-log · PR https://github.com/example/repo/pull/7 checks green\n' > "$state/one.crew-state"
  : > "$out"
  run_watch "$home" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "reported PR did not restore release pressure"
  grep -F 'lane backpressure: 1/1 lanes awaiting validation or release' "$out" >/dev/null \
    || fail "a reported PR URL did not count without metadata: $(cat "$out")"

  printf 'state: done · source: status-log · checks green · run still monitoring PR\n' > "$state/one.crew-state"
  : > "$out"
  run_watch "$home" "$out"
  stop_quiet_watch "$out"

  rm "$state/one.meta"
  : > "$out"
  run_watch "$home" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "retired validation did not release capacity"
  grep -F 'idle writing lanes: 0/3 occupied' "$out" >/dev/null \
    || fail "retired validation still counted as pressure: $(cat "$out")"

  printf 'kind=ship\n' > "$state/one.meta"
  printf 'state: parked · source: run-step · parked at fix_review\n' > "$state/one.crew-state"
  : > "$out"
  run_watch "$home" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "parked unpublished validation backpressure did not wake"
  grep -F 'lane backpressure: 1/1 lanes awaiting validation or release' "$out" >/dev/null \
    || fail "parked unpublished validation did not count as pressure: $(cat "$out")"

  printf 'state: working · source: pane · writing fixture\n' > "$state/one.crew-state"
  : > "$out"
  run_watch "$home" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "resumed writing did not release validation capacity"
  grep -F 'idle writing lanes: 1/3 occupied' "$out" >/dev/null \
    || fail "writing through the pane still counted as validation pressure: $(cat "$out")"

  printf 'state: working · source: run-step · validating (fixing)\n' > "$state/one.crew-state"
  printf 'pr=https://github.com/example/repo/pull/7\n' >> "$state/one.meta"
  : > "$out"
  run_watch "$home" "$out"
  wait_for_exit "$WATCH_PID" 100 || fail "release backpressure did not wake"
  grep -F 'lane backpressure: 1/1 lanes awaiting validation or release' "$out" >/dev/null \
    || fail "backpressure did not name the release bottleneck: $(cat "$out")"
  grep -F '1 ready: repair-one' "$out" >/dev/null \
    || fail "backpressure hid the dispatchable repair: $(cat "$out")"
  if grep -F 'idle writing lanes' "$out" >/dev/null; then
    fail "backpressure still asked to fill idle lanes: $(cat "$out")"
  fi

  printf 'state: done · source: run-step · run completed\n' > "$state/one.crew-state"
  : > "$out"
  run_watch "$home" "$out"
  stop_quiet_watch "$out"

  pass "watcher retains validation and ready-PR pressure until retirement and counts each published lane once"
}

test_unknown_release_state_suppresses_capacity_notices() {
  local home state out verdict index=0
  for verdict in \
    'state: unknown · source: run-step · selected run unreadable' \
    'state: unknown · source: pane · harness state unavailable' \
    'state: unknown · source: none · no current-state source available' \
    'state: unknown · source: status-log · unavailable' \
    'state: blocked · source: status-log · daemon socket down despite attributed run record' \
    'state: parked · source: status-log · decision open · UNVERIFIED daemon-down record · run: fixture-run' \
    'state: working · source: status-log · working declaration' \
    'state: paused · source: status-log · external wait' \
    'state: failed · source: status-log · validation failed' \
    'state: working · source: unrecognized · unavailable' \
    'state: unrecognized · source: run-step · unavailable' \
    'state: working source: pane' \
    $'state: working · source: pane · writing\nstate: unknown · source: run-step · unreadable' \
    'unparseable crew state' '' read-failed; do
    index=$((index + 1))
    home=$(make_case "unknown-release-$index")
    state="$home/state"; out="$home/watch.out"
    mkdir -p "$home/config" "$home/data"
    cat > "$home/fakebin/crew-state" <<'SH'
#!/usr/bin/env bash
[ ! -e "$FM_HOME/state/$1.read-failed" ] || exit 1
cat "$FM_HOME/state/$1.crew-state"
SH
    chmod +x "$home/fakebin/crew-state"
    printf '3\n' > "$home/config/writing-lane-cap"
    printf '1\n' > "$home/config/release-capacity"
    printf '# Backlog\n\n## Queued\n- [ ] repair-one - A dispatchable repair (kind: ship)\n' > "$home/data/backlog.md"
    printf 'kind=ship\n' > "$state/one.meta"
    printf '%s\n' "$verdict" > "$state/one.crew-state"
    [ "$verdict" != read-failed ] || touch "$state/one.read-failed"
    run_watch "$home" "$out"
    stop_quiet_watch "$out"
    [ ! -e "$state/.last-idle-lane-wake" ] || fail "unknown release state committed a capacity notice: $verdict"
    grep -F 'idle-lane release state unavailable: one' "$state/.watch-triage.log" >/dev/null \
      || fail "unknown release state did not name the unavailable lane: $verdict"

    printf 'pr=https://github.com/example/repo/pull/7\n' >> "$state/one.meta"
    : > "$out"
    run_watch "$home" "$out"
    wait_for_exit "$WATCH_PID" 100 || fail "recorded PR did not establish release pressure: $verdict"
    grep -F 'lane backpressure: 1/1 lanes awaiting validation or release' "$out" >/dev/null \
      || fail "recorded PR pressure depended on unavailable crew state: $verdict"
  done
  pass "unknown, unreadable, or noncompletion status-log states suppress capacity notices unless a recorded PR establishes pressure"
}

test_invalid_release_capacity_suppresses_notices() {
  local value home out diagnostic index=0 failures=0
  for value in 00 0 0000 -1 '' zero 9223372036854775808 18446744073709551616 9999999999999999999999999999999999999999 read-error dangling-symlink; do
    index=$((index + 1))
    (
      home=$(make_case "invalid-release-capacity-$index")
      out="$home/watch.out"
      mkdir -p "$home/config" "$home/data"
      printf '3\n' > "$home/config/writing-lane-cap"
      printf '# Backlog\n\n## Queued\n- [ ] repair-one - A dispatchable repair (kind: ship)\n' > "$home/data/backlog.md"
      diagnostic='invalid config/release-capacity'
      case "$value" in
        read-error)
          mkdir "$home/config/release-capacity"
          diagnostic='unreadable config/release-capacity' ;;
        dangling-symlink)
          ln -s missing-capacity "$home/config/release-capacity"
          diagnostic='unreadable config/release-capacity' ;;
        *) printf '%s\n' "$value" > "$home/config/release-capacity" ;;
      esac
      run_watch "$home" "$out"
      stop_quiet_watch "$out"
      [ ! -e "$home/state/.last-idle-lane-wake" ] || fail "invalid capacity committed a notice: $value"
      [ ! -s "$home/state/.wake-queue" ] || fail "invalid capacity queued a wake: $value"
      grep -F "$diagnostic" "$home/state/.watch-triage.log" >/dev/null 2>&1 \
        || fail "capacity $value did not report $diagnostic"
      pass "capacity '$value' suppresses notices and logs its cause"
    ) || failures=$((failures + 1))
  done
  [ "$failures" -eq 0 ] || fail "$failures invalid release-capacity cases failed"
}

test_release_metadata_only_invalidates_configured_notices() {
  local configured home state out marker failures=0
  for configured in absent 1 0001 9223372036854775807; do
    (
      home=$(make_case "release-metadata-$configured")
      state="$home/state"; out="$home/watch.out"
      mkdir -p "$home/config" "$home/data"
      cat > "$home/fakebin/crew-state" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: pane · writing fixture\n'
SH
      chmod +x "$home/fakebin/crew-state"
      printf '3\n' > "$home/config/writing-lane-cap"
      [ "$configured" = absent ] || printf '%s\n' "$configured" > "$home/config/release-capacity"
      printf '# Backlog\n\n## Queued\n- [ ] repair-one - A dispatchable repair (kind: ship)\n' > "$home/data/backlog.md"
      printf 'kind=ship\n' > "$state/one.meta"
      run_watch "$home" "$out"
      wait_for_exit "$WATCH_PID" 100 || fail "initial capacity notice did not wake: $configured"
      grep -F 'idle writing lanes: 1/3 occupied' "$out" >/dev/null || fail "initial writing lane consumed release capacity"
      marker=$(cat "$state/.last-idle-lane-wake")
      : > "$out"
      run_watch "$home" "$out"
      stop_quiet_watch "$out"

      printf 'pr=https://github.com/example/repo/pull/7\n' >> "$state/one.meta"
      : > "$out"
      run_watch "$home" "$out"
      if [ "$configured" = absent ]; then
        stop_quiet_watch "$out"
        [ "$(cat "$state/.last-idle-lane-wake")" = "$marker" ] || fail "unconfigured PR changed the notice marker"
      else
        wait_for_exit "$WATCH_PID" 100 || fail "configured PR did not update the capacity notice: $configured"
        case "$configured" in
          1|0001)
            grep -F "lane backpressure: 1/$configured lanes awaiting validation or release" "$out" >/dev/null \
              || fail "configured recorded PR did not saturate release capacity"
            grep -F '1 ready: repair-one' "$out" >/dev/null || fail "configured backpressure lost the ready repair" ;;
          *) grep -F 'idle writing lanes: 1/3 occupied' "$out" >/dev/null || fail "maximum supported capacity was not usable" ;;
        esac
      fi
      : > "$out"
      run_watch "$home" "$out"
      stop_quiet_watch "$out"

      printf 'kind=ship\n' > "$state/one.meta"
      : > "$out"
      run_watch "$home" "$out"
      if [ "$configured" = absent ]; then
        stop_quiet_watch "$out"
        [ "$(cat "$state/.last-idle-lane-wake")" = "$marker" ] || fail "unconfigured PR removal changed the notice marker"
      else
        wait_for_exit "$WATCH_PID" 100 || fail "removed PR did not release capacity: $configured"
        grep -F 'idle writing lanes: 1/3 occupied' "$out" >/dev/null || fail "removed PR retained release pressure"
      fi
      pass "release metadata only changes notices when capacity is configured: $configured"
    ) || failures=$((failures + 1))
  done
  [ "$failures" -eq 0 ] || fail "$failures release metadata cases failed"
}

test_idle_capacity_wake
test_public_followups_are_not_ready_work
test_local_completion_links_do_not_consume_release_capacity
test_release_backpressure_names_the_bottleneck
test_unknown_release_state_suppresses_capacity_notices
test_invalid_release_capacity_suppresses_notices
test_release_metadata_only_invalidates_configured_notices
