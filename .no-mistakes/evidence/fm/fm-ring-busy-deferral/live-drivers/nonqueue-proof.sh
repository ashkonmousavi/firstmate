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
. "$PWD/bin/fm-task-inbox-lib.sh"
herdr workspace create --cwd "$PWD" --label nonqueue-real --no-focus > "$PWD/.gate-live-lab/nonqueue-workspace.json"
PANE=$(jq -er '.result.root_pane.pane_id' "$PWD/.gate-live-lab/nonqueue-workspace.json")
herdr pane run "$PANE" "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$REMOTE' FM_TASK_INBOX='$REMOTE/state/parent-route/rsm.inbox' pi --no-extensions --no-skills --no-tools --no-session --provider openai-codex --model gpt-6.1-sol --thinking low --system-prompt 'This is a terminal test. Follow the user instruction. For any message starting with a Firstmate instruction waiting doorbell, reply RECEIVED only. Never run tools.'"
for i in $(seq 1 100); do
  status=$(herdr agent get "$PANE" | jq -r '.result.agent.agent_status')
  case "$status" in idle|done) break ;; esac
  sleep 0.2
done
{ [ "$status" = idle ] || [ "$status" = done ]; }
python3 - "$REMOTE/state/parent-route/rsm.meta" "$REMOTE/state/parent-route/rsm.inbox" "$PARENT/state/.wake-queue" <<'PY'
import sys,pathlib,shutil
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('w2:p1','w4:p1').replace('w2:t1','w4:t1').replace('herdr_workspace_id=w2','herdr_workspace_id=w4').replace('harness=claude','harness=pi'))
shutil.rmtree(sys.argv[2]);pathlib.Path(sys.argv[3]).unlink(missing_ok=True)
PY
rec=$(fm_task_inbox_write "$REMOTE/state/parent-route" rsm 'Reply RECEIVED only. Never run tools.')
herdr pane send-text "$PANE" 'Output 200 numbered lines with nonqueue acceptance test on each line. Never run tools.'
herdr pane send-keys "$PANE" enter
for i in $(seq 1 100); do
  status=$(herdr agent get "$PANE" | jq -r '.result.agent.agent_status')
  [ "$status" = working ] && break
  sleep 0.1
done
[ "$status" = working ]
printf 'Native Pi state before busy deferral: %s\n' "$status"
"$PWD/bin/fm-busy-event.sh" arm "$REMOTE/state" rsm --state busy --source pi-ext --event observed-live-turn >/dev/null
tick() { env FM_HOME="$PARENT" bash -c '. "$1/bin/fm-watch.sh"; remote_inbox_pass' _ "$LAB_ROOT"; }
tick
cat "${rec%/*}/.busy-state"
[ ! -e "${rec%/*}/.ring-state" ]
tick
cat "$PARENT/state/.wake-queue"
[ "$(wc -l < "$PARENT/state/.wake-queue")" = 1 ]
[ "$(cat "${rec%/*}/.escalated")" = 001.msg ]
[ ! -e "${rec%/*}/.ring-state" ]
herdr pane read "$PANE" > "$LAB_EVIDENCE/pi-busy-deferred.txt"
env FM_HOME="$PARENT" "$LAB_ROOT/bin/fm-wake-drain.sh" > "$LAB_EVIDENCE/drained-stuck-busy-wake.txt" 2>&1
read -r ack_seq ack_gen < <(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([^ ]*\) --recovery-generation \([^ ]*\)$/\1 \2/p' "$LAB_EVIDENCE/drained-stuck-busy-wake.txt")
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
printf 'PASS real busy-to-idle turn: no busy typing, one stuck-busy wake drained, one idle doorbell received, no second wake\n'
