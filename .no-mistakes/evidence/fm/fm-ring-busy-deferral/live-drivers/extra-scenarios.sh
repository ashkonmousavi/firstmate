#!/usr/bin/env bash
set -eu
export LAB_ROOT=$PWD
export LAB_EVIDENCE=~/.no-mistakes/evidence/01M66PJH65TPTKBMW5T925A2ZZ
export LAB_ORIGINAL_PATH=$PATH
export FM_HERDR_LAB_STATE_DIR="$PWD/.gate-live-lab/herdr-state"
export PATH="$PWD/.gate-live-lab:$PATH"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_BUSY_MAX=2 FM_TASK_INBOX_RING_MAX=3
export FM_SSH_BIN="$PWD/.gate-live-lab/local-transport"
BASE="$PWD/.gate-live-lab"
REMOTE="$BASE/remote"
PARENT="$BASE/parent"
. "$PWD/bin/fm-task-inbox-lib.sh"
printf '\nSCENARIO local log only after durable below-bound deferral\n'
LOCAL="$BASE/local"
"$PWD/bin/fm-lab-home.sh" create "$LOCAL"
cat > "$LOCAL/state/rsm.meta" <<EOF
window=fm-lab-ring-gate:w3:p1
worktree=-
project=-
backend=herdr
endpoint_task_id=rsm
harness=pi
herdr_session=fm-lab-ring-gate
herdr_workspace_id=w3
herdr_tab_id=w3:t1
herdr_pane_id=w3:p1
EOF
rec=$(fm_task_inbox_write "$LOCAL/state" rsm 'Reply RECEIVED only. Do not run tools.')
"$LAB_ROOT/bin/fm-busy-event.sh" arm "$LOCAL/state" rsm --state busy --source pi-ext --event lab-lifecycle >/dev/null
local_tick() { env FM_HOME="$LOCAL" bash -c '. "$1/bin/fm-watch.sh"; inbox_steer_check fm-lab-ring-gate:w3:p1 rsm' _ "$LAB_ROOT"; }
local_tick
[ "$(cut -f2 "${rec%/*}/.busy-state")" = 1 ]
grep 'steer-inbox busy deferral: rsm 001.msg count=1/2$' "$LOCAL/state/.watch-triage.log"
local_tick
local_tick
[ "$(grep -c 'steer-inbox busy deferral:' "$LOCAL/state/.watch-triage.log")" = 1 ]
[ "$(wc -l < "$LOCAL/state/.wake-queue")" = 1 ]
cat "$LOCAL/state/.wake-queue"
"$LAB_ROOT/bin/fm-busy-event.sh" apply "$LOCAL/state" rsm idle --current-gen --source pi-ext --event lab-idle
local_tick
[ "$(cut -f2 "${rec%/*}/.ring-state")" = 1 ]
[ "$(grep -c 'steer-inbox busy deferral:' "$LOCAL/state/.watch-triage.log")" = 1 ]
printf 'PASS local below-bound log once, absent at bound and subsequent polls; idle follow-up rung\n'
# A failed durable write must never advertise a successful deferral.
mv "$rec" "${rec%/*}/handled/"
rec=$(fm_task_inbox_write "$LOCAL/state" rsm 'Do not act; bookkeeping failure fixture.')
mkdir "${rec%/*}/.busy-state"
"$LAB_ROOT/bin/fm-busy-event.sh" apply "$LOCAL/state" rsm busy --current-gen --source pi-ext --event lab-busy
local_tick
[ "$(grep -c 'steer-inbox busy deferral:' "$LOCAL/state/.watch-triage.log")" = 1 ]
cat "$LOCAL/state/.wake-queue"
printf 'PASS no deferral log when busy bookkeeping fails\n'

printf '\nSCENARIO busy Claude queue harness receives doorbell\n'
python3 - "$REMOTE/state/parent-route/rsm.inbox" "$PARENT/state/.wake-queue" <<'PY'
import shutil,sys,pathlib
shutil.rmtree(sys.argv[1]);pathlib.Path(sys.argv[2]).unlink(missing_ok=True)
PY
python3 - "$REMOTE/state/parent-route/rsm.meta" <<'PY'
import sys,pathlib
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('w3:p1','w2:p1').replace('w3:t1','w2:t1').replace('herdr_workspace_id=w3','herdr_workspace_id=w2').replace('harness=pi','harness=claude'))
PY
rec=$(fm_task_inbox_write "$REMOTE/state/parent-route" rsm 'Reply RECEIVED only. Do not run tools.')
"$LAB_ROOT/bin/fm-busy-event.sh" arm "$REMOTE/state" rsm --state busy --source claude-hook --event lab-lifecycle >/dev/null
FM_HOME="$REMOTE" "$LAB_ROOT/bin/fm-remote-secondmate-control.sh" inbox rsm ring 001.msg 2
[ "$(cut -f2 "${rec%/*}/.ring-state")" = 1 ]
[ ! -e "${rec%/*}/.busy-state" ]
cat "${rec%/*}/.ring-state"
printf 'PASS busy Claude is rung and spends one ring attempt without busy debt\n'

printf '\nSCENARIO new parent retries due without capability against base-version remote\n'
python3 - "$REMOTE/state/parent-route/rsm.inbox" <<'PY'
import shutil,sys
shutil.rmtree(sys.argv[1])
PY
python3 - "$REMOTE/state/parent-route/rsm.meta" <<'PY'
import sys,pathlib
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('w2:p1','w3:p1').replace('w2:t1','w3:t1').replace('herdr_workspace_id=w2','herdr_workspace_id=w3').replace('harness=claude','harness=pi'))
PY
rec=$(fm_task_inbox_write "$REMOTE/state/parent-route" rsm 'Reply RECEIVED only. Do not run tools.')
"$LAB_ROOT/bin/fm-busy-event.sh" arm "$REMOTE/state" rsm --state busy --source pi-ext --event lab-lifecycle >/dev/null
mkdir -p "$BASE/old-bin"
for f in "$LAB_ROOT"/bin/*; do ln -s "$f" "$BASE/old-bin/${f##*/}"; done
python3 - "$BASE/old-bin/fm-remote-secondmate-control.sh" <<'PY'
import pathlib,sys
pathlib.Path(sys.argv[1]).unlink()
PY
git show 1f6bb65ded559e42a4a9feeeac35ee0572dd8f19:bin/fm-remote-secondmate-control.sh > "$BASE/old-bin/fm-remote-secondmate-control.sh"
chmod +x "$BASE/old-bin/fm-remote-secondmate-control.sh"
export LAB_REMOTE_CONTROL="$BASE/old-bin/fm-remote-secondmate-control.sh"
env FM_HOME="$PARENT" bash -c '. "$1/bin/fm-watch.sh"; remote_inbox_pass' _ "$LAB_ROOT"
[ "$(cut -f2 "${rec%/*}/.ring-state")" = 1 ]
[ ! -e "${rec%/*}/.busy-state" ]
cat "${rec%/*}/.ring-state"
printf 'PASS old remote refuses capability; new parent retries legacy due and rings busy pane\n'
