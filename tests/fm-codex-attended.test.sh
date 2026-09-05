#!/usr/bin/env bash
# Focused units for the Codex attended-delivery branch of the existing
# supervision daemon. The durable wake queue stays authoritative: this path
# rings the current Codex thread only and never drains or interprets records.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-attended.XXXXXX")
FAILED=0

cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

# Source only the daemon's functions. Its library-mode notifier guard prevents
# a sourced test from posting any real desktop notification.
# shellcheck source=bin/fm-supervise-daemon.sh
. "$DAEMON"

install_fake_codex() { # <dir>
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/codex" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" >> "$FM_FAKE_CODEX_LOG"
[ ! -e "${FM_FAKE_CODEX_FAIL:-/nonexistent}" ]
SH
  chmod +x "$dir/bin/codex"
}

install_fake_tmux() { # <dir>
  local dir=$1
  cat > "$dir/bin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf 'fakepane\n'; exit 0 ;;
  list-windows|list-panes) exit 0 ;;
  capture-pane) exit 0 ;;
esac
exit 1
SH
  chmod +x "$dir/bin/tmux"
}

start_attended_daemon() { # <dir> <thread>
  local dir=$1 thread=$2 state="$1/state"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fakepane \
    FM_CODEX_ATTENDED_THREAD="$thread" FM_FAKE_CODEX_LOG="$dir/codex.log" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HOUSEKEEPING_TICK=3600 \
    PATH="$dir/bin:$PATH" "$DAEMON" >"$dir/daemon.out" 2>"$dir/daemon.err" &
  FM_TEST_DAEMON_PID=$!
}

wait_for_line_count() { # <file> <pattern> <count>
  local file=$1 pattern=$2 want=$3 _ got
  for _ in $(seq 1 100); do
    got=$(grep -c "$pattern" "$file" 2>/dev/null || true)
    got=${got:-0}
    [ "$got" -ge "$want" ] && return 0
    sleep 0.05
  done
  return 1
}

test_empty_wait_is_silent() {
  local dir state log
  dir="$TMP_ROOT/empty"; state="$dir/state"; log="$dir/codex.log"
  mkdir -p "$state"; install_fake_codex "$dir"
  FM_CODEX_DOORBELL_OUTSTANDING=0
  PATH="$dir/bin:$PATH" FM_FAKE_CODEX_LOG="$log" \
    attended_codex_maybe_notify "$state" 11111111-1111-1111-1111-111111111111
  if [ ! -e "$log" ]; then
    pass "attended Codex: an empty durable queue is silent"
  else
    fail "attended Codex: an empty queue invoked codex"
  fi
}

test_action_rings_once_without_acknowledging_business_state() {
  local dir state log before_queue
  dir="$TMP_ROOT/action"; state="$dir/state"; log="$dir/codex.log"
  mkdir -p "$state/procevent" "$state/decision-bindings"; install_fake_codex "$dir"
  printf '1\t7\tcheck\tpr:42\tcheck: merge result ready\n' > "$state/.wake-queue"
  printf 'unmerged\n' > "$state/task.pr-poll"
  printf 'needs-decision: [key=ship] choose release\n' > "$state/task.status"
  printf 'source\n' > "$state/decision-bindings/ship"
  before_queue=$(cat "$state/.wake-queue")

  FM_CODEX_DOORBELL_OUTSTANDING=0
  PATH="$dir/bin:$PATH" FM_FAKE_CODEX_LOG="$log" \
    attended_codex_maybe_notify "$state" 22222222-2222-2222-2222-222222222222 \
    || fail "attended Codex: actionable doorbell failed"
  PATH="$dir/bin:$PATH" FM_FAKE_CODEX_LOG="$log" \
    attended_codex_maybe_notify "$state" 22222222-2222-2222-2222-222222222222 \
    || fail "attended Codex: duplicate-suppression call failed"

  if [ "$(grep -c '^queue$' "$log" 2>/dev/null || true)" -eq 1 ] \
    && grep -Fx -- '--thread' "$log" >/dev/null \
    && grep -Fx '22222222-2222-2222-2222-222222222222' "$log" >/dev/null \
    && grep -F "FIRSTMATE_OP: v1 watcher:" "$log" >/dev/null; then
    pass "attended Codex: pending work rings the captured thread once"
  else
    fail "attended Codex: doorbell command or duplicate suppression was wrong ($(tr '\n' '|' < "$log" 2>/dev/null))"
  fi

  if [ "$(cat "$state/.wake-queue")" = "$before_queue" ] \
    && [ "$(cat "$state/task.pr-poll")" = unmerged ] \
    && grep -Fx 'needs-decision: [key=ship] choose release' "$state/task.status" >/dev/null \
    && [ "$(cat "$state/decision-bindings/ship")" = source ]; then
    pass "attended Codex: doorbell receipt does not acknowledge queue, task, decision, or PR state"
  else
    fail "attended Codex: notification mutated durable business state"
  fi
}

