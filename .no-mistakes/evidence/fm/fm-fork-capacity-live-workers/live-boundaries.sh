#!/usr/bin/env bash
set -eu
LAB=$PWD/.lc
export TMUX_TMPDIR=.lc/tmux FM_HOME="$LAB"
SOCK=$(tmux -L fm-lab display-message -p -t primary '#{socket_path}')
export TMUX="$SOCK,0,0"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TEST_SEAM FM_GATE_REFUSE_BYPASS
mv "$LAB/state/capacity-b.meta" "$LAB/b.saved"
echo 'Stopped A alone releases its seat; B would be admitted:'
bash bin/fm-capacity.sh --admit
mv "$LAB/b.saved" "$LAB/state/capacity-b.meta"
echo 'B now occupies the seat:'
bash bin/fm-capacity.sh --json
printf '5 0\n' > "$LAB/config/lane-capacity"
printf 'kind=ship\nbackend=tmux\nwindow=primary:gone-invalid-worktree\nworktree=%s\n' "$LAB/nonexistent" > "$LAB/state/uncertain-cwd.meta"
echo 'Missing worktree evidence retains a seat:'
bash bin/fm-capacity.sh --json | tee "$LAB/check.json"
jq -e '.lanes == 2 and .free_lanes == 3' "$LAB/check.json"
echo 'Lab agent process inventory:'
tmux -L fm-lab list-panes -a -F '#{window_name} pane_pid=#{pane_pid} command=#{pane_current_command}'
echo 'Stopping private lab server:'
tmux -L fm-lab kill-server
if tmux -L fm-lab list-sessions 2>/dev/null; then exit 1; fi
echo 'Private server stopped. Removing disposable lab and targeted-test temporary directories.'
rm -rf "$LAB" "$PWD/.live-capacity-tmp"
git status --short
