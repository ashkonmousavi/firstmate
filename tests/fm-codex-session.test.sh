#!/usr/bin/env bash
# A shared Codex app-server must never be the lock owner or a handling-gap owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-session)
home="$TMP_ROOT/home"
fakebin="$TMP_ROOT/bin"
mkdir -p "$home/state" "$fakebin"

cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
printf 'pid=%s\n' "$$"
printf 'arg=%s\n' "$@"
SH
chmod +x "$fakebin/codex"
launcher_out=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
  HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SESSION=fmtest HERDR_SOCKET_PATH=/tmp/fmtest.sock \
  "$ROOT/bin/fm-codex-primary.sh" --model gpt-6-sol) || fail 'Codex primary launcher did not reach the CLI'
launcher_pid=$(printf '%s\n' "$launcher_out" | sed -n 's/^pid=//p')
case "$launcher_out" in
  *"arg=shell_environment_policy.set.FM_CODEX_CLIENT_PID=\"$launcher_pid\""*) : ;;
  *) fail 'the CLI did not receive its own foreground client pid' ;;
esac
assert_contains "$launcher_out" 'arg=shell_environment_policy.set.HERDR_PANE_ID="w1:p1"' \
  'the CLI did not receive its launch pane'
assert_contains "$launcher_out" 'arg=shell_environment_policy.set.HERDR_SESSION="fmtest"' \
  'the CLI did not receive its launch session'
assert_contains "$launcher_out" 'arg=shell_environment_policy.set.HERDR_SOCKET_PATH="/tmp/fmtest.sock"' \
  'the CLI did not receive its launch socket'
pass 'Codex launcher: per-thread settings carry the live client and launch terminal'

sleep 90 & client1=$!
sleep 90 & client2=$!
sleep 90 & daemon=$!
cleanup_clients() {
  kill "$client1" "$client2" "$daemon" 2>/dev/null || true
  wait "$client1" "$client2" "$daemon" 2>/dev/null || true
}
trap 'cleanup_clients; fm_test_cleanup' EXIT

# The command shells all descend from one simulated managed daemon. The two
# client pids are real, so the lock's kill -0 and /proc birth checks are real.
cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  "$TEST_CODEX_CLIENT1":comm=|"$TEST_CODEX_CLIENT2":comm=|"$TEST_CODEX_DAEMON":comm=) echo codex ;;
  "$TEST_CODEX_CLIENT1":args=|"$TEST_CODEX_CLIENT2":args=) echo 'codex --remote unix://' ;;
  "$TEST_CODEX_DAEMON":args=) echo 'codex app-server --managed-daemon' ;;
  "$TEST_CODEX_DAEMON":ppid=) echo 1 ;;
  1:comm=) echo init ;;
  1:args=) echo init ;;
  1:ppid=) echo 0 ;;
  *:comm=) echo bash ;;
  *:args=) echo 'bash bin/fm-lock.sh' ;;
  *:ppid=) echo "$TEST_CODEX_DAEMON" ;;
esac
SH
chmod +x "$fakebin/ps"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
birth1=$(fm_codex_pid_birth "$client1") || fail 'could not read first client birth'
birth2=$(fm_codex_pid_birth "$client2") || fail 'could not read second client birth'
export TEST_CODEX_CLIENT1="$client1" TEST_CODEX_CLIENT2="$client2" TEST_CODEX_DAEMON="$daemon"

run_lock() {  # <session> <client-pid> <birth>
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    PATH="$fakebin:$PATH" FM_HOME="$home" CODEX_SESSION_ID="$1" \
    FM_CODEX_CLIENT_PID="$2" FM_CODEX_CLIENT_BIRTH="$3" FM_CODEX_CLIENT_HOME="$home" \
    "$ROOT/bin/fm-lock.sh"
}

out=$(run_lock S1 "$client1" "$birth1") || fail "first client could not acquire: $out"
[ "$(cat "$home/state/.lock")" = "$client1" ] || fail 'lock anchored on the daemon instead of the first client'
[ "$(cat "$home/state/.lock-session")" = "codex:$client1:$birth1:S1" ] || fail 'Codex session sidecar did not bind the client birth'
if out=$(run_lock S2 "$client2" "$birth2" 2>&1); then
  fail "a second session under the same daemon acquired the first session's lock: $out"