test_acknowledged_queue_rearms_and_failed_delivery_retries() {
  local dir state log fail_flag
  dir="$TMP_ROOT/rearm"; state="$dir/state"; log="$dir/codex.log"; fail_flag="$dir/fail"
  mkdir -p "$state"; install_fake_codex "$dir"
  printf '1\t8\tsignal\ttask.status\tsignal: task.status\n' > "$state/.wake-queue"
  : > "$fail_flag"
  FM_CODEX_DOORBELL_OUTSTANDING=0

  if PATH="$dir/bin:$PATH" FM_FAKE_CODEX_LOG="$log" FM_FAKE_CODEX_FAIL="$fail_flag" \
      attended_codex_maybe_notify "$state" 33333333-3333-3333-3333-333333333333; then
    fail "attended Codex: failed queue delivery reported success"
  fi
  rm -f "$fail_flag"
  PATH="$dir/bin:$PATH" FM_FAKE_CODEX_LOG="$log" \
    attended_codex_maybe_notify "$state" 33333333-3333-3333-3333-333333333333 \
    || fail "attended Codex: retry after failed delivery did not succeed"

  : > "$state/.wake-queue"
  PATH="$dir/bin:$PATH" FM_FAKE_CODEX_LOG="$log" \
    attended_codex_maybe_notify "$state" 33333333-3333-3333-3333-333333333333
  printf '2\t9\tcheck\tprocess\tcheck: process result\n' > "$state/.wake-queue"
  PATH="$dir/bin:$PATH" FM_FAKE_CODEX_LOG="$log" \
    attended_codex_maybe_notify "$state" 33333333-3333-3333-3333-333333333333

  if [ "$(grep -c '^queue$' "$log" 2>/dev/null || true)" -eq 3 ]; then
    pass "attended Codex: failed delivery retries and an acknowledged queue rearms"
  else
    fail "attended Codex: retry/rearm issued the wrong number of doorbells"
  fi
}

test_executed_daemon_is_single_owner_and_recovers_pending_queue() {
  local dir state thread first_pid second_status second_out role
  dir="$TMP_ROOT/daemon"; state="$dir/state"; thread=44444444-4444-4444-4444-444444444444
  mkdir -p "$state"; install_fake_codex "$dir"; install_fake_tmux "$dir"
  printf '1\t10\tcheck\twork\tcheck: action required\n' > "$state/.wake-queue"

  start_attended_daemon "$dir" "$thread"; first_pid=$FM_TEST_DAEMON_PID
  if ! wait_for_line_count "$dir/codex.log" '^queue$' 1; then
    fail "attended Codex daemon: startup did not ring for the recovered durable row"
  fi
  role=$(cat "$state/.supervise-daemon.lock/role" 2>/dev/null || true)
  if [ "$role" = "codex-attended:$thread" ]; then
    pass "attended Codex daemon: live lock identifies the current-thread owner"
  else
    fail "attended Codex daemon: live lock omitted attended ownership ($role)"
  fi

  second_out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fakepane \
    FM_CODEX_ATTENDED_THREAD="$thread" FM_FAKE_CODEX_LOG="$dir/codex.log" \
    PATH="$dir/bin:$PATH" "$DAEMON" 2>&1)
  second_status=$?
  if [ "$second_status" -ne 0 ] \
    && printf '%s\n' "$second_out" | grep -F 'another fm-supervise-daemon is already running' >/dev/null \
    && kill -0 "$first_pid" 2>/dev/null; then
    pass "attended Codex daemon: concurrent start leaves exactly one owner"
  else
    fail "attended Codex daemon: concurrent owner was not refused ($second_status: $second_out)"
  fi

  kill -TERM "$first_pid" 2>/dev/null || true
  wait "$first_pid" 2>/dev/null || true
  start_attended_daemon "$dir" "$thread"; first_pid=$FM_TEST_DAEMON_PID
  if wait_for_line_count "$dir/codex.log" '^queue$' 2 \
    && [ -s "$state/.wake-queue" ]; then
    pass "attended Codex daemon: restart re-rings only because the durable row remains unacknowledged"
  else
    fail "attended Codex daemon: restart did not recover the pending durable row"
  fi
  kill -TERM "$first_pid" 2>/dev/null || true
  wait "$first_pid" 2>/dev/null || true
}

test_launcher_starts_existing_owner_without_away_mode() {
  local dir state out
  dir="$TMP_ROOT/launcher-start"; state="$dir/state"; mkdir -p "$state"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    CODEX_THREAD_ID=55555555-5555-5555-5555-555555555555 bash -c '
      . "$1"
      discover_supervisor_target() { printf "lab:captain\n"; }
      discover_supervisor_backend() { printf "herdr\n"; }
      daemon_lock_held_by_live_daemon() { return 1; }
      fm_afk_launch_create_herdr() {
        printf "create=%s/%s\nthread=%s\nentry=%s\n" "$1" "$2" \
          "${FM_CODEX_ATTENDED_THREAD:-}" "$(fm_afk_launch_entry_cmd)"
      }
      fm_afk_launch_start_codex
      [ ! -e "$FM_AFK_LAUNCH_STATE/.afk" ] && printf "afk=off\n"
    ' _ "$LAUNCH" 2>&1)
  if printf '%s\n' "$out" | grep -Fx 'create=lab:captain/herdr' >/dev/null \
    && printf '%s\n' "$out" | grep -Fx 'thread=55555555-5555-5555-5555-555555555555' >/dev/null \
    && printf '%s\n' "$out" | grep -Fx "entry=$DAEMON" >/dev/null \
    && printf '%s\n' "$out" | grep -Fx 'afk=off' >/dev/null; then
    pass "attended Codex launcher: reuses the hidden daemon owner without entering away mode"
  else
    fail "attended Codex launcher: wrong owner entry or away-mode mutation ($out)"
  fi
}

