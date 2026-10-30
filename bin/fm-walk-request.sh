#!/usr/bin/env bash
# fm-walk-request.sh - a secondmate's typed walk request on its parent channel.
#
# Usage:
#   fm-walk-request.sh --brief <absolute-brief-path> --release <sha> \
#     --walks <walk-id>[,<walk-id>...] [--bot <bot-name>] \
#     [--project <name> --target <name>]
#   fm-walk-request.sh --help
#
# WHY. The walker dispatcher (fm-grok-bot-dispatch.sh) and its Grok Bot bridge
# are private to one home (the PC MAIN home). This carrier routes a mate's
# checkpoint walk request to that home without a human hand-off: it writes
# the request on the mate's own parent channel, which is the one pipe that
# already reaches MAIN for every mate shape (a local route appends into the
# parent home's state/<mate-id>.status directly; a remote route appends into
# this home's state/parent-replies.status, which the parent's reply adapter
# mirrors line for line - bin/fm-parent-channel-lib.sh,
# docs/secondmate-parent-channel.md). No credential, bridge, or sign-in moves:
# the request is one informational channel line.
#
# THE TYPED LINE, owned here and read by MAIN's walk-request check
# (bin/fm-walk-request-check.sh):
#   note [corr=<16hex>] [at=<epoch>]: walk-request: walks=<ids>
#   brief64=<base64-UTF-8> release=<sha> [bot=<name>] [project=<name>
#   target=<name>]
# Local requests may use brief=<absolute-path> instead of brief64.
# The corr token is the request's receipt identity. The bot field may be
# omitted by the caller only when MAIN's default names one
# (FM_WALK_REQUEST_BOT there); the check reports a request with no resolvable
# bot plainly rather than guessing. The project and target fields come as a
# pair and are passed to MAIN's dispatcher as --project/--target, overriding
# MAIN's FM_WALK_REQUEST_PROJECT/FM_WALK_REQUEST_TARGET pair; omitted, MAIN's
# pair or none applies (bin/fm-walk-request-check.sh). Each is one space-free
# token; the dispatcher validates the pair itself. Briefs are UTF-8 text, at most 64 KiB,
# with binary control bytes refused. Remote requests carry their content inline;
# local paths are confined and copied by MAIN before dispatch.
#
# OUTPUT. Prints the corr id and one <walk-id>@<release> dispatch key per
# walk, so the caller can correlate the outcome MAIN returns. The request is
# fire-and-forget on the channel: MAIN's check owns dispatch, at-most-once
# keys, and returning the outcome through the mate's existing reply path (its
# steering inbox), not this script.
#
# Refused (exit 2, nothing written): a main home (this carrier is for
# secondmate homes - run the dispatcher directly instead), a broken parent
# binding, or invalid fields. Exit 4 is a channel append failure after
# validation; the caller may retry the same command.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-parent-channel-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-walk-request.sh --brief <absolute-brief-path> --release <sha> \
    --walks <walk-id>[,<walk-id>...] [--bot <bot-name>] \
    [--project <name> --target <name>]
  fm-walk-request.sh --help

Writes one typed walk request on this secondmate home's parent channel so
MAIN's registered walk-request check dispatches it through the home-private
fm-grok-bot-dispatch.sh (at most once per <walk-id>@<release>) and returns
the outcome to this home's steering inbox.

The brief must be UTF-8 text of at most 64 KiB, inside this mate data/walk-briefs
or MAIN data/from-main/walk-lists; private paths and symlink escapes are refused.
Remote requests carry the content inline. MAIN dispatches a private copy. The release is the
served commit the walk covers. Walk ids are privacy-safe slugs.
EOF
}

fail() {
  printf 'fm-walk-request: %s\n' "$*" >&2
  exit 2
}

# Privacy-safe correlation id, same shape as bin/fm-pending-reply-lib.sh's.
walk_request_new_corr() {
  local raw='' hex
  if command -v openssl >/dev/null 2>&1; then
    raw=$(openssl rand -hex 8 2>/dev/null || true)
  fi
  if [ -z "$raw" ]; then
    raw=$(printf '%s' "$$-$(date +%s%N 2>/dev/null || date +%s)-$RANDOM$RANDOM" | cksum 2>/dev/null | awk '{print $1}')
    hex=$(printf '%s' "$raw$RANDOM$RANDOM" | shasum -a 256 2>/dev/null | awk '{print $1}')
    raw=${hex:0:16}
  fi
  printf '%s' "$(printf '%s' "$raw" | tr 'A-F' 'a-f' | tr -cd 'a-f0-9' | cut -c1-16)"
}

