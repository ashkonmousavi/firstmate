#!/usr/bin/env bash
set -eu
ROOT=$PWD
export FM_HERDR_LAB_STATE_DIR="$ROOT/.gate-live-lab/herdr-state"
SESSION=fm-lab-ring-gate
cleanup() {
  "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION"
}
trap cleanup EXIT
"$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION"
"$ROOT/bin/fm-herdr-lab.sh" provision "$SESSION"
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" workspace create --cwd "$ROOT" --label ring-gate --no-focus > "$ROOT/.gate-live-lab/workspace.json"
PANE=$(jq -er '.result.root_pane.pane_id' "$ROOT/.gate-live-lab/workspace.json")
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane run "$PANE" "pi --no-extensions --no-skills --no-tools --no-session --system-prompt 'You are a terminal delivery test. Reply RECEIVED to every message. Do not run tools.'" 
touch "$ROOT/.gate-live-lab/ready"
while [ ! -e "$ROOT/.gate-live-lab/stop" ]; do sleep 0.5; done
