#!/usr/bin/env bash
# usage: drive.sh <repo-root-with-bin> <label>
set -u
R=$1; L=$2
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
"$PWD/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME=$LAB
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE
ST=$LAB/state
say(){ printf '\n=== [%s] %s\n' "$L" "$*"; }
run_bounded(){ # timeout-secs cmd...
  local t=$1; shift; local s e rc
  s=$(date +%s.%N); timeout "$t" "$@" >"$LAB/out" 2>"$LAB/err"; rc=$?; e=$(date +%s.%N)
  printf 'rc=%s elapsed=%.2fs\n' "$rc" "$(echo "$e - $s" | bc)"
  sed 's/^/  stdout: /' "$LAB/out"; sed 's/^/  stderr: /' "$LAB/err"
}
LOCK=$ST/.remote-reply-lifecycle-mate1.lock

say "S1 incident repro: holder dies leaving lock; its pid record now names an unrelated live process (reused pid)"
bash -c '. "$1"; fm_lock_try_acquire "$2"' _ "$R/bin/fm-wake-lib.sh" "$LOCK"
OWNER=$(readlink "$LOCK" 2>/dev/null || echo "$LOCK")
echo "owner files: $(ls "$OWNER" | tr '\n' ' ')"
sleep 300 & REUSED=$!
echo "$REUSED" > "$OWNER/pid"
echo "recorded identity: $(cat "$OWNER/identity" 2>/dev/null || echo none)"
echo "unrelated pid $REUSED identity: $(bash -c '. "$1"; fm_pid_identity "$2"' _ "$R/bin/fm-wake-lib.sh" "$REUSED")"
echo "running: fm-procevent-remote-reply.sh arm mate1 (outer 20s watchdog)"
run_bounded 20 "$R/bin/fm-procevent-remote-reply.sh" arm mate1
echo "lock after: pid=$(cat "$LOCK/pid" 2>/dev/null || echo '<released>')"
kill -0 $REUSED 2>/dev/null && echo "unrelated process $REUSED still alive (untouched)"
kill $REUSED; wait $REUSED 2>/dev/null
rm -rf "$LOCK" "$LOCK".owner.* 2>/dev/null

say "S2 live holder with matching identity blocks; bounded wait (FM_REMOTE_REPLY_LIFECYCLE_LOCK_WAIT=2) refuses arm/handle/retire naming holder"
bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 7; : > "$3"; sleep 300 & wait' _ "$R/bin/fm-wake-lib.sh" "$LOCK" "$LAB/held" & H=$!
for i in $(seq 50); do [ -e "$LAB/held" ] && break; sleep 0.1; done
echo "holder pid $H identity: $(cat "$LOCK/identity" 2>/dev/null || echo none)"
for c in "arm mate1" "handle mate1 1 /nonexistent" "retire mate1"; do
  echo "--- $c"; FM_REMOTE_REPLY_LIFECYCLE_LOCK_WAIT=2 run_bounded 20 "$R/bin/fm-procevent-remote-reply.sh" $c
done
echo "lock still held by: $(cat "$LOCK/pid")"

say "S3 remote teardown lifecycle wait bounded against the live holder"
cat > "$ST/mate1.meta" <<M
kind=secondmate
remote_host=lab-unreachable.invalid
remote_home=/nonexistent
M
FM_REMOTE_REPLY_LIFECYCLE_LOCK_WAIT=2 run_bounded 30 "$R/bin/fm-teardown.sh" mate1
echo "lock still held by: $(cat "$LOCK/pid")"
kill $H; wait $H 2>/dev/null
rm -rf "$LOCK" "$LOCK".owner.* "$LAB/held" 2>/dev/null

say "S4 legacy lock (pid only, no identity) with live pid still blocks; bounded refusal"
sleep 300 & LIVE=$!
mkdir "$LOCK"; echo $LIVE > "$LOCK/pid"
FM_REMOTE_REPLY_LIFECYCLE_LOCK_WAIT=2 run_bounded 20 "$R/bin/fm-procevent-remote-reply.sh" arm mate1
echo "lock still pid=$(cat "$LOCK/pid")"
kill $LIVE; wait $LIVE 2>/dev/null; rm -rf "$LOCK"

say "S5 holder that execs after acquiring stays live"
bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 7; : > "$3"; exec sleep 300' _ "$R/bin/fm-wake-lib.sh" "$LOCK" "$LAB/held" & H=$!
for i in $(seq 50); do [ "$(ps -p $H -o comm=)" = sleep ] && break; sleep 0.1; done
echo "holder $H now comm=$(ps -p $H -o comm=)"
FM_REMOTE_REPLY_LIFECYCLE_LOCK_WAIT=2 run_bounded 20 "$R/bin/fm-procevent-remote-reply.sh" arm mate1
kill $H; wait $H 2>/dev/null
rm -rf "$LAB"
