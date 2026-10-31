#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
export XDG_CONFIG_HOME=.x XDG_STATE_HOME="$ROOT/.doorbell-lab/xdg-state" TMPDIR="$ROOT/.doorbell-lab/tmp"
export FM_HERDR_LAB_STATE_DIR="$ROOT/.doorbell-lab/tripwire-local"
export FM_HOME="$ROOT/.doorbell-lab/cli-home"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID
HELPER="$ROOT/bin/fm-herdr-lab.sh"
SESSION=fm-lab-dg
holder=
cleanup() {
  status=$?
  trap - EXIT
  : > "$FM_HOME/release"
  [ -z "$holder" ] || wait "$holder" || status=1
  "$HELPER" teardown "$SESSION" || status=1
  printf 'TEARDOWN exit=%s\n' "$status"
  exit "$status"
}
bin/fm-lab-home.sh create "$FM_HOME"
trap cleanup EXIT
"$HELPER" provision "$SESSION"
lab() { "$HELPER" run "$SESSION" "$@"; }
ws=$(lab workspace create --cwd "$ROOT/.doorbell-lab" --label doorbell-cli --no-focus)
pane=$(jq -er '.result.root_pane.pane_id' <<< "$ws")
workspace=$(jq -er '.result.workspace.workspace_id' <<< "$ws")
tab=$(lab pane get "$pane" | jq -er '.result.pane.tab_id')
printf 'window=%s\nendpoint_task_id=doorbell\nbackend=herdr\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\nharness=claude\nkind=ship\nworktree=%s\nproject=%s\n' "$SESSION:$pane" "$SESSION" "$workspace" "$tab" "$pane" "$ROOT/.doorbell-lab" "$ROOT/.doorbell-lab" > "$FM_HOME/state/doorbell.meta"
mkdir -p "$FM_HOME/state/doorbell.inbox"
bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_lock_try_acquire "$FM_HOME/state/doorbell.inbox/.ring.lock" || exit 1; : > "$FM_HOME/ready"; for ((i=0;i<300;i++)); do [ -f "$FM_HOME/release" ] && break; sleep 0.1; done; fm_lock_release "$FM_HOME/state/doorbell.inbox/.ring.lock"' _ "$ROOT" &
holder=$!
for ((i=0;i<100;i++)); do [ -f "$FM_HOME/ready" ] && break; sleep 0.1; done
[ -f "$FM_HOME/ready" ]
rc=0
bin/fm-send.sh doorbell --one-way 'CLI overlapping delivery verification; preserve this durable record.' > "$FM_HOME/send-output" 2>&1 || rc=$?
cat "$FM_HOME/send-output"
printf 'FM_SEND_EXIT=%s\n' "$rc"
[ "$rc" = 0 ]
rg -q 'another doorbell for this inbox is being delivered right now' "$FM_HOME/send-output"
[ -f "$FM_HOME/state/doorbell.inbox/001.msg" ]
[ "$(cat "$FM_HOME/state/doorbell.inbox/001.ring-reason")" = 'rc=1 token=ring-in-flight' ]
cat "$FM_HOME/state/doorbell.inbox/001.msg"
cat "$FM_HOME/state/doorbell.inbox/001.ring-reason"
lab pane read "$pane" --source visible > "$FM_HOME/pane"
! rg -q 'Firstmate instruction waiting|CLI overlapping delivery verification' "$FM_HOME/pane"
echo 'CLI_SKIP durable_record=true retry_notice=true no_terminal_send=true'
