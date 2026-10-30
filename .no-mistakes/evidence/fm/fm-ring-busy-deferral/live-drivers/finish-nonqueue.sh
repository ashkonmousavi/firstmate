#!/usr/bin/env bash
set -eu
export LAB_ROOT=$PWD
export LAB_EVIDENCE=~/.no-mistakes/evidence/01M66PJH65TPTKBMW5T925A2ZZ
export LAB_ORIGINAL_PATH=$PATH
export FM_HERDR_LAB_STATE_DIR="$PWD/.gate-live-lab/herdr-state"
export PATH="$PWD/.gate-live-lab:$PATH"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=3 FM_TASK_INBOX_BUSY_MAX=2
export FM_SSH_BIN="$PWD/.gate-live-lab/local-transport"
REMOTE="$PWD/.gate-live-lab/remote"
PARENT="$PWD/.gate-live-lab/parent"
PANE=w4:p1
rec="$REMOTE/state/parent-route/rsm.inbox/001.msg"
read -r ack_seq ack_gen < <(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([^ ]*\) --recovery-generation \([^ ]*\)$/\1 \2/p' "$LAB_EVIDENCE/nonqueue-live-proof.log")
env FM_HOME="$PARENT" "$LAB_ROOT/bin/fm-wake-drain.sh" --ack-through "$ack_seq" --recovery-generation "$ack_gen"
[ ! -s "$PARENT/state/.wake-queue" ]
for i in $(seq 1 200); do
  status=$(herdr agent get "$PANE" | jq -r '.result.agent.agent_status')
  case "$status" in idle|done) break ;; esac
  sleep 0.2
done
{ [ "$status" = idle ] || [ "$status" = done ]; }
printf 'Native Pi state before follow-up: %s\n' "$status"
"$PWD/bin/fm-busy-event.sh" apply "$REMOTE/state" rsm idle --current-gen --source pi-ext --event observed-live-idle
tick() { env FM_HOME="$PARENT" bash -c '. "$1/bin/fm-watch.sh"; remote_inbox_pass' _ "$LAB_ROOT"; }
tick
cat "${rec%/*}/.ring-state"
[ "$(cut -f2 "${rec%/*}/.ring-state")" = 1 ]
[ ! -e "${rec%/*}/.busy-state" ]
[ "$(cat "${rec%/*}/.escalated")" = 001.msg ]
tick
[ ! -s "$PARENT/state/.wake-queue" ]
[ "$(cut -f2 "${rec%/*}/.ring-state")" = 1 ]
for i in $(seq 1 100); do
  herdr pane read "$PANE" > "$LAB_EVIDENCE/pi-live-followup-received.txt"
  grep -q RECEIVED "$LAB_EVIDENCE/pi-live-followup-received.txt" && break
  sleep 0.2
done
grep -F RECEIVED "$LAB_EVIDENCE/pi-live-followup-received.txt"
printf 'PASS real busy-to-idle turn: no busy typing, one stuck-busy wake acknowledged, one idle doorbell received, no second wake\n'
