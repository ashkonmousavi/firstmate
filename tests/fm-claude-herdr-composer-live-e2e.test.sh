#!/usr/bin/env bash
# Read-only guard for the Claude composer rendered in an existing Herdr pane.
# Select an idle Claude pane with FM_CLAUDE_HERDR_COMPOSER_TARGET=session:workspace:pane.
# No pane, server, or agent lifecycle operation is performed here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_HERDR_COMPOSER_LIVE herdr jq claude

target=${FM_CLAUDE_HERDR_COMPOSER_TARGET:-}
case "$target" in
  *:*) ;;
  *) fail "Claude Herdr composer guard needs FM_CLAUDE_HERDR_COMPOSER_TARGET=session:workspace:pane" ;;
esac
session=${target%%:*}
pane=${target#*:}
[ -n "$session" ] && [ -n "$pane" ] || fail "Claude Herdr composer target is incomplete"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

identity=$(herdr agent get "$pane" --session "$session" 2>/dev/null \
  | jq -r '(.result.agent.agent // "") + "\t" + (.result.agent.agent_status // "")') \
  || fail "Claude Herdr composer guard could not read native agent identity"
case "$identity" in
  $'claude\tidle'|$'claude\tdone') ;;
  *) fail "Claude Herdr composer guard needs a native idle Claude pane (got $identity)" ;;
esac
verdict=$(fm_backend_composer_state herdr "$target")
[ "$verdict" = empty ] \
  || fail "Claude Herdr composer guard expected empty, got $verdict (claude $(claude --version | head -1), $(herdr --version | head -1))"
pass "Claude Herdr idle composer classified empty on a real pane"