BRIEF=
RELEASE=
WALKS=
BOT=
PROJECT=
TARGET=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --brief) shift; BRIEF=${1:-} ;;
    --release) shift; RELEASE=${1:-} ;;
    --walks) shift; WALKS=${1:-} ;;
    --bot) shift; BOT=${1:-} ;;
    --project) shift; PROJECT=${1:-} ;;
    --target) shift; TARGET=${1:-} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "$BRIEF" ] && [ -n "$RELEASE" ] && [ -n "$WALKS" ] || {
  usage >&2
  exit 2
}
case "$BRIEF" in
  /*) ;;
  *) fail "--brief must be an absolute path: $BRIEF" ;;
esac
case "$BRIEF" in
  # A single token: the typed line is space-separated key=value fields, so a
  # path with whitespace cannot round-trip it.
  *[![:print:]]*|*$'\t'*|*' '*) fail "--brief must be a space-free single-line path" ;;
esac
case "$RELEASE" in
  [0-9a-fA-F]*) ;;
  *) fail "--release must be a commit sha (hex): $RELEASE" ;;
esac
case "$RELEASE" in
  *[!0-9a-fA-F]*) fail "--release must be a commit sha (hex): $RELEASE" ;;
esac
[ "${#RELEASE}" -ge 7 ] && [ "${#RELEASE}" -le 64 ] || fail "--release must be 7..64 hex characters"
# Walk ids become once-key components and channel tokens, so they accept the
# same privacy-safe slug class the rest of the fleet uses for ids. The list
# is comma-separated with no spaces, so one id can never split into two.
[ -n "$WALKS" ] || fail "--walks must name at least one walk id"
case "$WALKS" in
  ''|*[[:space:]]*) fail "--walks must be comma-separated privacy-safe slugs with no spaces" ;;
esac
WALKS=$(printf '%s' "$WALKS" | tr ',' ' ' | tr -s ' ' ' ')
WALKS=${WALKS# }; WALKS=${WALKS% }
for walk in $WALKS; do
  case "$walk" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) fail "--walks ids must be privacy-safe slugs: $walk" ;;
  esac
  [ "${#walk}" -le 64 ] || fail "--walks ids must be at most 64 characters: $walk"
done
# shellcheck disable=SC2086  # deliberate word split: every id is a validated slug
WALKS=$(printf '%s\n' $WALKS | awk '!seen[$0]++' | paste -sd, -)
if [ -n "$BOT" ]; then
  # A single token: the typed line is space-separated key=value fields, so a
  # bot name with whitespace cannot round-trip it.
  case "$BOT" in
    ''|*[!A-Za-z0-9._-]*) fail "--bot must be one space-free bot name: $BOT" ;;
  esac
fi
# project and target travel as a pair of single tokens, like the bot name.
if [ -n "$PROJECT$TARGET" ]; then
  [ -n "$PROJECT" ] && [ -n "$TARGET" ] || fail "--project and --target must be given together"
  case "$PROJECT$TARGET" in
    *[!A-Za-z0-9._-]*) fail "--project and --target must each be one space-free name" ;;
  esac
  case "$PROJECT" in [!A-Za-z0-9]*) fail "--project must start with a letter or digit" ;; esac
  case "$TARGET" in [!A-Za-z0-9]*) fail "--target must start with a letter or digit" ;; esac
fi

destination=$(fm_parent_channel_destination "$FM_HOME" "$STATE") || rc=$?
case "${rc:-0}" in
  0) : ;;
  1) fail "this home is not a secondmate; run the walker dispatcher in the home that owns it" ;;
  *) fail "this home's parent channel is unavailable (rc=$rc); fix the secondmate binding before requesting a walk" ;;
esac

fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" || fail "this home's parent binding is unavailable"
brief_field=brief
brief_action=path
if [ "$FM_SECONDMATE_PARENT_ROUTE" = remote ]; then
  brief_field=brief64
  brief_action=encode
fi
BRIEF=$(python3 "$SCRIPT_DIR/fm-walk-request-path.py" "$brief_action" "$BRIEF" "$FM_HOME" "${FM_SECONDMATE_PARENT_HOME:-}") \
  || fail "--brief must name an approved UTF-8 walk brief of at most 64 KiB"

corr=$(walk_request_new_corr)
[ -n "$corr" ] || fail "could not mint a correlation id"
line="note [corr=$corr]: walk-request: walks=$WALKS $brief_field=$BRIEF release=$RELEASE"
[ -z "$BOT" ] || line="$line bot=$BOT"
[ -z "$PROJECT" ] || line="$line project=$PROJECT target=$TARGET"
fm_parent_channel_append_once "$destination" "$(status_stamp_line "$line")" || {
  printf 'fm-walk-request: could not append the request to the parent channel at %s\n' "$destination" >&2
  exit 4
}

printf 'corr=%s\n' "$corr"
for walk in $(printf '%s' "$WALKS" | tr ',' ' '); do
  printf 'once-key=%s@%s\n' "$walk" "$RELEASE"
done
