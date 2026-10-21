#!/usr/bin/env bash
set -eu
LAB=$PWD/.lc
export TMUX_TMPDIR=.lc/tmux
SOCK=$(tmux -L fm-lab display-message -p -t primary '#{socket_path}')
export TMUX="$SOCK,0,0" FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TEST_SEAM FM_GATE_REFUSE_BYPASS
# Persisted records are disposable input data; endpoints and CLI are real.
rm -f "$LAB/state/"*.meta
printf '1 0\n' > "$LAB/config/lane-capacity"
printf 'codex\n' > "$LAB/config/crew-harness"
mkdir -p "$LAB/project" "$LAB/data/capacity-a"
git -C "$LAB/project" init -q
git -C "$LAB/project" -c user.name=Lab -c user.email=lab@example.test commit -qm initial --allow-empty
git -C "$LAB/project" worktree add -qb fm/capacity-a "$LAB/wt-a"
printf 'Capacity test: preserve this stopped copy.\n' > "$LAB/data/capacity-a/brief.md"
tmux -L fm-lab new-window -d -t primary -n fm-capacity-a -c "$LAB/wt-a" bash
tmux -L fm-lab set-window-option -t primary:fm-capacity-a automatic-rename off
printf 'kind=ship\nbackend=tmux\nwindow=primary:fm-capacity-a\nworktree=%s\nproject=%s\nharness=codex\nmode=no-mistakes\nyolo=off\nbranch=fm/capacity-a\n' "$LAB/wt-a" "$LAB/project" > "$LAB/state/capacity-a.meta"
# B's endpoint is one of the real running Codex instances from the capacity walk.
printf 'kind=ship\nbackend=tmux\nwindow=primary:fm-live-1\nworktree=%s\n' "$LAB/empty" > "$LAB/state/capacity-b.meta"
cp "$LAB/state/capacity-a.meta" "$LAB/prior.meta"
echo 'Capacity before relaunch:'
bash bin/fm-capacity.sh --json
set +e
bin/fm-spawn.sh capacity-a --relaunch
rc=$?
set -e
echo "direct-relaunch exit=$rc"
[ "$rc" = 75 ]
cmp "$LAB/prior.meta" "$LAB/state/capacity-a.meta"
echo 'Direct refusal preserved stopped record.'
set +e
bin/fm-control.sh capacity-a relaunch --note 'Continue the preserved stopped task.'
rc=$?
set -e
echo "control-relaunch exit=$rc"
[ "$rc" = 75 ]
cmp "$LAB/prior.meta" "$LAB/state/capacity-a.meta"
echo 'Control refusal preserved stopped record.'
. bin/fm-backend.sh
printf 'A endpoint state after refusals: '
fm_backend_agent_state tmux primary:fm-capacity-a
printf '\n'
