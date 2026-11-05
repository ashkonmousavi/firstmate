#!/usr/bin/env bash
# Live Claude background-shell exit guard, in live-harness-optin.
# Uses bash mode (!), not model prompts. A named Herdr lab owns every pane
# and lifecycle operation; the running default session is never addressed.
# Run after Claude/Herdr upgrades to refresh runtime-backends.md evidence.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CONTROL_CLAUDE_BUSY_LIVE claude herdr jq
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$HELPER" name control-busy)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-busy.XXXXXX")
VERSION=$(claude --version)
cleanup() {
  local rc=$? cleanup_rc=0
  trap - EXIT
  "$HELPER" teardown "$SESSION" || cleanup_rc=1
  rm -rf "$LAB"
  fm_test_cleanup
  [ "$cleanup_rc" = 0 ] || rc=1
  exit "$rc"
}
trap cleanup EXIT
"$HELPER" provision "$SESSION"
lab() { "$HELPER" run "$SESSION" "$@"; }
fail_live() { printf 'not ok - Claude %s on Herdr: %s\n' "$VERSION" "$1" >&2; exit 1; }
lab status --json > "$LAB/herdr-status.json"
printf '# harness: %s; transport: Herdr %s\n' "$VERSION" "$(jq -er '.server.version' "$LAB/herdr-status.json")"
PANE=$(lab workspace create --cwd "$LAB" --label busy-exit --no-focus | jq -er '.result.root_pane.pane_id')
# Disable hooks and project instructions; the lab needs no model turn.
printf -v launch 'env -u CLAUDECODE CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF=1 CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --setting-sources user --settings %q' \
  '{"disableAllHooks":true,"disableAgentView":true}'
lab pane run "$PANE" "$launch" >/dev/null
ready=0
for ((i=0; i<90; i++)); do
  shot=$(lab pane read "$PANE" --source visible)
  case "$shot" in
    *'Yes, I trust this folder'*) lab pane send-keys "$PANE" Up Enter >/dev/null ;;
    *'bypass permissions on'*) ready=1; break ;;
  esac
  sleep 1
done
[ "$ready" = 1 ] || fail_live 'composer did not become ready'
lab pane send-text "$PANE" '! sleep 120' >/dev/null
lab pane send-keys "$PANE" Enter >/dev/null
running=0
for ((i=0; i<30; i++)); do
  shot=$(lab pane read "$PANE" --source visible)
  case "$shot" in *'ctrl+b to run in background'*) running=1; break ;; esac
  sleep 1
done
[ "$running" = 1 ] || fail_live 'real shell did not start'
lab pane send-keys "$PANE" ctrl+b >/dev/null
lab pane send-text "$PANE" /exit >/dev/null
lab pane send-keys "$PANE" Enter >/dev/null
matched=0
for ((i=0; i<30; i++)); do
  shot=$(lab pane read "$PANE" --source visible)
  # A positive status count can render before the exit dialog. Wait for the
  # actual dialog as well, rather than failing on that valid earlier signal.
  if fm_control_background_shell_running claude "$shot" \
     && printf '%s\n' "$shot" | grep -F 'Background work is running' >/dev/null \
     && printf '%s\n' "$shot" | grep -F 'shell · sleep 120' >/dev/null; then
    matched=1
    break
  fi
  sleep 1
done
[ "$matched" = 1 ] || { printf '%s\n' "$shot" >&2; fail_live 'background-shell exit surface no longer recognized'; }
# Require a real exit dialog as well as the classifier, never a vacuous pass
# from a status count or a command that failed before starting its shell.
printf '%s\n' "$shot" | grep -F 'Background work is running' >/dev/null || fail_live 'exit dialog absent'
printf '%s\n' "$shot" | grep -F 'shell · sleep 120' >/dev/null || fail_live 'shell absent from exit dialog'
printf 'ok - Claude %s: real background-shell exit dialog recognized with no confirmation sent\n' "$VERSION"
