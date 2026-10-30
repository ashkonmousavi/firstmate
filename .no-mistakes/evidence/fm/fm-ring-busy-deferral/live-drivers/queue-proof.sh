#!/usr/bin/env bash
set -eu
export LAB_ROOT=$PWD
export LAB_EVIDENCE=~/.no-mistakes/evidence/01M66PJH65TPTKBMW5T925A2ZZ
export LAB_ORIGINAL_PATH=$PATH
export FM_HERDR_LAB_STATE_DIR="$PWD/.gate-live-lab/herdr-state"
export PATH="$PWD/.gate-live-lab:$PATH"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
REMOTE="$PWD/.gate-live-lab/remote"
. "$PWD/bin/fm-task-inbox-lib.sh"
python3 - "$REMOTE/state/parent-route/rsm.meta" "$REMOTE/state/parent-route/rsm.inbox" <<'PY'
import sys,pathlib,shutil
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('w3:p1','w2:p1').replace('w3:t1','w2:t1').replace('herdr_workspace_id=w3','herdr_workspace_id=w2').replace('harness=pi','harness=claude'))
shutil.rmtree(sys.argv[2])
PY
rec=$(fm_task_inbox_write "$REMOTE/state/parent-route" rsm 'Reply RECEIVED only. Never run tools.')
herdr pane send-text w2:p1 'For this terminal test only, output 120 numbered lines containing queue acceptance test on each line. Never run tools.'
herdr pane send-keys w2:p1 enter
found=0
for i in $(seq 1 80); do
  status=$(herdr agent get w2:p1 | jq -r '.result.agent.agent_status')
  if [ "$status" = working ]; then found=1; break; fi
  sleep 0.1
done
[ "$found" = 1 ]
printf 'Real Claude native lifecycle before delivery: %s\n' "$status"
"$PWD/bin/fm-busy-event.sh" arm "$REMOTE/state" rsm --state busy --source claude-hook --event live-claude-turn >/dev/null
out=$(FM_HOME="$REMOTE" "$PWD/bin/fm-remote-secondmate-control.sh" inbox rsm ring 001.msg 2)
printf 'Remote ring result: %s\n' "$out"
case "$out" in 'rang 0'*) ;; *) exit 1 ;; esac
[ "$(cut -f2 "${rec%/*}/.ring-state")" = 1 ]
[ ! -e "${rec%/*}/.busy-state" ]
herdr pane read w2:p1 > "$LAB_EVIDENCE/claude-queue-in-flight.txt"
for i in $(seq 1 100); do
  status=$(herdr agent get w2:p1 | jq -r '.result.agent.agent_status')
  [ "$status" != working ] && break
  sleep 0.3
done
herdr pane read w2:p1 --lines 400 > "$LAB_EVIDENCE/claude-queue-received.txt"
grep -F 'Firstmate instruction waiting:' "$LAB_EVIDENCE/claude-queue-received.txt"
grep -F 'RECEIVED' "$LAB_EVIDENCE/claude-queue-received.txt"
printf 'PASS a genuinely working Claude turn accepts the queued doorbell; ring budget=1, no busy debt\n'
