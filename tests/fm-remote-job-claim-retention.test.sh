#!/usr/bin/env bash
# The claim sweep must preserve the former numeric-name eligibility rules.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-claim-retention)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/state"
. "$ROOT/bin/fm-remote-job-lib.sh"
touch() {
  case "$1" in -d) printf 'touch: illegal option -- d\n' >&2; return 1 ;; esac
  command touch "$@"
}
mkdir -p "$TMP_ROOT/account"
fm_remote_job_prepare_state "$TMP_ROOT/account" || fail "$FM_REMOTE_JOB_ERROR"
for name in 0 notes 1x .private 1 00 01; do
  mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/$name"
  fm_touch_epoch 946684800 "$FM_REMOTE_JOB_SEQ_CLAIMS/$name"
done
mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/2"
# Pin the sweep clock so claims can sit on either side of the whole-second
# cutoff without racing a real second boundary.
NOW=$(command date +%s)
date() {
  if [ "$*" = '+%s' ]; then printf '%s\n' "$NOW"; else command date "$@"; fi
}
touch_frac() { # <epoch> <fraction> <path>
  python3 - "$@" <<'PY'
import os, sys

stamp = int(sys.argv[1]) * 1_000_000_000 + int(sys.argv[2].ljust(9, '0'))
os.utime(sys.argv[3], ns=(stamp, stamp))
PY
  [ "$?" -eq 0 ] || fail 'touch_frac: nanosecond timestamp creation failed'
}
CUTOFF=$((NOW - FM_REMOTE_JOB_SEQ_CLAIM_REAP_SECONDS))
for spec in 3:$CUTOFF:0 4:$CUTOFF:5 5:$((CUTOFF + 1)):0 6:$((CUTOFF + 1)):5 7:$CUTOFF:999999999 8:$((CUTOFF + 1)):000000001; do
  IFS=: read -r name epoch frac <<< "$spec"
  mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/$name"
  touch_frac "$epoch" "$frac" "$FM_REMOTE_JOB_SEQ_CLAIMS/$name"
done
fm_remote_job_reap_stale "$TMP_ROOT/account" || fail "claim sweep failed"
for name in 0 notes 1x .private 2 5 6 8; do
  assert_present "$FM_REMOTE_JOB_SEQ_CLAIMS/$name" "ineligible or fresh claim $name was reaped"
done
for name in 1 00 01 3 4 7; do
  assert_absent "$FM_REMOTE_JOB_SEQ_CLAIMS/$name" "expired eligible claim $name survived"
done
assert_present "$FM_REMOTE_JOB_STATE/.seq-claims-reaped" 'successful sweep did not publish its hourly marker'
mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/9"
touch_frac "$CUTOFF" 0 "$FM_REMOTE_JOB_SEQ_CLAIMS/9"
fm_remote_job_reap_stale "$TMP_ROOT/account" || fail 'rate-limited sweep failed'
assert_present "$FM_REMOTE_JOB_SEQ_CLAIMS/9" 'hourly marker did not throttle another sweep'
pass "claim sweep preserves numeric-name eligibility and whole-second expiry"
