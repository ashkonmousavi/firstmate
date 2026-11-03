#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6HHP6GWKMX7FZ0GRB6213RN
LAB=$ROOT/.f
cleanup() { chmod u+w "$LAB/h/data" 2>/dev/null || true; TMUX_TMPDIR="$LAB/t" tmux -L fm-lab kill-server >/dev/null 2>&1 || true; sleep 0.5; rm -rf "$LAB"; }
trap cleanup EXIT
unset FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID FM_BACKEND HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH TMUX TMUX_PANE TASKS_AXI_FILE TASKS_AXI_BACKEND
. "$ROOT/tests/git-config-helpers.sh"
"$ROOT/bin/fm-lab-home.sh" create "$LAB/h"
export FM_HOME=$LAB/h HOME=$LAB/u TREEHOUSE_ROOT=$LAB/p SHELL=/bin/bash TMUX_TMPDIR=$LAB/t
export TREEHOUSE_NO_UPDATE_CHECK=1
if [ "${DEFAULT_POOL:-0}" = 1 ]; then unset TREEHOUSE_ROOT; fi
export XDG_CONFIG_HOME=$LAB/u/.config XDG_STATE_HOME=$LAB/u/.state XDG_CACHE_HOME=$LAB/u/.cache
export TMPDIR=$LAB/tmp
mkdir -p "$HOME" "$TMUX_TMPDIR" "$TMPDIR"

printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf '10 0\n' > "$FM_HOME/config/lane-capacity"
printf '{"schema":"fm-machine-admission.v1","memory_floor_gib":0,"memory_full_avg60_max":100,"disk_floor_gib":0,"disk_paths":["%s"]}\n' "$LAB" > "$FM_HOME/config/machine-admission.json"
touch "$FM_HOME/config/keep-ai-trailers"
git init -qb main "$LAB/project"
printf 'base\n' > "$LAB/project/README.md"
git -C "$LAB/project" add README.md
git -C "$LAB/project" -c user.name=Lab -c user.email=lab@example.invalid commit -qm initial
# Real product, real pool, real tmux. The raw command consumes no model tokens.
tmux -L fm-lab new-session -d -s firstmate -n control -x 120 -y 32 -c "$ROOT" 'bash --noprofile --norc'
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),0,0"
export TMUX_PANE=$(tmux -L fm-lab display-message -p '#{pane_id}')
brief() {
  mkdir -p "$FM_HOME/data/$1"
  printf "# Task\n## Captain's intent\nRetain this disposable copy until explicit cleanup.\n\n## Firstmate spec\nValidate copy ownership through the public CLI.\n" > "$FM_HOME/data/$1/brief.md"
}
brief failed
rm "$FM_HOME/config/backlog-backend"
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$FM_HOME/.tasks.toml"
printf '## In flight\n## Queued\n## Done\n' > "$FM_HOME/data/backlog.md"
tasks-axi add failed 'disposable launch rollback proof' --kind scout --file "$FM_HOME/data/backlog.md"
# Data remains readable for preflight; the real tasks consumer cannot commit.
chmod u-w "$FM_HOME/data"
rc=0
"$ROOT/bin/fm-spawn.sh" failed "$LAB/project" --scout --backend tmux --harness 'tmux kill-window' > "$LAB/failure.out" 2>&1 || rc=$?
chmod u+w "$FM_HOME/data"
cat "$LAB/failure.out"
printf 'spawn_exit=%s\n' "$rc"
[ "$rc" -ne 0 ]
grep -q 'failed-dispatch cleanup is incomplete' "$LAB/failure.out"
A=$(sed -n 's/^worktree=//p' "$FM_HOME/state/failed.meta")
[ -d "$A" ]
grep -q 'task=failed' "$(dirname "$A")/.fm-slot-owner"
! tmux -L fm-lab list-windows -t firstmate -F '#{window_name}' | grep -Fx fm-failed
(cd "$LAB/project" && treehouse status --json) | tee "$LAB/status.json"
jq -e --arg path "$A" 'any(.[]; .path == $path and .status == "leased" and .lease_holder == "failed")' "$LAB/status.json"
printf '\nRETAINED RECORD:\n'; cat "$FM_HOME/state/failed.meta"
printf '\nPASS: real backlog write failure after endpoint exit retained the durable lease, claim and task record.\n'
