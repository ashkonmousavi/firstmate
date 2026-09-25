#!/usr/bin/env bash
# fm-grok-bot-dispatch.sh - send one routed task to a named Grok Bot and
# return its reply, for a crew-dispatch profile {"grok_bot":"<Bot name>"}.
#
# Usage:
#   fm-grok-bot-dispatch.sh <brief-file> --bot <name> [--timeout <sec>] [--out <file>]
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
#   turn that waits up to --timeout seconds (default 600).
#
# Output: the reply text on stdout, or written to --out, followed by one
#   `grok-bot: unverified` line. The reply is unverified: firstmate has it
#   checked by a candidate from another vendor before relaying or acting on it.
#
# Exit codes: 0 reply received; 3 the Bot was still working at the timeout
#   (read the rest later with the bridge's `transcript <id>`); 2 usage,
#   missing bridge or tool, unknown or ambiguous Bot name, or a bridge failure.
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

BRIEF='' BOT='' TIMEOUT=600 OUT=''
while [ $# -gt 0 ]; do
  case "$1" in
    --bot) [ $# -ge 2 ] || die "--bot needs a value"; BOT=$2; shift 2 ;;
    --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; TIMEOUT=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || die "--out needs a value"; OUT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$BRIEF" ] || die "one brief file only"; BRIEF=$1; shift ;;
  esac
done

[ -n "$BRIEF" ] || die "brief file required (see --help)"
[ -r "$BRIEF" ] || die "brief file not readable: $BRIEF"
[[ "$BOT" =~ [^[:space:]] ]] || die "--bot <name> required"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive number of seconds"
[ -f "$BRIDGE" ] || die "Grok Bot bridge not found: $BRIDGE"
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

CHAT=$(node "$BRIDGE" chat "$ID" "$PROMPT" "$TIMEOUT") || die "Grok Bot bridge chat failed"
# The bridge prints two JSON documents: the send receipt, then the new entries.
RESULT=$(jq -s 'last' <<<"$CHAT" 2>/dev/null) || die "Grok Bot bridge returned malformed output"
REPLY=$(jq -r --arg p "$PROMPT" '
  [.newEntries[]? | .text | select(type == "string" and test("\\S") and . != $p)] | join("\n\n")' <<<"$RESULT") \
  || die "Grok Bot bridge returned malformed output"

emit() {
  printf '%s\n' "$REPLY"
  printf 'grok-bot: unverified reply from %s; have another vendor check it before relaying\n' "$BOT"
}
if [ -n "$OUT" ]; then emit > "$OUT" || die "could not write $OUT"; else emit; fi

if [ "$(jq -r '.stillRunning' <<<"$RESULT")" = true ]; then
  printf 'grok-bot: %s (%s) still working after %ss; read the rest with the bridge transcript command\n' "$BOT" "$ID" "$TIMEOUT" >&2
  exit 3
fi
exit 0
