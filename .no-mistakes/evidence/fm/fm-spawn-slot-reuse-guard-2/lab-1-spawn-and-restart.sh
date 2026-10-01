#!/usr/bin/env bash
# Live lab phase 1: two real scout spawns through real treehouse + real tmux +
# real claude, then a simulated machine restart (kill the lab tmux server), then
# a fresh spawn that treehouse hands one of the stale copies.
set -u
. /home/tegris/.no-mistakes/evidence/01M3VZF72MYDKFSVPWF8SMTY11/lab-env.sh
cd "$WT" || exit 1

step "precondition: no tmux process for this user"
tmuxprocs; echo "tmux processes: $(tmuxprocs | wc -l)"

for id in lab-t1 lab-t2; do
  step "fresh spawn $id (scout, claude haiku)"
  fm bin/fm-spawn.sh "$id" "$PROJ" --scout --harness claude --model haiku 2>&1 | tail -15
  echo "rc=${PIPESTATUS[0]}"
  grep -E '^(window|worktree|kind|spawn_gen|harness|backend)=' "$LAB/state/$id.meta"
done
step "claims and tmux after both spawns"
claim
labtmux list-windows -a -F '#{session_name}:#{window_name} #{pane_current_command} #{pane_current_path}'
cat "$LAB/state/tmux-started-server" 2>/dev/null

step "simulated restart: kill the lab tmux server"
labtmux kill-server
for _ in $(seq 1 50); do [ "$(tmuxprocs | wc -l)" = 0 ] && break; sleep 0.2; done
echo "tmux processes after restart: $(tmuxprocs | wc -l)"
(cd "$PROJ" && TREEHOUSE_ROOT="$LAB/pool" treehouse status 2>&1)