fi
if out=$(run_lock S2 "$client1" "$birth1" 2>&1); then
  fail "a different thread sharing the first client acquired its lock: $out"
fi
[ "$(cat "$home/state/.lock")" = "$client1" ] || fail 'the denied second session changed the owner'
run_lock S1 "$client1" "$birth1" >/dev/null || fail 'the first session lost its own lock'
env PATH="$fakebin:$PATH" FM_HOME="$home" CODEX_SESSION_ID=S1 \
  CLAUDE_CODE_SESSION_ID=inherited-claude CLAUDE_PID="$daemon" \
  FM_CODEX_CLIENT_PID="$client1" FM_CODEX_CLIENT_BIRTH="$birth1" FM_CODEX_CLIENT_HOME="$home" \
  "$ROOT/bin/fm-lock.sh" >/dev/null || fail 'inherited Claude markers hid the real Codex owner'
pass 'Codex lock: two sessions under one daemon stay exclusive'

if out=$(run_lock S2 "$client2" wrong-birth 2>&1); then
  fail "an unverified client birth acquired the lock: $out"
fi
kill "$client1"
wait "$client1" 2>/dev/null || true
kill -0 "$daemon" 2>/dev/null || fail 'the simulated managed daemon did not survive the first client'
out=$(run_lock S2 "$client2" "$birth2") || fail "dead client did not release the lock: $out"
[ "$(cat "$home/state/.lock")" = "$client2" ] || fail 'reclaimed lock did not name the second client'
pass 'Codex lock: a dead client releases ownership while the daemon survives'

run_verdict() {  # <grace>
  # shellcheck disable=SC2016 # Positional parameters expand in the child bash.
  env PATH="$fakebin:$PATH" FM_HOME="$home" CODEX_SESSION_ID=S2 \
    FM_CODEX_CLIENT_PID="$client2" FM_CODEX_CLIENT_BIRTH="$birth2" FM_CODEX_CLIENT_HOME="$home" \
    FM_SUPERVISION_MODEL=checkpoint bash -c '
      . "$1/bin/fm-wake-lib.sh"
      fm_watcher_supervision_verdict "$2/state" "$1/bin/fm-watch.sh" "$3" "$2" "$1"
      printf "%s %s\n" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"
    ' _ "$ROOT" "$home" "$1"
}
run_marker() {  # <begin|finish>
  # shellcheck disable=SC2016 # Positional parameters expand in the child bash.
  env PATH="$fakebin:$PATH" FM_HOME="$home" CODEX_SESSION_ID=S2 \
    FM_CODEX_CLIENT_PID="$client2" FM_CODEX_CLIENT_BIRTH="$birth2" FM_CODEX_CLIENT_HOME="$home" \
    bash -c '. "$1/bin/fm-session-lock-lib.sh"; "fm_codex_checkpoint_$2" "$3/state"' _ "$ROOT" "$1" "$home"
}

touch "$home/state/.last-watcher-beat"
[ "$(run_verdict 300)" = 'false no-watcher' ] || fail 'a fresh beacon alone suppressed the alarm'
run_marker finish || fail 'the lock owner could not publish a handling interval'
[ "$(run_verdict 300)" = 'true stale-beacon' ] || fail 'a live session-owned handling interval was not healthy'
[ "$(run_verdict 0)" = 'false stale-beacon' ] || fail 'an expired beacon remained healthy'
run_marker begin || fail 'the next checkpoint could not clear its prior marker'
[ "$(run_verdict 300)" = 'false no-watcher' ] || fail 'a failed next checkpoint inherited the old marker'
run_marker finish || fail 'the owner could not republish its marker'
printf 'codex:%s:%s:OTHER\n' "$client2" "$birth2" > "$home/state/.codex-checkpoint-handling"
[ "$(run_verdict 300)" = 'false no-watcher' ] || fail 'a foreign session marker suppressed the alarm'
pass 'Codex checkpoint: only a fresh, live, session-owned gap is healthy'
