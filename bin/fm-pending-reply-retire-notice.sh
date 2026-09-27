#!/usr/bin/env bash
# Retire one historical routine notice mistakenly sent as a reply request.
# Usage: FM_HOME=<parent-home> fm-pending-reply-retire-notice.sh <task-id> <corr-id>
#
# The operator identifies the exact correlation after verifying that its
# original message was a one-way notice. No text heuristic retires records.
# This does not send to the secondmate or alter any other pending reply.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -ne 2 ] || [ -z "${FM_HOME:-}" ]; then
  echo "usage: FM_HOME=<parent-home> fm-pending-reply-retire-notice.sh <task-id> <corr-id>" >&2
  exit 2
fi
task_id=$1
corr=$2
case "$task_id" in ''|*[!A-Za-z0-9._-]*|.*) echo "error: unsafe task id" >&2; exit 2 ;; esac
[[ $corr =~ ^[a-f0-9]{16}$ ]] || { echo "error: unsafe correlation id" >&2; exit 2; }
home=$(cd "$FM_HOME" && pwd -P) || exit 1
state="$home/state"
rec=$(fm_pending_reply_path "$state" "$corr")
status="$state/$task_id.status"
[ -f "$rec" ] && [ ! -L "$rec" ] && [ -f "$status" ] && [ ! -L "$status" ] || {
  echo "error: exact pending record or parent status missing" >&2
  exit 1
}
lock="$state/.pending-reply-$corr.lock"
fm_lock_acquire_wait "$lock" || exit 1
rc=0
if [ "$(fm_pending_reply_get "$rec" schema)" != "$FM_PENDING_REPLY_SCHEMA" ] ||
   [ "$(fm_pending_reply_get "$rec" corr_id)" != "$corr" ] ||
   [ "$(fm_pending_reply_get "$rec" task_id)" != "$task_id" ] ||
   [ "$(fm_pending_reply_get "$rec" parent_home)" != "$home" ] ||
   [ "$(fm_pending_reply_get "$rec" parent_status)" != "$status" ]; then
  echo "error: pending record identity mismatch" >&2
  rc=1
elif [ "$(fm_pending_reply_get "$rec" phase)" = resolved ]; then
  [ "$(fm_pending_reply_get "$rec" resolved_via)" = notice ] || {
    echo "error: correlation already resolved through another path" >&2
    rc=1
  }
else
  now=$(fm_pending_reply_now)
  fm_pending_reply_set "$rec" resolved_via notice &&
    fm_pending_reply_set "$rec" resolved_epoch "$now" &&
    fm_pending_reply_set "$rec" phase resolved || rc=1
fi
if [ "$rc" -eq 0 ]; then
  _fm_pending_reply_close_escalation_locked "$state" "$corr" || rc=1
fi
fm_lock_release "$lock"
[ "$rc" -eq 0 ] || exit "$rc"
printf 'retired notice: %s %s\n' "$task_id" "$corr"
