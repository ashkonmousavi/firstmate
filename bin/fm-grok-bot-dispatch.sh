#!/usr/bin/env bash
# fm-grok-bot-dispatch.sh - send one routed task to a named Grok Bot and
# return its reply, for a crew-dispatch profile {"grok_bot":"<Bot name>"}.
#
# Usage:
#   fm-grok-bot-dispatch.sh <brief-file> --bot <name> [--timeout <sec>]
#                           [--walk <walk-id> --walk-owner <owner-id>]
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
# Output: the reply text on stdout, followed by one
#   `grok-bot: unverified` line. The reply is unverified: firstmate has it
#   checked by a candidate from another vendor before relaying or acting on it.
#
# Walk marker (--walk): a live walk holds every restart on the walked host.
#   After the Bot resolves and before anything is sent, the walk is claimed in
#   that host's walk marker for --timeout seconds; when the reply lands, the
#   timeout passes, or the send fails, only this walk is released again.
#   bin/fm-walk-marker.py owns the marker format, overlap and expiry rules; it
#   runs through the home-private transport $FM_HOME/data/walk-marker/transport,
#   or FM_WALK_MARKER_TRANSPORT when set: an executable run as
#   `<transport> claim|release <walk> <owner> <seconds|started> < bin/fm-walk-marker.py`
#   that executes the program from stdin with python3 and those arguments as
#   the marker's account on the walked host. Ids match [A-Za-z0-9][A-Za-z0-9._:-]*.
#   A missing transport, a failed claim, another owner's active claim, or a
#   malformed marker refuses the walk before anything is sent.
#
# Exit codes: 0 reply received; 3 the Bot was still working at the timeout
#   (read the rest later with the bridge's `transcript <id>`); 2 usage,
#   missing bridge or tool, unknown or ambiguous Bot name, a bridge failure, or
#   a refused walk claim; 4 the reply was returned (or the timeout passed) but
#   the walk's release failed, so its claim holds restarts until it expires.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
BRIDGE="${FM_GROKBOT_BRIDGE:-$FM_HOME/data/grok-bot-bridge/grokbot.mjs}"
WALK_TRANSPORT="${FM_WALK_MARKER_TRANSPORT:-$FM_HOME/data/walk-marker/transport}"
WALK_PROGRAM="$SCRIPT_DIR/fm-walk-marker.py"

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

