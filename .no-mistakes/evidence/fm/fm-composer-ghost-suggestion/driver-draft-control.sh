#!/usr/bin/env bash
set -u
ROOT=$PWD
E=~/.no-mistakes/evidence/01M673MNWZ5DED50AB7RTVNT98
SOCKDIR=$(cat .phase-lab/home/state/.fm-lab-tmux-dir)
export TMUX_TMPDIR=$SOCKDIR
export TMUX=$(tmux -L fm-lab display-message -p -t primary '#{socket_path},#{pid},0')
export FM_HOME="$ROOT/.phase-lab/home"
tmux -L fm-lab rename-window -t primary:1 fm-draft
cat > "$FM_HOME/state/draft.meta" <<EOF
window=primary:fm-draft
endpoint_task_id=draft
worktree=$ROOT
project=$ROOT
harness=claude
kind=scout
backend=tmux
EOF
set +e
bin/fm-control.sh draft exit > "$E/draft-exit-refusal.log" 2>&1
rc=$?
set -e
printf 'Exit with real unsent draft returned %s\n' "$rc"
test "$rc" -ne 0
cat "$E/draft-exit-refusal.log"
tmux -L fm-lab capture-pane -p -t primary:fm-draft > "$E/draft-after-exit-refusal.txt"
tmux -L fm-lab send-keys -t primary:fm-draft C-u
printf '\n%s' 'Unsent draft spanning several terminal rows to prove real input remains pending in a narrow composer' | tmux -L fm-lab load-buffer -b draft -
tmux -L fm-lab paste-buffer -p -d -b draft -t primary:fm-draft
sleep 1
bash .phase-lab/capture-check.sh newline primary:fm-draft
