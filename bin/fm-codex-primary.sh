#!/usr/bin/env bash
# Launch a Codex primary with a per-thread binding to this foreground client.
# The CLI's shell_environment_policy.set travels with the thread even when a
# shared managed app-server executes its tools. Its pid and birth let Firstmate
# verify the client is still live; its terminal variables override any stale
# pane or tmux identity inherited by that app-server.
# Usage: bin/fm-codex-primary.sh [ordinary codex CLI arguments]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME=$(cd -P -- "$FM_HOME" && pwd -P)

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
command -v codex >/dev/null 2>&1 || { echo 'error: codex is required' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 1; }

if [ "${HERDR_ENV:-}" = 1 ]; then
  [ -n "${HERDR_PANE_ID:-}" ] && [ -n "${HERDR_SOCKET_PATH:-}" ] || {
    echo 'error: incomplete Herdr pane identity at Codex launch' >&2
    exit 1
  }
  HERDR_SESSION=${HERDR_SESSION:-default}
fi

client_birth=$(fm_codex_pid_birth "$$") || {
  echo 'error: cannot identify the Codex launcher process birth' >&2
  exit 1
}
config_args=()
codex_set() {  # <name> <value>
  local encoded
  encoded=$(jq -Rn --arg value "$2" '$value') || return 1
  config_args+=(-c "shell_environment_policy.set.$1=$encoded")
}
codex_set FM_CODEX_CLIENT_PID "$$"
codex_set FM_CODEX_CLIENT_BIRTH "$client_birth"
codex_set FM_CODEX_CLIENT_HOME "$FM_HOME"
for name in TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH; do
  codex_set "$name" "${!name:-}"
done

# A nested launch must not inherit its parent's thread id. Codex supplies the
# new thread's own values to its tool commands.
unset CODEX_SESSION_ID CODEX_THREAD_ID FM_CODEX_CLIENT_PID FM_CODEX_CLIENT_BIRTH FM_CODEX_CLIENT_HOME
exec codex "${config_args[@]}" "$@"
