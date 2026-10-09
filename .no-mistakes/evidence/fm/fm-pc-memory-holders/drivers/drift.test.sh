#!/usr/bin/env bash
set -u
. "$GATE_LIB"
root=$(fm_test_tmproot fm-test-live-cwd-drift)
printf '%s\n' "$root" > "$GATE_RECEIPT.root"
bash -c '
  cd "$1" || exit 1
  limit=$((SECONDS + 300))
  while [ ! -e "$3.move" ] && [ "$SECONDS" -lt "$limit" ]; do sleep 0.1; done
  cd "$2" || exit 1
  : > "$3.moved"
  while [ ! -e "$3.release" ] && [ "$SECONDS" -lt "$limit" ]; do sleep 0.1; done
  [ "$SECONDS" -lt "$limit" ] || : > "$3.expired"
' _ "$root" "$GATE_EXTERNAL" "$GATE_RECEIPT" </dev/null >/dev/null 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$GATE_RECEIPT.pid"
fm_test_track_process "$pid" "$root" || fail 'could not register drift subject'
cp "$FM_TEST_PROCESS_REGISTRY" "$GATE_RECEIPT.provenance"
: > "$GATE_RECEIPT.move"
tries=0
while [ ! -e "$GATE_RECEIPT.moved" ] && [ "$tries" -lt 600 ]; do sleep 0.1; tries=$((tries + 1)); done
[ -e "$GATE_RECEIPT.moved" ] || fail 'live child never changed cwd'
