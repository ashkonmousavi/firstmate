#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M68YZ3V3MCTBD3KN3E967737
export LAB_SESSION=fm-lab-dg LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh" ORIGINAL_PATH="$PATH"
export XDG_CONFIG_HOME=.x XDG_STATE_HOME="$ROOT/.doorbell-lab/xdg-state" XDG_CACHE_HOME="$ROOT/.doorbell-lab/cache" XDG_DATA_HOME="$ROOT/.doorbell-lab/data"
export FM_HERDR_LAB_STATE_DIR="$ROOT/.doorbell-lab/tripwire-local" TMPDIR="$ROOT/.doorbell-lab/tmp"
export TEST_ROOT="$ROOT/.doorbell-lab" TEST_EVIDENCE="$EVIDENCE"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
LAB="$ROOT/.doorbell-lab/home"
bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB" FM_TASK_INBOX="$LAB/state/doorbell.inbox"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
CLAUDE_PID= BACKGROUND=
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "$@"; }
cleanup() {
  status=$?
  trap - EXIT
  [ -z "$CLAUDE_PID" ] || kill -CONT "$CLAUDE_PID" 2>/dev/null || true
  [ -z "$BACKGROUND" ] || { kill "$BACKGROUND" 2>/dev/null || true; wait "$BACKGROUND" 2>/dev/null || true; }
  env PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$LAB_SESSION" || status=1
  printf 'TEARDOWN exit=%s\n' "$status"
  exit "$status"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$LAB_SESSION"
lab workspace create --cwd "$ROOT/.doorbell-lab" --label doorbell-proof --no-focus > "$TEST_ROOT/workspace.json"
PANE=$(jq -er '.result.root_pane.pane_id' "$TEST_ROOT/workspace.json")
export TARGET="$LAB_SESSION:$PANE"
printf -v launch 'set +m; env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME=%q FM_TASK_INBOX=%q CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 bash -c %q _ %q claude --dangerously-skip-permissions --setting-sources user --strict-mcp-config --mcp-config %q --settings %q --system-prompt %q' "$LAB" "$FM_TASK_INBOX" 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' "$TEST_ROOT/claude.pid" '{"mcpServers":{}}' '{"disableAllHooks":true,"feedbackDrafts":"off","autoMemoryEnabled":false}' 'You are an isolated doorbell verification worker. Only process explicitly supplied test requests. When told an instruction is waiting, read all *.msg files in FM_TASK_INBOX, carry out their specified local sentinel operations, move each message to handled/, then reply DONE. Never access other files, run fleet supervision, spawn agents, or use external services besides this conversation.'
lab pane run "$PANE" "$launch"
for ((i=0;i<90;i++)); do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  printf '%s\n' "$screen" > "$EVIDENCE/startup-pane.txt"
  case "$screen" in
    *'bypass permissions on'*) break;;
    *'Yes, I trust this folder'*) lab pane send-keys "$PANE" down enter >/dev/null;;
  esac
  sleep 1
done
[ "$i" -lt 90 ] || { echo 'FAIL Claude startup'; exit 1; }
CLAUDE_PID=$(cat "$TEST_ROOT/claude.pid")
export CLAUDE_PID
printf 'VERSIONS: '; herdr --version; claude --version
printf 'LAB session=%s pane=%s claude_pid=%s\n' "$LAB_SESSION" "$PANE" "$CLAUDE_PID"
export PATH="$TEST_ROOT/bin:$ORIGINAL_PATH"
. "$ROOT/bin/fm-task-inbox-lib.sh"
fm_backend_source herdr
ring() {
  local result=0
  fm_task_inbox_ring herdr "$TARGET" "$1" '' claude || result=$?
  printf 'RING %s rc=%s reason=%s\n' "${1##*/}" "$result" "$FM_TASK_INBOX_RING_REASON"
  printf '%s %s\n' "$result" "$FM_TASK_INBOX_RING_REASON" > "$TEST_ROOT/last-result"
}
wait_action() {
  local label=$1 rec=$2
  for ((j=0;j<180;j++)); do
    [ -f "$LAB/$label" ] && [ -f "${rec%/*}/handled/${rec##*/}" ] && break
    sleep 0.5
  done
  [ -f "$LAB/$label" ] && [ "$(cat "$LAB/$label")" = "$label" ] && [ -f "${rec%/*}/handled/${rec##*/}" ] || { echo "FAIL no sentinel/ack $label"; exit 1; }
  echo "ACTION $label sentinel=$(cat "$LAB/$label") acknowledgement=handled/${rec##*/}"
  for ((j=0;j<90;j++)); do
    st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in idle|done) break;; esac
    sleep 0.5
  done
  sleep 1
  lab pane read "$PANE" --source visible > "$EVIDENCE/$label-pane.txt"
  lab pane read "$PANE" --source visible --format ansi > "$EVIDENCE/$label-pane.ansi"
  cp "${rec%/*}/handled/${rec##*/}" "$EVIDENCE/$label-record.msg"
}
make_record() {
  fm_task_inbox_write "$LAB/state" doorbell "Use the Bash tool to run exactly: printf '%s' '$1' > '$LAB/$1'. Then move this .msg into handled/."
}
# Deliver a real prefix, hold the remaining input, then finish transport.
mkdir "$TEST_ROOT/prefix"
export FM_RENDER_MODE=prefix FM_RENDER_DIR="$TEST_ROOT/prefix"
rec=$(make_record partial-prefix)
(
  for ((k=0;k<300;k++)); do [ -f "$FM_RENDER_DIR/probe.ansi" ] && break; sleep 0.1; done
  [ -f "$FM_RENDER_DIR/probe.ansi" ] || exit 1
  sleep 1.5
  [ ! -e "$FM_RENDER_DIR/keys" ] || exit 1
  echo 'PREFIX_HOLD no_enter_before_remainder=true'
  lab pane send-text "$PANE" "$(cat "$FM_RENDER_DIR/remainder")" >/dev/null
) &
BACKGROUND=$!
ring "$rec"
wait "$BACKGROUND"; BACKGROUND=
[ "$(cat "$TEST_ROOT/last-result")" = '0 ok' ]
actual=$(FM_COMPOSER_GHOST_LUMA_MAX=0 fm_composer_extract_selected_content $'styled=1\ncursor=0\nidentity=0' "$(cat "$FM_RENDER_DIR/probe.ansi")")
[ -n "$actual" ]
[ "$actual" = ': Firstmate instruction waiting: list "$FM_TASK_INBOX"/*.msg' ]
printf 'PARTIAL_PROOF composer=%s\n' "$actual"
cp "$FM_RENDER_DIR/probe.ansi" "$EVIDENCE/partial-prefix-first-proof.ansi"
unset FM_RENDER_MODE FM_RENDER_DIR
wait_action partial-prefix "$rec"
echo PREFIX_LIVE_SCENARIO_PASSED
