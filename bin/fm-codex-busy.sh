#!/usr/bin/env bash
# fm-codex-busy.sh - Codex global lifecycle hook and idempotent installer.
# Usage: fm-codex-busy.sh install [codex-home] | fm-codex-busy.sh < payload.json
# install merges only Firstmate's three handlers into hooks.json, preserving
# existing hooks and config.toml. The global command is inert without the
# FM_CODEX_BUSY_* launch binding. Events must have a cwd inside that worktree;
# the fixed launch gen, never --current-gen, fences superseded sessions.
# The existing busy-event writer owns all busy-record mutations. Hook mode
# always returns {} with exit 0, including ignored or stale events.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ "${1:-}" = install ]; then
  codex_home=${2:-${CODEX_HOME:-$HOME/.codex}}
  mkdir -p "$codex_home" || exit 1
  config=$codex_home/hooks.json
  [ ! -L "$config" ] || { echo 'error: Codex global hooks.json is a symlink; refusing to replace it' >&2; exit 1; }
  lock=$codex_home/.fm-busy-hooks.lock
  attempts=0
  until mkdir "$lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 100 ] || { echo 'error: Codex busy hook installation lock timeout' >&2; exit 1; }
    sleep 0.1
  done
  tmp=
  trap '[ -z "$tmp" ] || rm -f "$tmp"; rmdir "$lock"' EXIT
  # The executable comes from each launch, so one shared registration serves
  # multiple Firstmate homes without pinning a disposable checkout or scanning
  # other homes. No task binding means no side effects in ordinary sessions.
  # shellcheck disable=SC2016 # Expanded by the Codex hook process, not here.
  command='bash -c '\''if [ -n "${FM_CODEX_BUSY_HOOK:-}" ]; then bash "$FM_CODEX_BUSY_HOOK"; else printf "{}\n"; fi'\'''
  tmp=$(mktemp "$codex_home/.fm-busy-hooks.XXXXXX") || exit 1
  input=$config
  if [ -e "$config" ]; then
    cp -p "$config" "$tmp" || exit 1
  else
    input=/dev/null
  fi
  jq -s --arg command "$command" '
    (.[0] // {}) |
    reduce ["UserPromptSubmit", "Stop", "SessionEnd"][] as $event (. ;
      if any(.hooks[$event][]?.hooks[]?; .command == $command) then .
      else .hooks[$event] = ((.hooks[$event] // []) +
        [{hooks:[{type:"command",command:$command,timeout:3}]}]) end)
  ' "$input" > "$tmp" || exit 1
  if [ -e "$config" ] && cmp -s "$config" "$tmp"; then exit 0; fi
  mv "$tmp" "$config" || exit 1
  exit 0
fi

event() {
  local payload cwd worktree name state session record prior_event
  [ -n "${FM_CODEX_BUSY_WORKTREE:-}" ] && [ -n "${FM_CODEX_BUSY_STATE:-}" ] \
    && [ -n "${FM_CODEX_BUSY_ID:-}" ] && [ -n "${FM_CODEX_BUSY_GEN:-}" ] || return 0
  payload=$(cat) || return 0
  cwd=$(printf '%s' "$payload" | jq -er '.cwd | strings') || return 0
  name=$(printf '%s' "$payload" | jq -er '.hook_event_name | strings') || return 0
  session=$(printf '%s' "$payload" | jq -er '.session_id | strings') || return 0
  cwd=$(cd "$cwd" && pwd -P) || return 0
  worktree=$(cd "$FM_CODEX_BUSY_WORKTREE" && pwd -P) || return 0
  case "$cwd" in "$worktree"|"$worktree"/*) ;; *) return 0 ;; esac
  case "$name" in
    UserPromptSubmit) state=busy ;;
    Stop|SessionEnd) state=idle ;;
    *) return 0 ;;
  esac
  # Bind the first submitted session in the event token. A nested Codex review
  # inherits the launch environment and cwd but must never settle its parent.
  # shellcheck source=bin/fm-busy-lib.sh
  . "$SCRIPT_DIR/fm-busy-lib.sh"
  fm_busy_token_valid "$session" || return 0
  record=$(fm_busy_record_read "$FM_CODEX_BUSY_STATE" "$FM_CODEX_BUSY_ID") || return 0
  case "$record" in
    *' codex-hook '*)
      prior_event=${record#* codex-hook }
      prior_event=${prior_event%% *}
      [ "${prior_event#*.}" = "$session" ] || return 0
      ;;
    *) [ "$name" = UserPromptSubmit ] || return 0 ;;
  esac
  "$SCRIPT_DIR/fm-busy-event.sh" apply "$FM_CODEX_BUSY_STATE" "$FM_CODEX_BUSY_ID" \
    "$state" --gen "$FM_CODEX_BUSY_GEN" --source codex-hook --event "$name.$session" || true
}
event >/dev/null 2>&1
printf '{}\n'
