#!/usr/bin/env bash
set -eu
E=~/.no-mistakes/evidence/01M5FNVP5Q7E3546Y9CSQY9J3N
LAB=$(mktemp -d "$PWD/.lXXXXXX")
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
tmux() { command tmux -L fm-lab "$@"; }
cleanup() { tmux kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -x 120 -y 40 -s primary -c "$PWD" -e FM_HOME="$LAB" claude
sleep 4
tmux capture-pane -p -t primary > "$E/claude-start.txt"
cat "$E/claude-start.txt"
for ((i=0;i<35;i++)); do
 screen=$(tmux capture-pane -p -t primary)
 case "$screen" in
 *'Yes, I trust this folder'*) tmux send-keys -t primary Down Enter; sleep 2 ;;
 *'❯'*) break ;;
 esac
 sleep 1
done
tmux capture-pane -p -t primary > "$E/claude-ready.txt"
cat "$E/claude-ready.txt"
tmux send-keys -t primary -l /exit
sleep 2
tmux capture-pane -p -t primary > "$E/claude-popup.txt"
tmux capture-pane -e -p -t primary > "$E/claude-popup.ansi"
. bin/fm-tmux-lib.sh
screen=$(tmux capture-pane -e -p -t primary)
content=$(fm_composer_extract_selected_content $'styled=1\ncursor=0\nidentity=0\nrows=40' "$screen")
printf 'Real popup selected composer content: <%s>\n' "$content"
[ "$content" = /exit ]
tmux send-keys -t primary C-u
sleep 0.3
verdict=$(fm_tmux_submit_core primary /exit 3 0.4 1.2)
printf 'Product submit verdict: %s\n' "$verdict"
for ((i=0;i<20;i++)); do
 if ! tmux has-session -t primary 2>/dev/null; then printf 'Claude /exit terminated the lab session\n'; exit 0; fi
 sleep 1
done
tmux capture-pane -p -t primary > "$E/claude-after-exit.txt"
cat "$E/claude-after-exit.txt"
exit 1