test_launcher_repeated_start_and_away_mode_do_not_duplicate() {
  local dir state out
  dir="$TMP_ROOT/launcher-repeat"; state="$dir/state"; mkdir -p "$state/.supervise-daemon.lock"
  printf 'codex-attended:%s\n' 66666666-6666-6666-6666-666666666666 > "$state/.supervise-daemon.lock/role"
  printf 'none\t-\tnative\n' > "$state/.afk-daemon-terminal"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    CODEX_THREAD_ID=66666666-6666-6666-6666-666666666666 bash -c '
      . "$1"
      discover_supervisor_target() { printf "lab:captain\n"; }
      discover_supervisor_backend() { printf "herdr\n"; }
      daemon_lock_held_by_live_daemon() { return 0; }
      fm_afk_launch_create_herdr() { printf "DUPLICATE\n"; return 1; }
      fm_afk_launch_start_codex
      : > "$FM_AFK_LAUNCH_STATE/.afk"
      fm_afk_launch_start_codex
      printf "stable\n"
    ' _ "$LAUNCH" 2>&1)
  if printf '%s\n' "$out" | grep -Fx stable >/dev/null \
    && ! printf '%s\n' "$out" | grep -F DUPLICATE >/dev/null; then
    pass "attended Codex launcher: repeated starts and away mode preserve one live owner"
  else
    fail "attended Codex launcher: repeated/away start created another owner ($out)"
  fi
}

test_launcher_recovers_exact_dead_terminal_before_restart() {
  local dir state out
  dir="$TMP_ROOT/launcher-recover"; state="$dir/state"; mkdir -p "$state"
  printf 'herdr\tlab:dead-pane\tdead-workspace\n' > "$state/.afk-daemon-terminal"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    CODEX_THREAD_ID=77777777-7777-7777-7777-777777777777 bash -c '
      . "$1"
      discover_supervisor_target() { printf "lab:captain\n"; }
      discover_supervisor_backend() { printf "herdr\n"; }
      daemon_lock_held_by_live_daemon() { return 1; }
      fm_afk_launch_close_recorded() {
        printf "closed=%s\n" "$FM_AFK_REC_TARGET"
        rm -f "$FM_AFK_LAUNCH_RECORD"
      }
      fm_afk_launch_create_herdr() { printf "created=%s\n" "$1"; }
      fm_afk_launch_start_codex
    ' _ "$LAUNCH" 2>&1)
  if printf '%s\n' "$out" | grep -Fx 'closed=lab:dead-pane' >/dev/null \
    && printf '%s\n' "$out" | grep -Fx 'created=lab:captain' >/dev/null; then
    pass "attended Codex launcher: crash recovery closes the exact dead terminal before restart"
  else
    fail "attended Codex launcher: crash recovery did not converge by exact id ($out)"
  fi
}

test_launcher_waits_for_attended_watcher_readiness() {
  local dir state out
  dir="$TMP_ROOT/launcher-ready"; state="$dir/state"; mkdir -p "$state/.supervise-daemon.lock"
  printf 'codex-attended:%s\n' 88888888-8888-8888-8888-888888888888 > "$state/.supervise-daemon.lock/role"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_CODEX_ATTENDED_THREAD=88888888-8888-8888-8888-888888888888 bash -c '
      . "$1"
      daemon_lock_held_by_live_daemon() { return 0; }
      fm_afk_launch_terminal_alive() { return 0; }
      fm_watcher_healthy() {
        n=$(cat "$FM_AFK_LAUNCH_STATE/readiness-calls" 2>/dev/null || echo 0)
        n=$((n + 1)); printf "%s\n" "$n" > "$FM_AFK_LAUNCH_STATE/readiness-calls"
        [ "$n" -ge 2 ]
      }
      fm_afk_launch_wait_ready herdr lab:daemon
      cat "$FM_AFK_LAUNCH_STATE/readiness-calls"
    ' _ "$LAUNCH" 2>&1)
  if [ "$out" = 2 ]; then
    pass "attended Codex launcher: readiness includes the daemon-owned watcher"
  else
    fail "attended Codex launcher: returned before watcher ownership was ready ($out)"
  fi
}

test_empty_wait_is_silent
test_action_rings_once_without_acknowledging_business_state
test_acknowledged_queue_rearms_and_failed_delivery_retries
test_executed_daemon_is_single_owner_and_recovers_pending_queue
test_launcher_starts_existing_owner_without_away_mode
test_launcher_repeated_start_and_away_mode_do_not_duplicate
test_launcher_recovers_exact_dead_terminal_before_restart
test_launcher_waits_for_attended_watcher_readiness

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
