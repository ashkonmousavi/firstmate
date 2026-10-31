#!/usr/bin/env bash
# Close one existing pending-reply correlation as needing no reply.
# Usage: FM_HOME=<parent-home> fm-pending-reply-ack-handled.sh <task-id> <corr-id>
#
# The recipient names the exact correlation. No text heuristic closes records,
# and acknowledging an inbox message by moving it to handled/ does not call
# this. This does not send to the secondmate or alter any other pending reply.
# bin/fm-pending-reply-lib.sh's fm_pending_reply_ack_handled owns the record
# checks, the resolved_via=handled transition, the "handled, no reply needed"
# close note, and the escalation close.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

if [ "$#" -ne 2 ] || [ -z "${FM_HOME:-}" ]; then
  echo "usage: FM_HOME=<parent-home> fm-pending-reply-ack-handled.sh <task-id> <corr-id>" >&2
  exit 2
fi
task_id=$1
corr=$2
case "$task_id" in ''|*[!A-Za-z0-9._-]*|.*) echo "error: unsafe task id" >&2; exit 2 ;; esac
[[ $corr =~ ^[a-f0-9]{16}$ ]] || { echo "error: unsafe correlation id" >&2; exit 2; }
fm_pending_reply_ack_handled "$FM_HOME" "$task_id" "$corr" || exit 1
printf 'handled, no reply needed: %s %s\n' "$task_id" "$corr"
