#!/usr/bin/env bash
# Live lab phase 2, after the simulated restart: fresh spawns handed a copy a
# dead task still records must refuse; then exit and relaunch of both tmux
# tasks whose windows went with the server (absence proof + rebind + claim).
set -u
. /home/tegris/.no-mistakes/evidence/01M3VZF72MYDKFSVPWF8SMTY11/lab-env.sh
cd "$WT" || exit 1

for id in lab-x lab-y; do
  step "fresh spawn $id after the restart (treehouse hands it a stale copy)"
  fm bin/fm-spawn.sh "$id" "$PROJ" --scout --harness claude --model haiku 2>&1 | tail -6
  echo "rc=${PIPESTATUS[0]}"
  ls "$LAB/state/$id.meta" 2>&1
  step "after $id: claims, windows, pool"
  claim
  labtmux list-windows -a -F '#{session_name}:#{window_name} #{pane_current_command} #{pane_current_path}'
  (cd "$PROJ" && TREEHOUSE_ROOT="$LAB/pool" treehouse status 2>&1 | grep -v -i 'new version\|treehouse update')
  git -C "$LAB/pool/.treehouse/demo-55bf35/1/demo" status --short --branch
done
step "recorded started server"
cat "$LAB/state/tmux-started-server"
tmuxprocs

step "fm-control lab-t1 exit (window went with the old server)"
fm bin/fm-control.sh lab-t1 exit 2>&1; echo "rc=$?"

for id in lab-t1 lab-t2; do
  step "fm-control $id relaunch (reclaim after restart)"
  before=$(grep '^window=' "$LAB/state/$id.meta")
  fm bin/fm-control.sh "$id" relaunch --note "Lab: your window went with a tmux restart; carry on." 2>&1 | tail -6
  echo "rc=${PIPESTATUS[0]}"
  echo "record before: $before"
  grep -E '^(window|worktree|endpoint_task_id)=' "$LAB/state/$id.meta"
done
step "after both reclaims: claims and windows"
claim
labtmux list-windows -a -F '#{session_name}:#{window_name} #{window_id} #{pane_current_command} #{pane_current_path}'
