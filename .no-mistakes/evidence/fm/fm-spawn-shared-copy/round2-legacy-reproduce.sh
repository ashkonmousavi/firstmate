#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6HHP6GWKMX7FZ0GRB6213RN
LAB=$ROOT/.g
cleanup() { TMUX_TMPDIR="$LAB/t" tmux -L fm-lab kill-server >/dev/null 2>&1 || true; sleep 0.5; rm -rf "$LAB"; }
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
printf '\n=== LEGACY INTERACTIVE COPY BEFORE PROTECTION ===\n'
tmux -L fm-lab new-window -t firstmate -n legacy -c "$LAB/project" 'treehouse get --no-fetch'
LEGACY=
for i in $(seq 1 60); do
  LEGACY=$(tmux -L fm-lab display-message -p -t firstmate:legacy '#{pane_current_path}')
  case "$LEGACY" in */.treehouse/*/1/project) break ;; esac
  sleep 0.2
done
[ -d "$LEGACY" ] && [ "$LEGACY" != "$LAB/project" ]
(cd "$LAB/project" && treehouse status --json) | tee "$LAB/legacy-before.json"
jq -e --arg path "$LEGACY" 'any(.[]; .path == $path and .status != "leased" and (.lease_id // "") == "")' "$LAB/legacy-before.json"
git -C "$LEGACY" checkout -qb fm/legacy
printf 'legacy retained work\n' > "$LEGACY/legacy.txt"
printf 'window=firstmate:legacy\nendpoint_task_id=legacy\nkind=scout\nworktree=%s\nproject=%s\nharness=sleep\nbranch=fm/legacy\n' "$LEGACY" "$LAB/project" > "$FM_HOME/state/legacy.meta"
printf 'held: legacy worker retained\n' > "$FM_HOME/state/legacy.status"
printf 'task=legacy\nhome=%s\n' "$FM_HOME" > "$(dirname "$LEGACY")/.fm-slot-owner"
brief alpha
"$ROOT/bin/fm-spawn.sh" alpha "$LAB/project" --scout --backend tmux --harness 'sleep 300'
printf '\n=== LEGACY COPY PROTECTED BY FIRSTMATE ===\n'
(cd "$LAB/project" && treehouse status --json) | tee "$LAB/legacy-after.json"
jq -e --arg path "$LEGACY" 'any(.[]; .path == $path and .status == "leased" and .lease_holder == "legacy")' "$LAB/legacy-after.json"
tmux -L fm-lab kill-window -t firstmate:legacy
[ "$(git -C "$LEGACY" symbolic-ref --short HEAD)" = fm/legacy ]
[ "$(cat "$LEGACY/legacy.txt")" = 'legacy retained work' ]
A=$(sed -n 's/^worktree=//p' "$FM_HOME/state/alpha.meta")
printf '\n=== FIRST SPAWN ===\n'
cat "$FM_HOME/state/alpha.meta"
(cd "$LAB/project" && treehouse status --json)
[ -d "$A" ]
git -C "$A" checkout -qb fm/alpha
printf 'retained edits\n' > "$A/retained.txt"
# Ending the whole interactive get shell must leave the durable slot untouched.
AW=$(sed -n 's/^window=//p' "$FM_HOME/state/alpha.meta")
tmux -L fm-lab kill-window -t "$AW"
printf 'done: worker and shell exited\n' > "$FM_HOME/state/alpha.status"
printf '\n=== AFTER ENDPOINT EXIT ===\n'
(cd "$LAB/project" && treehouse status --json)
[ "$(git -C "$A" symbolic-ref --short HEAD)" = fm/alpha ]
[ "$(cat "$A/retained.txt")" = 'retained edits' ]
brief beta
"$ROOT/bin/fm-spawn.sh" beta "$LAB/project" --scout --backend tmux --harness 'sleep 300'
B=$(sed -n 's/^worktree=//p' "$FM_HOME/state/beta.meta")
printf '\n=== SECOND SPAWN ===\nalpha=%s\nbeta=%s\n' "$A" "$B"
[ "$A" != "$B" ]
[ "$(git -C "$A" symbolic-ref --short HEAD)" = fm/alpha ]
[ "$(cat "$A/retained.txt")" = 'retained edits' ]
(cd "$LAB/project" && treehouse status --json)
printf '\n=== SAME-ID FRESH RETRY REFUSAL ===\n'
cp "$FM_HOME/state/alpha.meta" "$LAB/alpha.before"
rc=0
"$ROOT/bin/fm-spawn.sh" alpha "$LAB/project" --scout --backend tmux --harness 'sleep 300' > "$LAB/retry.out" 2>&1 || rc=$?
cat "$LAB/retry.out"
[ "$rc" -ne 0 ]
cmp "$FM_HOME/state/alpha.meta" "$LAB/alpha.before"
[ "$(cat "$A/retained.txt")" = 'retained edits' ]
printf '\nPASS: legacy process-only copy upgraded in place without branch/edit loss after shell exit; native interactive reservation became durable, survived shell exit, later allocation used a distinct copy, and fresh same-ID retry preserved ownership.\n'
