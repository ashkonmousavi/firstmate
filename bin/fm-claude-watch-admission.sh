#!/usr/bin/env bash
# Shared admission for the guard-marked owning primary.
# Usage: fm-claude-watch-admission.sh admit|warn <code-root> <home> <state>

set -eu

fm_claude_watch_admission() {
  local mode=$1 root=$2 home=$3 state=$4 libdir=${BASH_SOURCE[0]%/*}
  local session identity marker age repair message
  [ -f "$state/.claude-watch-guard.lock/session" ] || return 0
  [ -z "${FM_TASK_ID:-}" ] || return 0
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$libdir/fm-primary-scope-lib.sh"
  fm_root_is_secondmate_home "$root" && return 0
  fm_root_is_secondmate_home "$home" && return 0
  fm_primary_scope_matches "$root" "$state" || return 0
  FM_ROOT=$root FM_HOME=$home STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$libdir/fm-wake-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$libdir/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$state" || return 0
  session=$FM_SESSION_LOCK_PID
  identity=$(fm_session_pid_identity "$session") || return 0
  marker=$(cat "$state/.claude-watch-guard.lock/session" 2>/dev/null) || return 0
  [ "$marker" = "$session:$identity" ] || return 0
  [ ! -e "$state/.afk" ] || return 0
  # shellcheck source=bin/fm-afk-contract.sh
  . "$libdir/fm-afk-contract.sh"
  fm_afk_contract_away_present "$state" && return 0
  age=$(fm_path_age "$state/.last-watcher-beat")
  if [ "$mode" = admit ]; then
    [ "$age" -gt 300 ] || return 0
  elif fm_watcher_healthy "$state" "$libdir/fm-watch.sh" 300 "$home"; then
    return 0
  fi
  repair=$(FM_HOME="$home" "$libdir/fm-supervision-instructions.sh" --harness claude --repair-line)
  message="[watcher-continuity] No verified watcher cycle (beacon age ${age}s; grace 300s). $repair"
  if [ "$mode" = warn ]; then
    printf '%s\n' "$message"
    return 0
  fi
  printf '%s\n' "$message New spawns and sends are refused until a fresh beat confirms recovery." >&2
  return 2
}

fm_claude_watch_admission "$@"
