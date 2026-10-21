#!/usr/bin/env bash
set -u
export FM_HOME="$PWD/.l" TMPDIR="$PWD/.l/testtmp"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export TMUX_TMPDIR="$FM_HOME/tmux"
socket=$(tmux -L fm-lab display-message -p -t primary '#{socket_path}')
export TMUX="$socket,0,0"
evidence=~/.no-mistakes/evidence/01M5EFYR8TJSF6027SV80VBGR7
for n in $(seq 1 80); do
 if grep -q 'state=busy source=codex-hook' "$FM_HOME/state/live.busy-state"; then break; fi
 sleep 0.25
done
tmux -L fm-lab capture-pane -p -t primary > "$evidence/tui-working.txt"
bin/fm-crew-state.sh live > "$evidence/crew-working.txt"
bin/fm-bearings-snapshot.sh --json > "$evidence/bearings-working.json" 2> "$evidence/bearings-stderr.log"
bash ~/.codex/skills/activity/activity.sh > "$evidence/activity-working.md" 2> "$evidence/activity-stderr.log"
