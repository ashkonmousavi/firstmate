#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$ROOT/.matecheck
SOCKET=$ROOT/.q
E=~/.no-mistakes/evidence/01M6HHP6GWKMX7FZ0GRB6213RN
cleanup() {
  TMUX_TMPDIR="$SOCKET/t" tmux -L fm-lab kill-server >/dev/null 2>&1 || true
  sleep 0.5
  python3 - "$LAB" "$SOCKET" <<'PY'
import pathlib,shutil,sys
for name in sys.argv[1:]:
 p=pathlib.Path(name)
 if p.exists(): shutil.rmtree(p)
PY
}
trap cleanup EXIT
[ ! -e "$LAB" ] && [ ! -e "$SOCKET" ]
mkdir -p "$LAB/code" "$SOCKET/t"
git archive HEAD | tar -x -C "$LAB/code"
. "$ROOT/tests/git-config-helpers.sh"
unset FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID FM_BACKEND HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH TMUX TMUX_PANE TASKS_AXI_FILE TASKS_AXI_BACKEND
"$LAB/code/bin/fm-lab-home.sh" create "$LAB/parent"
export FM_HOME=$LAB/parent HOME=$LAB/user SHELL=/bin/bash TMUX_TMPDIR=$SOCKET/t
export XDG_CONFIG_HOME=$HOME/.config XDG_STATE_HOME=$HOME/.state XDG_CACHE_HOME=$HOME/.cache TMPDIR=$LAB/tmp
mkdir -p "$HOME" "$TMPDIR" "$LAB/mate/bin" "$LAB/mate/data" "$LAB/mate/state" "$LAB/mate/config" "$LAB/mate/projects"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf '10 0\n' > "$FM_HOME/config/lane-capacity"
printf '{"schema":"fm-machine-admission.v1","memory_floor_gib":0,"memory_full_avg60_max":100,"disk_floor_gib":0,"disk_paths":["%s"]}\n' "$LAB" > "$FM_HOME/config/machine-admission.json"
touch "$FM_HOME/config/keep-ai-trailers"
printf 'retained\n' > "$LAB/mate/.fm-secondmate-home"
printf '# Firstmate\n' > "$LAB/mate/AGENTS.md"
printf 'Retain the existing isolated home.\n' > "$LAB/mate/data/charter.md"
printf 'Retained secondmate notes must survive recovery.\n' > "$LAB/mate/notes.txt"
printf 'projects/\nstate/\ndata/\nconfig/\n.no-mistakes/\n' > "$LAB/mate/.gitignore"
git -C "$LAB/mate" init -qb main
printf 'window=firstmate:fm-retained\nkind=secondmate\nharness=sleep\nbackend=tmux\nhome=%s\nworktree=%s\n' "$LAB/mate" "$LAB/mate" > "$FM_HOME/state/retained.meta"
cp "$LAB/mate/notes.txt" "$LAB/notes.before"
tmux -L fm-lab new-session -d -s firstmate -n control -x 120 -y 32 -c "$ROOT" 'bash --noprofile --norc'
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),0,0"
export TMUX_PANE=$(tmux -L fm-lab display-message -p '#{pane_id}')
printf 'BEFORE: retained home=%s; recorded endpoint is absent\n' "$LAB/mate"
! tmux -L fm-lab list-windows -t firstmate -F '#{window_name}' | grep -Fx fm-retained
"$LAB/code/bin/fm-spawn.sh" retained --secondmate --backend tmux --harness 'sleep 30'
printf '\nAFTER: public spawn returned success\n'
cat "$FM_HOME/state/retained.meta"
W=$(sed -n 's/^window=//p' "$FM_HOME/state/retained.meta")
for i in $(seq 1 30); do
 CMD=$(tmux -L fm-lab display-message -p -t "$W" '#{pane_current_command}')
 [ "$CMD" != sleep ] || break
 sleep 0.2
done
printf 'REAL ENDPOINT: '; tmux -L fm-lab display-message -p -t "$W" '#{session_name}:#{window_name} command=#{pane_current_command} cwd=#{pane_current_path} size=#{pane_width}x#{pane_height}'
printf '\nPANE TRANSCRIPT:\n'; tmux -L fm-lab capture-pane -p -t "$W" -S -35
[ "$CMD" = sleep ]
[ "$(sed -n 's/^worktree=//p' "$FM_HOME/state/retained.meta")" = "$LAB/mate" ]
[ "$(sed -n 's/^home=//p' "$FM_HOME/state/retained.meta")" = "$LAB/mate" ]
cmp "$LAB/notes.before" "$LAB/mate/notes.txt"
printf '\nPASS: real secondmate respawn reused recorded home and preserved notes; real sleep process started on private tmux.\n'
