#!/usr/bin/env bash
set -eu
export LAB_ROOT=$PWD
export LAB_EVIDENCE=~/.no-mistakes/evidence/01M66PJH65TPTKBMW5T925A2ZZ
export LAB_ORIGINAL_PATH=$PATH
export FM_HERDR_LAB_STATE_DIR="$PWD/.gate-live-lab/herdr-state"
export PATH="$PWD/.gate-live-lab:$PATH"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
BASE="$PWD/.gate-live-lab"
REMOTE="$BASE/remote"
PARENT="$BASE/parent"
for H in "$REMOTE" "$PARENT"; do "$PWD/bin/fm-lab-home.sh" create "$H"; done
mkdir -p "$REMOTE/state/parent-route"
ln -s "$PWD/bin" "$REMOTE/bin"
ln -s "$PWD/AGENTS.md" "$REMOTE/AGENTS.md"
printf 'rsm\n' > "$REMOTE/.fm-secondmate-home"
cat > "$REMOTE/state/parent-route/rsm.meta" <<EOF
window=fm-remote:w3:p1
worktree=-
project=-
backend=herdr
endpoint_task_id=rsm
harness=pi
herdr_session=fm-remote
herdr_workspace_id=w3
herdr_tab_id=w3:t1
herdr_pane_id=w3:p1
EOF
cat > "$PARENT/state/rsm.meta" <<EOF
window=fm-remote:w3:p1
endpoint_task_id=rsm
harness=pi
kind=secondmate
mode=secondmate
remote_host=disposable-lab
remote_root=$PWD
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w3:p1
EOF
printf -- '- rsm - lab (host: disposable-lab; root: %s; home: %s; scope: testing; projects: alpha; added 2026-10-30)\n' "$PWD" "$REMOTE" > "$PARENT/data/secondmates.md"
export FM_SSH_BIN="$BASE/local-transport"
export FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=3 FM_TASK_INBOX_BUSY_MAX=2
. "$PWD/bin/fm-task-inbox-lib.sh"
reset_case() {
  rm -rf "$REMOTE/state/parent-route/rsm.inbox" "$PARENT/state/.wake-queue" "$PARENT/state/.watch-triage.log"
  rec=$(fm_task_inbox_write "$REMOTE/state/parent-route" rsm 'Reply RECEIVED only. Do not run tools.')
}
busy() {
  "$LAB_ROOT/bin/fm-busy-event.sh" arm "$REMOTE/state" rsm --state "$1" --source pi-ext --event lab-lifecycle >/dev/null
}
tick() {
  env FM_HOME="$PARENT" bash -c '. "$1/bin/fm-watch.sh"; remote_inbox_pass' _ "$LAB_ROOT"
}
remote() { FM_HOME="$REMOTE" "$LAB_ROOT/bin/fm-remote-secondmate-control.sh" inbox rsm "$@"; }
state() {
  for file in "$REMOTE/state/parent-route/rsm.inbox"/.*state "$REMOTE/state/parent-route/rsm.inbox/.escalated" "$PARENT/state/.watch-triage.log" "$PARENT/state/.wake-queue"; do
    [ ! -f "$file" ] || { printf '%s: ' "${file#$BASE/}"; cat "$file"; }
  done
}
printf '\nSCENARIO busy below bound then one stuck-busy wake then idle ring\n'
reset_case; busy busy
# Contradictory parent-route state rejects the wrong-state-directory bug.
"$LAB_ROOT/bin/fm-busy-event.sh" arm "$REMOTE/state/parent-route" rsm --state idle --source pi-ext --event wrong-directory >/dev/null
tick; state
[ ! -e "${rec%/*}/.ring-state" ]
[ "$(cut -f2 "${rec%/*}/.busy-state")" = 1 ]
[ ! -s "$PARENT/state/.wake-queue" ]
tick; state
[ "$(cat "${rec%/*}/.escalated")" = 001.msg ]
[ "$(wc -l < "$PARENT/state/.wake-queue")" = 1 ]
tick
[ "$(wc -l < "$PARENT/state/.wake-queue")" = 1 ]
[ "$(remote ring 001.msg 2)" = 'deferred 0' ]
[ ! -e "${rec%/*}/.ring-state" ]
busy idle
tick; state
[ "$(cut -f2 "${rec%/*}/.ring-state")" = 1 ]
[ ! -e "${rec%/*}/.busy-state" ]
[ "$(cat "${rec%/*}/.escalated")" = 001.msg ]
[ "$(wc -l < "$PARENT/state/.wake-queue")" = 1 ]
tick
[ "$(cut -f2 "${rec%/*}/.ring-state")" = 1 ]
herdr pane read w3:p1 > "$LAB_EVIDENCE/pi-idle-followup.txt"
printf 'PASS busy deferral, own-home classification, single wake, busy follow-up, single idle ring\n'

printf '\nSCENARIO idle before busy bound rings once\n'
reset_case; busy busy; tick; busy idle; tick; state
[ "$(cut -f2 "${rec%/*}/.ring-state")" = 1 ]
[ ! -e "${rec%/*}/.busy-state" ]
[ ! -s "$PARENT/state/.wake-queue" ]
printf 'PASS idle before busy bound\n'

printf '\nSCENARIO old parent omits capability and still rings busy worker\n'
reset_case; busy busy
[ "$(remote due 0 3)" = 'ring 001.msg' ]
remote ring 001.msg
state
[ "$(cut -f2 "${rec%/*}/.ring-state")" = 1 ]
[ ! -e "${rec%/*}/.busy-state" ]
printf 'PASS old parent rings busy worker\n'
