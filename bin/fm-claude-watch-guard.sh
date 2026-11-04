#!/usr/bin/env bash
# Claude hook-owned mid-turn watcher continuity and PreToolUse seatbelt.
# Usage: <hook JSON> | fm-claude-watch-guard.sh [--check]
# No arguments: async UserPromptSubmit/PreToolUse hook; one home-scoped owner
# keeps checking for a missing cycle independently of model turns. It defers to
# a healthy watcher or an open Stop auto-arm claim, and otherwise runs the
# existing home-scoped arm wrapper. Stop still owns wake delivery and the host.
# --check: synchronous PreToolUse hook; warn while a cycle is absent, refuse
# fm-spawn.sh/fm-send.sh once the beacon reaches FM_GUARD_GRACE (default 300s).
# Reads and the home-scoped repair command remain available. Fresh beats clear
# immediately; there is no persistent denial latch. stdout is Claude JSON for
# warnings, stderr + exit 2 denies. Workers, foreign primaries and away/daemon
# supervision are inert. No live-home install or restart is performed here.
set -u
case "${1:-}" in
  '') MODE=watch ;;
  --check) MODE=check ;;
  -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
  *) echo 'usage: fm-claude-watch-guard.sh [--check]' >&2; exit 2 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$PAYLOAD" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
printf '%s' "$PAYLOAD" | jq -e '(.transcript_path // "") | contains("/.pi/")' >/dev/null 2>&1 && exit 0
[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
fm_session_lock_owned_by_self "$STATE" || exit 0
SESSION=$FM_SESSION_LOCK_PID
fm_harness_pid_alive "$SESSION" && [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || exit 0
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"
GRACE=${FM_GUARD_GRACE:-300}
case "$GRACE" in ''|0|*[!0-9]*) GRACE=300 ;; esac
SESSION_ID=$(fm_session_pid_identity "$SESSION") || exit 0
attended_owner() {
  [ ! -e "$STATE/.afk" ] && ! fm_afk_contract_away_present "$STATE" \
    && [ "$(cat "$STATE/.lock" 2>/dev/null)" = "$SESSION" ] \
    && fm_session_pid_alive "$SESSION" \
    && [ "$(fm_session_pid_identity "$SESSION")" = "$SESSION_ID" ]
}
attended_owner || exit 0

if [ "$MODE" = check ]; then
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty')
  fm_supervision_needed "$STATE" "$GRACE" || exit 0
  age=$(fm_path_age "$STATE/.last-watcher-beat")
  fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME" && exit 0
  repair=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-supervision-instructions.sh" --harness claude --repair-line)
  message="[watcher-continuity] No verified watcher cycle (beacon age ${age}s; grace ${GRACE}s). $repair"
  if [ "$age" -ge "$GRACE" ] && [ -n "$CMD" ]; then
    verdict=$(printf '%s' "$CMD" | node "$SCRIPT_DIR/fm-fleet-command-policy.mjs" 2>/dev/null) || {
      case "$CMD" in *fm-spawn*|*fm-send*) verdict=deny ;; *) verdict=allow ;; esac
    }
    if [ "$verdict" != allow ]; then
      printf '%s\n' "$message New spawns and sends are refused until a fresh beat confirms recovery." >&2
      exit 2
    fi
  fi
  jq -cn --arg message "$message" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$message}}'
  exit 0
fi

# This long-lived lock belongs to this hook process, never to a tool call.
# The existing identity-bound lock primitive recovers dead/reused owners.
OWNER="$STATE/.claude-watch-guard.lock"
while ! fm_lock_try_acquire "$OWNER"; do
  [ "$(cat "$OWNER/session" 2>/dev/null)" != "$SESSION:$SESSION_ID" ] || exit 0
  attended_owner || exit 0
  sleep 1
done
printf '%s\n' "$SESSION:$SESSION_ID" > "$OWNER/session"
ARM=
OUT=
# shellcheck disable=SC2329 # EXIT trap
cleanup() {
  if [ -n "$ARM" ]; then
    kill -TERM "$ARM" 2>/dev/null || true
    wait "$ARM" 2>/dev/null || true
  fi
  [ -z "$OUT" ] || rm -f "$OUT"
  fm_lock_release "$OWNER"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
INTERVAL=5
if [ "${FM_TEST_SEAM:-}" = 1 ]; then INTERVAL=${FM_TEST_CLAUDE_WATCH_INTERVAL:-1}; fi
while attended_owner; do
  if [ -n "$ARM" ]; then
    if fm_pid_alive "$ARM"; then
      sleep "$INTERVAL"
      continue
    fi
    wait "$ARM" 2>/dev/null || true
    ARM=
    rm -f "$OUT"
    OUT=
  fi
  if fm_supervision_needed "$STATE" "$GRACE" \
    && ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME" \
    && ! fm_autoarm_claim_open "$STATE" "$GRACE"; then
    OUT=$(mktemp "$STATE/.claude-watch-guard.XXXXXX") || exit 1
    # One tracked child, reaped here. The arm owns singleton arbitration,
    # stale-holder recovery, beacon verification and durable wake publication.
    "$SCRIPT_DIR/fm-watch-arm.sh" > "$OUT" 2>&1 </dev/null &
    ARM=$!
  fi
  sleep "$INTERVAL"
done
