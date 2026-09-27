#!/usr/bin/env bash
# Retire one historical routine notice mistakenly sent as a reply request.
# Usage: FM_HOME=<parent-home> fm-pending-reply-retire-notice.sh <task-id> <corr-id>
#
# The operator identifies the exact correlation after verifying that its
# original message was a one-way notice. No text heuristic retires records.
# This does not send to the secondmate or alter any other pending reply.
# bin/fm-pending-reply-lib.sh's fm_pending_reply_retire_notice owns the record
# checks, the resolved_via=notice transition, and the escalation close.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

if [ "$#" -ne 2 ] || [ -z "${FM_HOME:-}" ]; then
  echo "usage: FM_HOME=<parent-home> fm-pending-reply-retire-notice.sh <task-id> <corr-id>" >&2
  exit 2
fi
task_id=$1
corr=$2
case "$task_id" in ''|*[!A-Za-z0-9._-]*|.*) echo "error: unsafe task id" >&2; exit 2 ;; esac
[[ $corr =~ ^[a-f0-9]{16}$ ]] || { echo "error: unsafe correlation id" >&2; exit 2; }
home=$(cd "$FM_HOME" && pwd -P) || exit 1
fm_pending_reply_retire_notice "$home" "$task_id" "$corr" || exit 1
printf 'retired notice: %s %s\n' "$task_id" "$corr"
