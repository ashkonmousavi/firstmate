#!/usr/bin/env bash
# Run from this gate worktree. Requires installed codex, tmux, jq and python3.
# Current expected result is a Python assertion: zero conflict wakes after replacement exit.
set -eu
E=~/.no-mistakes/evidence/01M623WEVE8Z0BJ53B6V14ECWW
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
printf '%s\n' "$LAB" > "$E/lab-path.txt"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 140 -y 40 -c "$PWD" -e FM_HOME="$LAB" 'codex -c check_for_update_on_startup=false --disable hooks'
python3 "$E/reproduce-relaunch.py"
