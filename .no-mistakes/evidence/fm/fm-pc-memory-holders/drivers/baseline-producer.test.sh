#!/usr/bin/env bash
set -u
. "$CHILD_LIB"
if [ "$CHILD_CLEANUP" = disabled ]; then
  fm_test_reap_processes() { return 0; }
fi
root=$(fm_test_tmproot fm-test-child-producer)
mkdir -p "$root"
bash "$CHILD_HOLDER" "$root" "$CHILD_RECEIPT.release" </dev/null >/dev/null 2>&1 &
pid=$!
printf '%s\n%s\n' "$pid" "$root" > "$CHILD_RECEIPT"
# The original helper has no ordinary-child registration interface.
if declare -F fm_test_track_process >/dev/null; then
  fm_test_track_process "$pid" "$root" || fail 'owned child registration failed'
  cp "$FM_TEST_PROCESS_REGISTRY" "$CHILD_RECEIPT.provenance"
fi
if [ "$CHILD_OUTCOME" = failure ]; then fail 'original assertion failure'; fi
