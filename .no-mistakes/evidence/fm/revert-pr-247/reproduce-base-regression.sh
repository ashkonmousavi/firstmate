#!/usr/bin/env bash
set -euo pipefail
BASE_SNAPSHOT=$(mktemp -d "$PWD/.revert-baseline.XXXXXX")
trap 'rm -rf "$BASE_SNAPSHOT"' EXIT
git archive 4e4a338f1167b55826b81414070402bea7b9b34f bin tests | tar -x -C "$BASE_SNAPSHOT"
set +e
FM_AUTOLAUNCH_EGM1R2_ONLY=test_egm1r2_malformed_ready_is_not_a_successful_read bash "$BASE_SNAPSHOT/tests/fm-autolaunch.test.sh" > ~/.no-mistakes/evidence/01M6QG4GJ98YRTXTMHF63ZZK56/base-count-mismatch.log 2>&1
rc=$?
set -e
cat ~/.no-mistakes/evidence/01M6QG4GJ98YRTXTMHF63ZZK56/base-count-mismatch.log
printf '\nBase reproduction exit: %s (expected failure)\n' "$rc"
test "$rc" -ne 0
rg -F 'EGM1-R2 ready count-mismatch: malformed ready output was recorded as tasks status ok' ~/.no-mistakes/evidence/01M6QG4GJ98YRTXTMHF63ZZK56/base-count-mismatch.log
