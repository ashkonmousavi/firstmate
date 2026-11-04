#!/usr/bin/env bash
# Claude mid-turn continuity and stale-beacon fleet command seatbelt.
# shellcheck disable=SC2016 # Commands are data evaluated only inside the fixture harness.
set -u
# Reuse the fixture harness and the repository-owned Stop hand-back deadline.
# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"
fm_git_identity fmtest fmtest@example.invalid
export FAKE_CLAUDE
export -f wait_until_deadline
# Hook scope must resolve each copied primary, not the wake helper's non-git
# root used to suppress unrelated drain warnings.
unset FM_ROOT_OVERRIDE

make_guard_home() {
  local home=$1
  mkdir -p "$home/state" "$home/config"
  git init -q "$home"
  : > "$home/AGENTS.md"
  cp -R "$ROOT/bin" "$home/bin"
  printf 'project=fixture\nwindow=fixture\n' > "$home/state/task.meta"
}

run_check() {
  local home=$1 command=$2
  jq -cn --arg command "$command" '{tool_name:"Bash",tool_input:{command:$command}}' |
    FM_HOME="$home" "$FAKE_CLAUDE" -c '
      echo "$$" > "$FM_HOME/state/.lock"
      "$FM_HOME/bin/fm-claude-watch-guard.sh" --check
    '
}

