#!/usr/bin/env bash
# fm-grok-bot-dispatch.sh - send one routed task to a named Grok Bot and
# return its reply, for a crew-dispatch profile {"grok_bot":"<Bot name>"}.
#
# Usage:
#   fm-grok-bot-dispatch.sh <brief-file> --bot <name> [--timeout <sec>]
#                           [--once-key <key>]
#
# Grok Bot is not a launchable harness: it has no worktree, hooks, or access
# to local files, so route it only file-free work such as web research and
# public-repository reading. The profile shape and routing contract are owned
# by docs/configuration.md "Crew dispatch profiles".
#
# What it sends: the brief's `## Captain's intent` and `## Firstmate spec`
#   sections, read by bin/fm-brief-heading-lib.sh (the whole brief when it has
#   neither), and nothing else from this machine.
# How: through the local bridge, $FM_HOME/data/grok-bot-bridge/grokbot.mjs, or
#   FM_GROKBOT_BRIDGE when set. The bridge is private to the home and is not
#   shipped with this repository; when it is absent this tool refuses.
#   It resolves <name> to exactly one Bot with `list`, then runs one `chat`
#   turn that waits up to --timeout seconds (default 300). A longer wait can
#   outlast a supervisor's per-command limit, so run long turns in the
#   background.
#
# --once-key <key>: send this task at most once per key, so a repeated
#   supervision pass converges instead of sending a duplicate. The key is
#   letters, digits, `.`, `_`, `@` and `-` (for a walker re-check,
#   <assignment>@<served-commit>). Before `chat` the key is claimed atomically
#   as the directory $FM_HOME/state/grok-bot-once/<key>; once the bridge
#   accepts the send (exit 0 or 3) a `sent` record is written inside it.
#   A key already sent prints `grok-bot: once-key <key> already sent ...`,
#   sends nothing, and exits 0. A failed `chat` removes the claim, so a retry
#   sends. A claim without `sent` belongs to a dispatch in flight or one
#   interrupted mid-send: it refuses with exit 2 rather than risk a duplicate;
#   after reading the bridge transcript, remove that empty directory by hand
#   to allow a resend. Without the flag nothing is recorded.
#
# Output: the reply text on stdout, followed by one
#   `grok-bot: unverified` line. The reply is unverified: firstmate has it
#   checked by a candidate from another vendor before relaying or acting on it.
#
# Exit codes: 0 reply received, or the --once-key was already sent; 3 the Bot
#   was still working at the timeout (read the rest later with the bridge's
#   `transcript <id>`); 2 usage, missing bridge or tool, unknown or ambiguous
#   Bot name, a bridge failure, or a --once-key held by another dispatch.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
BRIDGE="${FM_GROKBOT_BRIDGE:-$FM_HOME/data/grok-bot-bridge/grokbot.mjs}"

# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

BRIEF='' BOT='' TIMEOUT=300 ONCE_KEY='' ONCE_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bot) [ $# -ge 2 ] || die "--bot needs a value"; BOT=$2; shift 2 ;;
    --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; TIMEOUT=$2; shift 2 ;;
    --once-key) [ $# -ge 2 ] || die "--once-key needs a value"; ONCE_KEY=$2; ONCE_SET=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$BRIEF" ] || die "one brief file only"; BRIEF=$1; shift ;;
  esac
done

[ -n "$BRIEF" ] || die "brief file required (see --help)"
[ -r "$BRIEF" ] || die "brief file not readable: $BRIEF"
[[ "$BOT" =~ [^[:space:]] ]] || die "--bot <name> required"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive number of seconds"
if [ "$ONCE_SET" = 1 ]; then
  [[ "$ONCE_KEY" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] \
    || die "--once-key must be letters, digits, '.', '_', '@' or '-', starting with a letter or digit"
  ONCE_CLAIM="$FM_HOME/state/grok-bot-once/$ONCE_KEY"
  if [ -f "$ONCE_CLAIM/sent" ]; then
    printf 'grok-bot: once-key %s already sent to %s; not sent again\n' "$ONCE_KEY" "$BOT"
    exit 0
  fi
fi
[ -f "$BRIDGE" ] || die "Grok Bot bridge not found: $BRIDGE; Grok Bot targets run only in the home that holds the bridge (the primary), so treat this candidate as unavailable and fall to the rule's other candidates"
command -v node >/dev/null 2>&1 || die "node required"
command -v jq >/dev/null 2>&1 || die "jq required"

task_text() {
  local heading sections=''
  for heading in "## Captain's intent" "## Firstmate spec"; do
    fm_brief_task_heading_present "$BRIEF" "$heading" || continue
    sections+="$heading"$'\n'"$(fm_brief_task_heading_body "$BRIEF" "$heading")"$'\n\n'
  done
  if [ -n "$sections" ]; then printf '%s' "$sections"; else cat "$BRIEF"; fi
}
PROMPT=$(task_text) || die "could not read brief: $BRIEF"

LIST=$(node "$BRIDGE" list) || die "Grok Bot bridge list failed"
ID=$(jq -r --arg n "$BOT" '
  [.[] | select(.name == $n) | .id] |
  if length == 1 then .[0] else error("\(length)") end' <<<"$LIST" 2>/dev/null) \
  || die "expected exactly one Grok Bot named $BOT"

if [ "$ONCE_SET" = 1 ]; then
  mkdir -p "${ONCE_CLAIM%/*}" || die "could not create once-key directory ${ONCE_CLAIM%/*}"
  if ! mkdir "$ONCE_CLAIM" 2>/dev/null; then
    if [ -f "$ONCE_CLAIM/sent" ]; then
      printf 'grok-bot: once-key %s already sent to %s; not sent again\n' "$ONCE_KEY" "$BOT"
      exit 0
    fi
    die "once-key $ONCE_KEY is held by another dispatch (in flight or interrupted); not sent; see --help to clear an interrupted claim"
  fi
fi
CHAT=$(node "$BRIDGE" chat "$ID" "$PROMPT" "$TIMEOUT") || {
  [ "$ONCE_SET" = 0 ] || rmdir "$ONCE_CLAIM" 2>/dev/null || true
  die "Grok Bot bridge chat failed"
}
if [ "$ONCE_SET" = 1 ]; then
  printf 'key=%s\nbot=%s\nid=%s\nat=%s\n' "$ONCE_KEY" "$BOT" "$ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$ONCE_CLAIM/sent" || printf 'grok-bot: warning: sent, but could not record once-key %s\n' "$ONCE_KEY" >&2
fi
# The bridge prints two JSON documents: the send receipt, then the new entries.
RESULT=$(jq -s 'last' <<<"$CHAT" 2>/dev/null) || die "Grok Bot bridge returned malformed output"
REPLY=$(jq -r --arg p "$PROMPT" '
  [.newEntries[]? | .text | select(type == "string" and test("\\S") and . != $p)] | join("\n\n")' <<<"$RESULT") \
  || die "Grok Bot bridge returned malformed output"

printf '%s\n' "$REPLY"
printf 'grok-bot: unverified reply from %s; have another vendor check it before relaying\n' "$BOT"

if [ "$(jq -r '.stillRunning' <<<"$RESULT")" = true ]; then
  printf 'grok-bot: %s (%s) still working after %ss; read the rest with the bridge transcript command\n' "$BOT" "$ID" "$TIMEOUT" >&2
  exit 3
fi
exit 0
