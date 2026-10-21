#!/usr/bin/env bash
# fm-secondmate-report.sh - optional helper to append a correlated parent report.
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: another literal
# append to the parent channel with the same corr token is equally valid
# (bin/fm-pending-reply-lib.sh). For safe shell appends, see the invocation
# contract in bin/fm-status-append.sh's header.
#
# The write destination is mechanical: this helper never takes a status path.
# It resolves the parent channel through fm_parent_channel_destination
# (bin/fm-parent-channel-lib.sh): a local mate writes the parent home's
# state/<id>.status, and a remote mate writes this home's
# state/parent-replies.status. Call it from the secondmate home with FM_HOME
# set to that home.
#
# Usage:
#   fm-secondmate-report.sh <verb> <corr_id> <<'EOF'
#   <note>
#   EOF
#   fm-secondmate-report.sh <verb> <corr_id> <note...>
#   fm-secondmate-report.sh --doc <verb> <corr_id> <doc-path> [note...]
#   fm-secondmate-report.sh --doc <verb> <corr_id> <doc-path> <<'EOF'
#   <note>
#   EOF
#
# With no note argument, the note is read from stdin and is never evaluated.
# A note argument still works, for callers that already pass the text as data.
# Newlines in a stdin note are folded to spaces so the status line stays one line.
#
# Examples:
#   fm-secondmate-report.sh done abcdef0123456789 <<'EOF'
#   audit clean
#   EOF
#   fm-secondmate-report.sh done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh --doc done abcdef0123456789 data/x/report.md "see report"
set -eu

CALLER_FM_HOME=${FM_HOME:-}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  fm-secondmate-report.sh <verb> <corr_id> <note...>
  fm-secondmate-report.sh <verb> <corr_id>  (note read from stdin)
  fm-secondmate-report.sh --doc <verb> <corr_id> <doc-path> [note...]
  With no note argument, pass the note on stdin with a quoted heredoc.
EOF
  exit 2
}

# Drop one trailing newline, then fold the rest to spaces. A quoted heredoc
# always ends with a newline; that terminator is not part of the note.
read_folded_note() {
  local text
  if [ -t 0 ]; then
    printf ''
    return 0
  fi
  text=$(cat; printf x)
  text=${text%x}
  case "$text" in
    *$'\n') text=${text%$'\n'} ;;
  esac
  text=${text//$'\r\n'/ }
  text=${text//$'\n'/ }
  text=${text//$'\r'/ }
  printf '%s' "$text"
}

DOC_MODE=0
if [ "${1:-}" = "--doc" ]; then
  DOC_MODE=1
  shift
fi

[ $# -ge 2 ] || usage
VERB=$1
CORR=$2
shift 2
if [ "$DOC_MODE" = 1 ]; then
  [ $# -ge 1 ] && [ -n "$1" ] || usage
else
  if [ $# -eq 0 ]; then
    [ -t 0 ] && usage
  else
    [ -n "$*" ] || usage
  fi
fi

case "$CORR" in
  corr=*) CORR=${CORR#corr=} ;;
esac
case "$CORR" in
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *)
    echo "error: corr_id must be 16 hex characters (got '$CORR')" >&2
    exit 1
    ;;
esac

HOME_DIR=$CALLER_FM_HOME
case "$HOME_DIR" in
  '')
    echo "error: FM_HOME is required so the helper can resolve the parent channel" >&2
    exit 1
    ;;
esac
STATE_DIR="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"

DESTINATION=
DEST_RC=0
DESTINATION=$(fm_parent_channel_destination "$HOME_DIR" "$STATE_DIR") || DEST_RC=$?
if [ "$DEST_RC" -ne 0 ] || [ -z "$DESTINATION" ]; then
  echo "error: cannot resolve the parent channel from this home (not a seeded secondmate?)" >&2
  exit 1
fi
mkdir -p "$(dirname "$DESTINATION")" 2>/dev/null || true
if [ ! -d "$(dirname "$DESTINATION")" ]; then
  echo "error: cannot create parent directory for status file '$DESTINATION'" >&2
  exit 1
fi

token=$(fm_pending_reply_corr_token "$CORR")
if [ "$DOC_MODE" = 1 ]; then
  DOC_PATH=$1
  shift
  if [ $# -ge 1 ]; then
    NOTE=$*
  else
    NOTE=$(read_folded_note)
  fi
  if [ -n "$NOTE" ]; then
    printf -v line '%s [%s]: %s (%s via-helper)' "$VERB" "$token" "$NOTE" "$DOC_PATH"
  else
    printf -v line '%s [%s]: %s (via-helper)' "$VERB" "$token" "$DOC_PATH"
  fi
else
  if [ $# -ge 1 ]; then
    NOTE=$*
  else
    NOTE=$(read_folded_note)
  fi
  [ -n "$NOTE" ] || usage
  printf -v line '%s [%s]: %s (via-helper)' "$VERB" "$token" "$NOTE"
fi
printf '%s\n' "$(status_stamp_line "$line")" >> "$DESTINATION"