test_stale_refusal_and_recovery() {
  local home="$TMP_ROOT/seatbelt" rc=0 out
  make_guard_home "$home"
  touch -t 200001010000 "$home/state/.last-watcher-beat"
  out=$(run_check "$home" 'FM_HOME=/fixture bash bin/fm-spawn.sh ship' 2>&1) || rc=$?
  [ "$rc" -eq 2 ] && [[ "$out" == *'watcher'* ]] || fail "stale or continuity contract failed"
  rc=0
  out=$(run_check "$home" 'bin/fm-send.sh worker hello' 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "stale or continuity contract failed"
  run_check "$home" 'bin/fm-watch-arm.sh --restart' >/dev/null || fail "stale or continuity contract failed"
  run_check "$home" 'cat bin/fm-send.sh' >/dev/null || fail "stale or continuity contract failed"
  touch "$home/state/.last-watcher-beat"
  run_check "$home" 'bin/fm-send.sh worker hello' || fail "stale or continuity contract failed"
  run_check "$home" 'bin/fm-spawn.sh ship' || fail "stale or continuity contract failed"
  pass "stale spawns and sends refuse; repair and reads remain available; fresh clears"
}

test_twenty_minute_turn() {
  local home="$TMP_ROOT/continuity" baseline="$TMP_ROOT/baseline"
  make_guard_home "$home"
  cat > "$home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/state/.last-watcher-beat"
sleep 0.5
printf 'signal: fixture\n'
SH
  chmod +x "$home/bin/fm-watch-arm.sh"
  make_guard_home "$baseline"
  touch "$home/state/.last-watcher-beat" "$baseline/state/.last-watcher-beat"
  node - "$home" "$baseline" <<'JS' &
const { statSync, writeFileSync } = require('node:fs');
const [home, baseline] = process.argv.slice(2);
const start = performance.now();
const epoch = Date.now();
let maxAge = 0;
const timer = setInterval(() => {
  const elapsed = performance.now() - start;
  const age = (epoch + elapsed - statSync(`${home}/state/.last-watcher-beat`).mtimeMs) * 60 / 1000;
  maxAge = Math.max(maxAge, age);
  if (elapsed < 20000) return;
  clearInterval(timer);
  const baselineAge = (epoch + elapsed - statSync(`${baseline}/state/.last-watcher-beat`).mtimeMs) * 60 / 1000;
  writeFileSync(`${home}/state/ages`, `${maxAge} ${baselineAge}\n`);
  writeFileSync(`${home}/state/.afk`, '');
}, 25);
JS
  local observer=$!
  FM_HOME="$home" FM_TEST_CLAUDE_WATCH_INTERVAL=0.01 "$FAKE_CLAUDE" -c '
    echo "$$" > "$FM_HOME/state/.lock"
    printf "{}" | "$FM_HOME/bin/fm-claude-watch-guard.sh"
  ' || fail "stale or continuity contract failed"
  wait "$observer" || fail "independent beat observer failed"
  awk '$1 < 300 && $2 >= 1200 {ok=1} END {exit !ok}' "$home/state/ages" || fail "independent elapsed beat age exceeded grace"
  printf '# guarded max age and unguarded final age (60x wall time): %s\n' "$(cat "$home/state/ages")"
  pass "20-minute MAIN turn remains covered without a Stop event"
}

test_command_positions() {
  local command result
  for command in 'env FM_HOME=/fixture bash bin/fm-send.sh x y' \
    '(bin/fm-spawn.sh x)' 'bash -c "bin/fm-send.sh x y"' \
    'bash -c "echo okay"; bin/fm-send.sh x y' \
    'echo "$(bin/fm-send.sh x y)"' 'bin/fm-"spawn".sh x' \
    'for id in a b; do bin/fm-send.sh "$id" hello; done' \
    'if true; then bin/fm-spawn.sh x; fi' \
    'while bin/fm-send.sh x y; do :; done' \
    '! bin/fm-send.sh x y' 'time bin/fm-spawn.sh x' \
    'env -S "bin/fm-send.sh x y"' \
    'eval "bin/fm-send.sh x y"' '. bin/fm-send.sh' \
    'builtin eval "bin/fm-send.sh x y"' \
    'tool=bin/fm-send.sh; "$tool" x y' \
    'payload="bin/fm-send.sh x y"; eval "$payload"' \
    'payload="bin/fm-send.sh x y"; bash -c "$payload"' \
    'script=bin/fm-send.sh; bash "$script" x y' \
    'script=bin/fm-send.sh; source "$script" x y' \
    'payload="bin/fm-send.sh x y"; env -S "$payload"' \
    'bash /dev/stdin <<< "bin/fm-send.sh x y"' \
    'bash <<EOF_PROGRAM
bin/fm-send.sh x y
EOF_PROGRAM' \
    'bash <<< "bin/fm-spawn.sh x"' \
    'bash < bin/fm-send.sh' 'printf "bin/fm-send.sh x y" | bash'; do
    result=$(printf '%s' "$command" | node "$ROOT/bin/fm-fleet-command-policy.mjs")
    [ "$result" = deny ] || fail "missed command position: $command"
  done
  for command in 'cat bin/fm-spawn.sh' 'echo "bin/fm-send.sh x y"' \
    'bash bin/fm-watch-arm.sh --restart' 'git status' \
    'bash -c "cat bin/fm-send.sh"' 'env -S "cat bin/fm-send.sh"' \
    'FM_HOME=/fixture env -S "cat bin/fm-send.sh"' \
    '(cat bin/fm-send.sh)' '{ echo bin/fm-spawn.sh; }' \
    'bash <<EOF_PROGRAM
cat bin/fm-send.sh
EOF_PROGRAM' \
    'bash <<< "echo bin/fm-spawn.sh"' \
    'cat <<EOF_DATA
bin/fm-send.sh x y
EOF_DATA'; do
    result=$(printf '%s' "$command" | node "$ROOT/bin/fm-fleet-command-policy.mjs")
    [ "$result" = allow ] || fail "blocked data or repair: $command"
  done
  pass "fleet mutation command positions include wrappers and nested execution, not data"
}

test_pending_wake_keeps_checks_running() {
  local mode home
  for mode in guard repair; do
    home="$TMP_ROOT/pending-$mode"
    make_guard_home "$home"
    rm "$home/state/task.meta"
    : > "$home/config/supervision-host-off"
    cat > "$home/state/continuity.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'checked\n' >> "$FM_HOME/state/checks"
SH
    chmod 700 "$home/state/continuity.check.sh"
    FM_HOME="$home" bash "$home/bin/fm-check-register.sh" continuity >/dev/null || fail "check fixture registration"
    append_wake "$home/state" check fixture "check: pending fixture wake"
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
      FM_TEST_CLAUDE_WATCH_INTERVAL=0.05 FM_GUARD_MODE="$mode" "$FAKE_CLAUDE" -c '
      cd "$FM_HOME" || exit 1
      echo "$$" > state/.lock
      if [ "$FM_GUARD_MODE" = guard ]; then
        printf "{}" | bin/fm-claude-watch-guard.sh > state/owner.out 2>&1 &
      else
        line=$(bin/fm-supervision-instructions.sh --harness claude --repair-line)
        repair=${line#*watcher with }
        repair=${repair%% as its own*}
        bash -c "$repair" > state/owner.out 2>&1 &
      fi
      owner=$!
      checks_progressed() { [ -f state/checks ] && [ "$(wc -l < state/checks)" -ge 2 ]; }
      rc=0
      wait_until_deadline 30 checks_progressed || rc=1
      grep -qF "check: pending fixture wake" state/.wake-queue || rc=1
      if [ "$rc" -eq 0 ]; then
        bin/fm-claude-stop-autoarm.sh > state/stop.out 2> state/stop.err <<EOF_PAYLOAD &
{}
EOF_PAYLOAD
        stop=$!
        stop_finished() { ! kill -0 "$stop" 2>/dev/null; }
        if wait_until_deadline 60 stop_finished; then
          wait "$stop"; stop_rc=$?
          [ "$stop_rc" -eq 2 ] || rc=1
          grep -q "rearm-resurface" state/stop.err || rc=1
          grep -qF "check: pending fixture wake" state/.wake-queue || rc=1
        else
          kill "$stop" 2>/dev/null || true
          wait "$stop" 2>/dev/null || true
          rc=1
        fi
      fi
      if [ "$rc" -ne 0 ]; then
        for record in state/owner.out state/stop.out state/stop.err state/checks state/.wake-queue state/.watcher-down state/.claude-watch-guard.*; do
          [ ! -f "$record" ] || cat "$record"
        done
      fi
      touch state/.afk
      kill "$owner" 2>/dev/null || true
      wait "$owner" 2>/dev/null || true
      bin/fm-watch-arm.sh --stop >/dev/null 2>&1
      [ "$rc" -eq 0 ] || { cat state/owner.out; exit 1; }
    ' || fail "$mode starved checks or consumed the pending wake"
  done
  pass "automatic continuation and emitted repair keep checks running; later Stop delivers pending wakes"
}

test_scope() {
  local home="$TMP_ROOT/scope" harness payload
  make_guard_home "$home"
  touch -t 200001010000 "$home/state/.last-watcher-beat"
  for payload in '{"cursor_version":"fixture"}' '{"transcript_path":"/tmp/.pi/session.json"}'; do
    printf '%s' "$payload" | FM_HOME="$home" "$FAKE_CLAUDE" -c '
      echo "$$" > "$FM_HOME/state/.lock"
      "$FM_HOME/bin/fm-claude-watch-guard.sh" --check
      "$FM_HOME/bin/fm-claude-watch-guard.sh" <<EOF_PAYLOAD
{"cursor_version":"fixture"}
EOF_PAYLOAD
    ' || fail "foreign payload was not inert"
  done
  for harness in codex grok pi pi-signed omp opencode agy; do
    ln -s "$(command -v bash)" "$FAKEBIN/$harness"
    printf '{"tool_input":{"command":"bin/fm-spawn.sh x"}}' |
      FM_HOME="$home" "$FAKEBIN/$harness" -c '
        echo "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-watch-guard.sh" --check
      ' || fail "$harness primary was not inert"
  done
  touch "$home/state/.afk"
  run_check "$home" 'bin/fm-send.sh x y' || fail "daemon posture changed"
  rm "$home/state/.afk"
  # A non-primary root must remain inert; the shared primary-scope suite
  # separately covers linked task copies.
  printf '{"tool_input":{"command":"bin/fm-spawn.sh x"}}' |
    FM_HOME="$home" FM_ROOT_OVERRIDE="$TMP_ROOT/non-primary" "$FAKE_CLAUDE" -c '
      echo "$$" > "$FM_HOME/state/.lock"
      "$FM_HOME/bin/fm-claude-watch-guard.sh" --check
    ' || fail "worker copy was not inert"
  pass "foreign primary harnesses, compatibility payloads, daemon posture and non-primary roots stay inert"
}

test_single_owner_and_session_end() {
  local home="$TMP_ROOT/single"
  make_guard_home "$home"
  cat > "$home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arms"
trap 'exit 0' TERM
while :; do sleep 0.05; done
SH
  chmod +x "$home/bin/fm-watch-arm.sh"
  FM_HOME="$home" FM_TEST_CLAUDE_WATCH_INTERVAL=0.01 "$FAKE_CLAUDE" -c '
    echo "$$" > "$FM_HOME/state/.lock"
    "$FM_HOME/bin/fm-claude-watch-guard.sh" <<EOF_PAYLOAD &
{}
EOF_PAYLOAD
    owner=$!
    for ((i=0;i<100;i++)); do [ -s "$FM_HOME/state/arms" ] && break; sleep 0.05; done
    "$FM_HOME/bin/fm-claude-watch-guard.sh" <<EOF_PAYLOAD
{}
EOF_PAYLOAD
    [ "$(wc -l < "$FM_HOME/state/arms")" -eq 1 ] || exit 1
    echo 9999999 > "$FM_HOME/state/.lock"
    wait "$owner"
    [ ! -e "$FM_HOME/state/.claude-watch-guard.lock" ] || exit 1
    arm=$(cat "$FM_HOME/state/arms")
    ! kill -0 "$arm" 2>/dev/null
  ' || fail "duplicate hook or session-end cleanup failed"
  pass "one guard and arm survive duplicate hooks; loss of session ownership reaps both"
}

test_stop_cooperation() {
  local home="$TMP_ROOT/stop-peer"
  make_guard_home "$home"
  : > "$home/config/supervision-host-off"
  rm "$home/state/task.meta"
  touch "$home/state/.last-check"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/state/x-watch.check.sh"
  chmod 700 "$home/state/x-watch.check.sh"
  FM_HOME="$home" bash "$home/bin/fm-check-register.sh" x-watch >/dev/null || fail "check fixture registration"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TEST_CLAUDE_WATCH_INTERVAL=0.05 "$FAKE_CLAUDE" -c '
    retain_failure() {
      local dest record
      # CI logs retain the evidence even without a private artifact directory.
      for record in "$FM_HOME/state/stop.stdout" "$FM_HOME/state/stop.stderr" \
        "$FM_HOME/state"/.claude-autoarm-output.* "$FM_HOME/state"/.claude-autoarm-successor.* \
        "$FM_HOME/state"/.claude-watch-guard.* "$FM_HOME/state/.watch-cycle-exits.log" \
        "$FM_HOME/state/.watch-deliveries.log" "$FM_HOME/state/.wake-queue"; do
        [ -f "$record" ] || continue
        printf "diagnostic: %s\n" "$record" >&2
        cat "$record" >&2
      done
      [ -n "${FM_WATCH_GUARD_DIAGNOSTICS:-}" ] || return 0
      mkdir -p "$FM_WATCH_GUARD_DIAGNOSTICS"
      dest=$(mktemp -d "$FM_WATCH_GUARD_DIAGNOSTICS/stop-coexistence.XXXXXX") || return 0
      cp -a "$FM_HOME/state" "$dest/state"
      date -u > "$dest/capture-time.txt"
      ps -eo pid,ppid,pgid,stat,args | awk -v home="$FM_HOME" "index(\$0, home)" > "$dest/processes.txt"
      for record in .watch.lock/pid .watch.lock/pid-identity .last-watcher-beat; do
        stat "$FM_HOME/state/$record" >> "$dest/lock-and-beacon.txt" 2>&1 || true
      done
      printf "fixture=%s\nguard=%s\nstop=%s\n" "$FM_HOME" "${guard:-}" "${stop:-}" > "$dest/owners.txt"
      printf "retained diagnostics: %s\n" "$dest" >&2
    }
    trap "rc=\$?; [ \"\$rc\" -eq 0 ] || retain_failure" EXIT
    echo "$$" > "$FM_HOME/state/.lock"
    "$FM_HOME/bin/fm-claude-watch-guard.sh" <<EOF_PAYLOAD &
{}
EOF_PAYLOAD
    guard=$!
    for ((i=0;i<200;i++)); do [ -e "$FM_HOME/state/.last-watcher-beat" ] && break; sleep 0.05; done
    first=$(cat "$FM_HOME/state/.watch.lock/pid") || exit 1
    "$FM_HOME/bin/fm-claude-watch-guard.sh" <<EOF_PAYLOAD
{}
EOF_PAYLOAD
    [ "$(cat "$FM_HOME/state/.watch.lock/pid")" = "$first" ] || exit 1
    "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$FM_HOME/state/stop.stdout" 2> "$FM_HOME/state/stop.stderr" <<EOF_PAYLOAD &
{}
EOF_PAYLOAD
    stop=$!
    sleep 1
    [ "$(cat "$FM_HOME/state/.watch.lock/pid")" = "$first" ] || exit 1
    printf "done: fixture actionable event\n" > "$FM_HOME/state/task.status"
    stop_finished() { ! kill -0 "$stop" 2>/dev/null; }
    # Stop first waits for an attached successor, then confirms its own arm.
    # CONTRIBUTING.md gives these sequential hand-backs a 60-second budget.
    if ! wait_until_deadline 60 stop_finished; then retain_failure; kill "$stop"; exit 1; fi
    wait "$stop"; rc=$?
    [ "$rc" -eq 2 ] || { cat "$FM_HOME/state/stop.stderr"; exit 1; }
    grep -q "signal:" "$FM_HOME/state/stop.stderr" || exit 1
    touch "$FM_HOME/state/.afk"
    wait "$guard"
    "$FM_HOME/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1
  ' || fail "Stop hook did not share and deliver the guard-owned real watcher cycle"
  pass "real Stop hook shares a healthy guard cycle and still delivers exit-2 wake"
}

fm_test_run test_stale_refusal_and_recovery test_twenty_minute_turn test_command_positions test_pending_wake_keeps_checks_running test_scope test_single_owner_and_session_end test_stop_cooperation
