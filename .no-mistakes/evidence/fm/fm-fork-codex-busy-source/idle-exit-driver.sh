#!/usr/bin/env bash
set -eu
export FM_HOME="$PWD/.l" TMPDIR="$PWD/.l/testtmp" TMUX_TMPDIR="$PWD/.l/tmux"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
socket=$(tmux -L fm-lab display-message -p -t primary '#{socket_path}')
export TMUX="$socket,0,0"
evidence=~/.no-mistakes/evidence/01M5EFYR8TJSF6027SV80VBGR7
for n in $(seq 1 120); do
 if grep -q 'state=idle source=codex-hook' "$FM_HOME/state/live.busy-state"; then break; fi
 sleep 0.25
done
grep -q 'state=idle source=codex-hook' "$FM_HOME/state/live.busy-state"
bin/fm-crew-state.sh live > "$evidence/crew-idle.txt"
bin/fm-bearings-snapshot.sh --json > "$evidence/bearings-idle.json" 2>> "$evidence/bearings-stderr.log"
bash ~/.codex/skills/activity/activity.sh > "$evidence/activity-idle.md" 2>> "$evidence/activity-stderr.log"
tmux -L fm-lab capture-pane -p -t primary > "$evidence/tui-idle.txt"
tmux -L fm-lab send-keys -t primary -l /quit
sleep 1.3
tmux -L fm-lab send-keys -t primary Enter
for n in $(seq 1 40); do
 if grep -q 'event=SessionEnd.' "$FM_HOME/state/live.busy-state"; then break; fi
 sleep 0.25
done
cat "$FM_HOME/state/live.busy-state" > "$evidence/tui-final-state.txt"
