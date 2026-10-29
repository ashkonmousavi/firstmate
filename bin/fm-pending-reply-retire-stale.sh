#!/usr/bin/env bash
# Retire stale superseded pending-reply records without deleting them.
# Usage:
#   FM_HOME=<parent-home> fm-pending-reply-retire-stale.sh (--dry-run|--apply)
#
# A record is eligible only when strictly older than 86400 seconds (24 hours)
# and superseded: a later record for the same task has confirmed delivery,
# or its task metadata is gone.
# An unanswered record that is not superseded stays open.
# --dry-run lists eligible records and changes nothing.
# --apply marks each one resolved with resolved_via=retired-stale, keeps the
# file, records why, and closes only that correlation's escalation.
# This does not send to the secondmate and does not change who gets a
# recovery or an escalation.
# bin/fm-pending-reply-lib.sh's fm_pending_reply_retire_stale owns the checks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  echo "usage: FM_HOME=<parent-home> fm-pending-reply-retire-stale.sh (--dry-run|--apply)" >&2
  exit 2
}

mode=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|--apply)
      [ -z "$mode" ] || usage
      mode=${1#--}
      ;;
    --help|-h)
      mode=help
      break
      ;;
    *) usage ;;
  esac
  shift
done

[ -n "$mode" ] || usage
[ "$mode" = help ] || [ -n "${FM_HOME:-}" ] || usage
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
if [ "$mode" = help ]; then
  echo "usage: FM_HOME=<parent-home> fm-pending-reply-retire-stale.sh (--dry-run|--apply)"
  echo "retirement age: ${FM_PENDING_REPLY_STALE_AGE_SECS} seconds (24 hours)"
  echo "eligible records are strictly older than 24 hours and superseded; the record file is kept"
  exit 0
fi
home=$(cd "$FM_HOME" && pwd -P) || exit 1
fm_pending_reply_retire_stale "$home" "$mode"
