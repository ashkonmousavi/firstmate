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
sleep 90 & client3=$!
cleanup_clients() {
  kill "$client1" "$client2" "$daemon" "$client3" 2>/dev/null || true
  wait "$client1" "$client2" "$daemon" "$client3" 2>/dev/null || true
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
  "$TEST_CODEX_CLIENT3":comm=) echo node-MainThread ;;
  "$TEST_CODEX_CLIENT3":args=) echo 'node /opt/node/lib/node_modules/@openai/codex/bin/codex.js --yolo' ;;
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
birth3=$(fm_codex_pid_birth "$client3") || fail 'could not read node-launched client birth'
export TEST_CODEX_CLIENT1="$client1" TEST_CODEX_CLIENT2="$client2" TEST_CODEX_DAEMON="$daemon" TEST_CODEX_CLIENT3="$client3"

run_lock() {  # <session> <client-pid> <birth> [<home>]
  local lock_home=${4:-$home}
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    PATH="$fakebin:$PATH" FM_HOME="$lock_home" CODEX_SESSION_ID="$1" \
    FM_CODEX_CLIENT_PID="$2" FM_CODEX_CLIENT_BIRTH="$3" FM_CODEX_CLIENT_HOME="$lock_home" \
    "$ROOT/bin/fm-lock.sh"
}

# The npm CLI is a node script, so the launcher's exec leaves the bound pid
# running as node rather than as the native codex binary.
node_home="$TMP_ROOT/node-home"
mkdir -p "$node_home/state"
out=$(run_lock S3 "$client3" "$birth3" "$node_home") || fail "a node-launched Codex client could not acquire: $out"
[ "$(cat "$node_home/state/.lock")" = "$client3" ] || fail 'the lock did not anchor on the node-launched client'
[ "$(cat "$node_home/state/.lock-session")" = "codex:$client3:$birth3:S3" ] \
  || fail 'the node-launched client did not bind its session sidecar'
pass 'Codex lock: a client launched through the node CLI script owns its lock'

# An older release anchored the lock on the shared daemon with no sidecar.
legacy_home="$TMP_ROOT/legacy-home"
mkdir -p "$legacy_home/state"
printf '%s\n' "$daemon" > "$legacy_home/state/.lock"
status_out=$(PATH="$fakebin:$PATH" FM_HOME="$legacy_home" "$ROOT/bin/fm-lock.sh" status)
assert_not_contains "$status_out" 'held by live harness' 'the shared daemon was reported as a live lock holder'
out=$(run_lock S3 "$client3" "$birth3" "$legacy_home") || fail "a daemon-anchored lock was not reclaimable: $out"
[ "$(cat "$legacy_home/state/.lock")" = "$client3" ] || fail 'the reclaimed lock did not name the live client'
pass 'Codex lock: a lock anchored on the shared daemon is reclaimed by a live client'

if out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_CODEX_CLIENT_PID -u FM_CODEX_CLIENT_BIRTH -u FM_CODEX_CLIENT_HOME \
  PATH="$fakebin:$PATH" FM_HOME="$TMP_ROOT/unbound-home" \
  CODEX_SESSION_ID=S4 "$ROOT/bin/fm-lock.sh" 2>&1); then
  fail "a Codex tool command without a client binding acquired the lock: $out"
fi
assert_contains "$out" 'bin/fm-codex-primary.sh' 'an unbound Codex primary was not told how to relaunch'
pass 'Codex lock: an unbound daemon tool command names the launcher remedy'

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
