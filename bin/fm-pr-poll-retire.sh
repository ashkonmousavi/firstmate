#!/usr/bin/env bash
# Retire one PR poll without landing or removing any task work.
# Usage: fm-pr-poll-retire.sh <task-id> --reason <reason>
# Removes only the named .check.sh, .pr-poll and .pr-poll-registration.
# Requires an intact authenticated poll generation, including an older program
# whose stored hash and file identities still match. Never executes that program.
# Refuses custom checks, unsafe artifacts, and a pending merge-retirement receipt.
# Metadata, statuses, worktrees and branches are preserved; the reason is printed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$FM_ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_ROOT/bin/fm-wake-lib.sh"

if [ "$#" -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
  echo 'usage: fm-pr-poll-retire.sh <task-id> --reason <reason>'
  exit 0
fi
if [ "$#" -ne 3 ] || ! fm_pr_task_id_valid "$1" || [ "$2" != --reason ] \
  || [ -z "$3" ] || [[ "$3" = *$'\n'* ]] || [[ "$3" = *$'\r'* ]]; then
  echo 'usage: fm-pr-poll-retire.sh <task-id> --reason <reason>' >&2
  exit 2
fi
ID=$1
REASON=$3
[ -n "$STATE" ] && [ -d "$STATE" ] && [ ! -L "$STATE" ] \
  || { echo 'error: state directory is unavailable' >&2; exit 1; }
CONTROL_LOCK="$STATE/.control-$ID.lock"
PUBLISH_LOCK="$STATE/.pr-poll-publish-$ID.lock"
CONTROL_HELD=0
PUBLISH_HELD=0
cleanup() {
  [ "$PUBLISH_HELD" -eq 0 ] || fm_lock_release "$PUBLISH_LOCK" || true
  [ "$CONTROL_HELD" -eq 0 ] || fm_lock_release "$CONTROL_LOCK" || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$CONTROL_LOCK"
CONTROL_HELD=1
fm_lock_acquire_wait "$PUBLISH_LOCK"
PUBLISH_HELD=1
CHECK="$STATE/$ID.check.sh"
DATA="$STATE/$ID.pr-poll"
REGISTRATION="$STATE/$ID.pr-poll-registration"
for special in "$STATE/$ID.check-trust" "$STATE/$ID.pr-poll-retirement"; do
  if [ -e "$special" ] || [ -L "$special" ]; then
    echo 'error: custom check or pending merge retirement cannot be retired here' >&2
    exit 1
  fi
done
if [ ! -e "$CHECK" ] && [ ! -L "$CHECK" ] \
  && [ ! -e "$DATA" ] && [ ! -L "$DATA" ] \
  && [ ! -e "$REGISTRATION" ] && [ ! -L "$REGISTRATION" ]; then
  printf 'PR poll already retired: %s; reason: %s\n' "$ID" "$REASON"
  exit 0
fi
fm_pr_poll_artifacts_valid "$STATE" "$ID" "$CHECK" \
  || { echo 'error: PR poll artifacts are unsafe or unauthenticated; nothing removed' >&2; exit 1; }
rm -- "$CHECK" "$DATA" "$REGISTRATION"
printf 'PR poll retired: %s; reason: %s\n' "$ID" "$REASON"
