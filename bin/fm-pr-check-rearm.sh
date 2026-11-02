#!/usr/bin/env bash
# Refresh PR poll generations after an update; never execute stored checks.
# Usage: fm-pr-check-rearm.sh
# FM_ROOT_OVERRIDE is the updated code root; FM_HOME and FM_STATE_OVERRIDE
# select exactly one operational home. Current polls are left alone. Older
# polls must authenticate against their own registered bytes before the normal
# fm-pr-check.sh owner republishes the current program and its registration.
# Custom checks are never re-registered. Failed polls are preserved and named
# on one pr-poll-rearm: could-not-rearm line each; failures do not roll back an
# update. The final per-home line counts rearmed generations and unresolved
# polls (left); already-current polls and superseded-or-retired skips count in
# neither total. Per-poll failures do not make the command exit nonzero, so
# callers must read left and the named reasons, not just its exit status.
# An unavailable state directory instead reports left=unknown and exits 1.
# When a watch is no longer needed, fm-pr-poll-retire.sh owns explicit retirement.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
  echo 'usage: fm-pr-check-rearm.sh'
  exit 0
fi
[ "$#" -eq 0 ] || { echo 'usage: fm-pr-check-rearm.sh' >&2; exit 2; }

[ -n "$STATE" ] && [ -d "$STATE" ] && [ ! -L "$STATE" ] \
  || { printf 'pr-poll-rearm: home=%s left=unknown reason=state-directory-unavailable\n' "$FM_HOME"; exit 1; }
rearmed=0
left=0
for check in "$STATE"/*.check.sh; do
  [ -e "$check" ] || [ -L "$check" ] || continue
  id=${check##*/}; id=${id%.check.sh}
  [ -e "$STATE/$id.pr-poll" ] || [ -L "$STATE/$id.pr-poll" ] \
    || [ -e "$STATE/$id.pr-poll-registration" ] || [ -L "$STATE/$id.pr-poll-registration" ] || continue
  fm_pr_poll_artifacts_valid "$STATE" "$id" "$FM_ROOT/bin/fm-pr-poll.sh" && continue
  reason=unauthenticated-poll-generation
  if [ ! -e "$STATE/$id.check-trust" ] && [ ! -L "$STATE/$id.check-trust" ] \
    && fm_pr_poll_snapshot_capture "$STATE" "$id" "$check"; then
    url=$FM_PR_POLL_SNAPSHOT_URL
    generation="$FM_PR_POLL_SNAPSHOT_REG_IDENTITY:$FM_PR_POLL_SNAPSHOT_REG_HASH"
    if out=$(env FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
      FM_PR_CHECK_REARM_GENERATION="$generation" \
      FM_CONFIG_OVERRIDE="$FM_HOME/config" bash "$FM_ROOT/bin/fm-pr-check.sh" "$id" "$url" 2>&1); then
      if fm_pr_poll_artifacts_valid "$STATE" "$id" "$FM_ROOT/bin/fm-pr-poll.sh"; then
        rearmed=$((rearmed + 1))
        continue
      fi
      reason=post-rearm-validation-failed
    else
      rc=$?
      if [ "$rc" -eq 3 ]; then
        printf 'pr-poll-rearm: home=%s task=%s skipped=superseded-or-retired\n' "$FM_HOME" "$id"
        continue
      fi
      reason=${out//$'\n'/ }
      reason=${reason//$'\r'/ }
      [ -n "$reason" ] || reason="record-owner-failed"
    fi
  fi
  left=$((left + 1))
  printf 'pr-poll-rearm: home=%s task=%s could-not-rearm reason=%s\n' "$FM_HOME" "$id" "$reason"
done
printf 'pr-poll-rearm: home=%s rearmed=%s left=%s\n' "$FM_HOME" "$rearmed" "$left"
