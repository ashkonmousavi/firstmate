#!/usr/bin/env bash
set -eu
# Run from the gate worktree using the machine's existing authenticated harness.
E=~/.no-mistakes/evidence/01M623WEVE8Z0BJ53B6V14ECWW/round2
LAB=~/.no-mistakes/evidence/01M623WEVE8Z0BJ53B6V14ECWW/r2
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 140 -y 40 -c "$PWD" -e FM_HOME="$LAB" 'codex -c check_for_update_on_startup=false --disable hooks'
python3 "$E/live.py"
