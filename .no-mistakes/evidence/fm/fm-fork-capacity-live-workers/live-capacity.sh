#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB=$PWD/.lc
E=~/.no-mistakes/evidence/01M5F4TP4RGP70Q9S4NR5X1TK2
export TMUX_TMPDIR=.lc/tmux
SOCK=$(tmux -L fm-lab display-message -p -t primary '#{socket_path}')
export TMUX="$SOCK,0,0" FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TEST_SEAM FM_GATE_REFUSE_BYPASS
printf '5 0\n' > "$LAB/config/lane-capacity"
mkdir -p "$LAB/empty" "$LAB/work"
for w in 0 1 2 3 4; do
  tmux -L fm-lab set-window-option -t "primary:$w" automatic-rename off
  tmux -L fm-lab rename-window -t "primary:$w" "fm-live-$((w+1))"
  tmux -L fm-lab send-keys -t "primary:$w" 3 Enter
done
sleep 2
for n in 1 2 3 4 5; do
  w=$((n-1))
  printf 'kind=ship\nbackend=tmux\nwindow=primary:%s\nworktree=%s\n' "fm-live-$n" "$LAB/empty" > "$LAB/state/live-$n.meta"
  tmux -L fm-lab capture-pane -p -t "primary:$w" > "$E/agent-$n.txt"
done
for n in 1 2; do printf 'kind=ship\nbackend=tmux\nwindow=primary:gone-%s\nworktree=%s\n' "$n" "$LAB/empty" > "$LAB/state/dead-$n.meta"; done
report() {
  echo "SCENARIO: $1"
  bash bin/fm-capacity.sh --json | tee "$E/$1.json"
  jq -e "$2" "$E/$1.json" >/dev/null
}
report five-live-two-dead '.lanes == 5 and .free_lanes == 0 and .reason == "full"'
rm "$LAB/state/live-5.meta"
report four-live-two-dead '.lanes == 4 and .free_lanes == 1 and .reason == "ok"'
printf 'kind=ship\nbackend=tmux\nwindow=unreadable\nworktree=%s\n' "$LAB/empty" > "$LAB/state/unknown.meta"
report unknown-retains-seat '.lanes == 5 and .reason == "full"'
rm "$LAB/state/unknown.meta"
printf 'kind=secondmate\nbackend=tmux\nwindow=primary:fm-live-5\n' > "$LAB/state/mate.meta"
printf 'kind=ship\nbackend=tmux\nwindow=primary:fm-live-5\npr=https://example.test/pull/1\n' > "$LAB/state/handoff.meta"
report exemptions '.lanes == 4 and .secondmates == 1 and .free_lanes == 1'
# Real shell with its cwd in a dead task's worktree.
tmux -L fm-lab new-window -d -t primary -n parked -c "$LAB/empty" bash
sleep 1
report shell-only '.lanes == 4 and .free_lanes == 1'
# A non-agent process is enough to hold a seat for an agent-free endpoint.
tmux -L fm-lab new-window -d -t primary -n pipeline -c "$LAB/work" 'sleep 300'
printf 'kind=ship\nbackend=tmux\nwindow=primary:gone-pipeline\nworktree=%s\n' "$LAB/work" > "$LAB/state/pipeline.meta"
report pipeline-retains-seat '.lanes == 5 and .reason == "full"'
mv "$LAB/config/lane-capacity" "$LAB/config/saved-capacity"
set +e
bash bin/fm-capacity.sh --admit
rc=$?
set -e
echo "missing-config admission exit=$rc"
[ "$rc" = 75 ]
mv "$LAB/config/saved-capacity" "$LAB/config/lane-capacity"
tmux -L fm-lab list-panes -a -F '#{session_name}:#{window_index} command=#{pane_current_command} grid=#{pane_width}x#{pane_height}'