BRIEF='' BOT='' TIMEOUT=300 WALK='' WALK_OWNER=''
while [ $# -gt 0 ]; do
  case "$1" in
    --bot) [ $# -ge 2 ] || die "--bot needs a value"; BOT=$2; shift 2 ;;
    --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; TIMEOUT=$2; shift 2 ;;
    --walk) [ $# -ge 2 ] || die "--walk needs a value"; WALK=$2; shift 2 ;;
    --walk-owner) [ $# -ge 2 ] || die "--walk-owner needs a value"; WALK_OWNER=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$BRIEF" ] || die "one brief file only"; BRIEF=$1; shift ;;
  esac
done

[ -n "$BRIEF" ] || die "brief file required (see --help)"
[ -r "$BRIEF" ] || die "brief file not readable: $BRIEF"
[[ "$BOT" =~ [^[:space:]] ]] || die "--bot <name> required"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive number of seconds"
[ -f "$BRIDGE" ] || die "Grok Bot bridge not found: $BRIDGE; Grok Bot targets run only in the home that holds the bridge (the primary), so treat this candidate as unavailable and fall to the rule's other candidates"
command -v node >/dev/null 2>&1 || die "node required"
command -v jq >/dev/null 2>&1 || die "jq required"
if [ -n "$WALK$WALK_OWNER" ]; then
  id_re='^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
  [[ "$WALK" =~ $id_re && "$WALK_OWNER" =~ $id_re ]] \
    || die "--walk and --walk-owner both need an id matching [A-Za-z0-9][A-Za-z0-9._:-]*"
  [ -x "$WALK_TRANSPORT" ] || die "walk marker transport not found: $WALK_TRANSPORT; the walk is not sent"
  command -v python3 >/dev/null 2>&1 || die "python3 required for a bounded walk"
fi

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

WALK_CLAIMED='' WALK_STARTED=''
walk_marker() {  # <claim|release> <seconds|started>: prints the program's one JSON line
  local receipt
  receipt=$("$WALK_TRANSPORT" "$1" "$WALK" "$WALK_OWNER" "${@:2}" < "$WALK_PROGRAM" 2>&1) \
    || { printf '%s\n' "$receipt" >&2; return 1; }
  if ! jq -se --arg op "$1" --arg walk "$WALK" --arg owner "$WALK_OWNER" --arg started "$WALK_STARTED" '
    def utc:
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
      and (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == .) catch false);
    def marker:
      .owner == $owner and (.walks | type == "array" and length > 0)
      and all(.walks[]; type == "string" and test("\\S"))
      and ((.walks | unique | length) == (.walks | length))
      and (.started | utc) and (.expires_at | utc)
      and (.expires_at > .started);
    length == 1 and (.[0] | type == "object" and
      if $op == "claim" then
        .result == "claimed" and marker and (.walks | index($walk) != null)
      elif .result == "cleared" or .result == "absent" then
        .walks == null and .owner == null and .started == null and .expires_at == null
      else
        (.result == "released" or .result == "not-listed")
        and marker and .started == $started and (.walks | index($walk) == null)
      end)
  ' <<<"$receipt" >/dev/null 2>&1; then
    printf 'invalid %s receipt: %s\n' "$1" "${receipt:0:300}" >&2
    return 1
  fi
  printf '%s\n' "$receipt"
}
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
walk_release_on_exit() {
  local rc=$? result
  [ -n "$WALK_CLAIMED" ] || exit "$rc"
  if result=$(walk_marker release "$WALK_STARTED" 2>&1); then exit "$rc"; fi
  printf 'walk-marker: release failed for %s (%s); the claim holds restarts until %s: %s\n' \
    "$WALK" "$WALK_OWNER" "$WALK_CLAIMED" "${result:0:300}" >&2
  case "$rc" in 0|3) exit 4 ;; *) exit "$rc" ;; esac
}
if [ -n "$WALK" ]; then
  WALK_DEADLINE=$(python3 -c 'import sys, time; print(time.monotonic() + int(sys.argv[1]))' "$TIMEOUT") \
    || die "could not establish the walk deadline"
  CLAIM=$(walk_marker claim "$TIMEOUT" 2>&1) \
    || die "walk marker not claimed for $WALK, so nothing was sent: ${CLAIM:0:300}"
  WALK_CLAIMED=$(jq -r '.expires_at' <<<"$CLAIM")
  WALK_STARTED=$(jq -r '.started' <<<"$CLAIM")
  trap walk_release_on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
fi

chat() {
  if [ -z "$WALK" ]; then
    node "$BRIDGE" chat "$ID" "$PROMPT" "$TIMEOUT"
    return $?
  fi
  python3 - "$WALK_DEADLINE" "$BRIDGE" "$ID" "$PROMPT" <<'PY'
import math
import subprocess
import sys
import time

remaining = float(sys.argv[1]) - time.monotonic()
if remaining <= 0:
    sys.exit(3)
try:
    result = subprocess.run(["node", sys.argv[2], "chat", sys.argv[3], sys.argv[4], str(math.ceil(remaining))],
                            timeout=remaining)
except subprocess.TimeoutExpired:
    sys.exit(3)
sys.exit(result.returncode if result.returncode >= 0 else 2)
PY
}
CHAT=$(chat)
CHAT_CODE=$?
if [ "$CHAT_CODE" -eq 3 ] && [ -n "$WALK" ]; then
  printf 'grok-bot: walk %s reached its dispatch deadline\n' "$WALK" >&2
  exit 3
fi
[ "$CHAT_CODE" -eq 0 ] || die "Grok Bot bridge chat failed"
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
