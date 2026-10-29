#!/usr/bin/env bash
# Retire stale superseded pending-reply records without deleting them.
# Usage:
#   FM_HOME=<parent-home> fm-pending-reply-retire-stale.sh (--dry-run|--apply) [--max-age <seconds>]
#
# --max-age defaults to 86400 (24 hours). A record is eligible only when it
# is strictly older than that age and it is superseded: a later record for
# the same task exists, its task metadata is gone, or that task is a ship
# or scout whose latest complete status event is done or failed.
# An unanswered record that is not superseded stays open.
# --dry-run lists eligible records and changes nothing.
# --apply marks each one resolved with resolved_via=retired-stale, keeps the
# file, records why, and closes only that correlation's escalation.
# This does not send to the secondmate and does not change who gets a
# recovery or an escalation.
# bin/fm-pending-reply-lib.sh's fm_pending_reply_retire_stale owns the checks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

usage() {
  echo "usage: FM_HOME=<parent-home> fm-pending-reply-retire-stale.sh (--dry-run|--apply) [--max-age <seconds>]" >&2
  exit 2
}

mode=''
max_age=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|--apply)
      [ -z "$mode" ] || usage
      mode=${1#--}
      ;;
    --max-age)
      [ "$#" -ge 2 ] || usage
      max_age=$2
      shift
      ;;
    --help|-h)
      echo "usage: FM_HOME=<parent-home> fm-pending-reply-retire-stale.sh (--dry-run|--apply) [--max-age <seconds>]"
      echo "default max-age: ${FM_PENDING_REPLY_STALE_MAX_AGE_DEFAULT} (24 hours)"
      echo "eligible records are strictly older than max-age and superseded; the record file is kept"
      exit 0
      ;;
    *) usage ;;
  esac
  shift
done

[ -n "$mode" ] || usage
[ -n "${FM_HOME:-}" ] || usage
if [ -z "$max_age" ]; then
  max_age=$FM_PENDING_REPLY_STALE_MAX_AGE_DEFAULT
fi
case "$max_age" in
  ''|*[!0-9]*) echo "error: --max-age must be a non-negative integer number of seconds" >&2; exit 2 ;;
esac
max_age=$((10#$max_age))

home=$(cd "$FM_HOME" && pwd -P) || exit 1
fm_pending_reply_retire_stale "$home" "$max_age" "$mode"
