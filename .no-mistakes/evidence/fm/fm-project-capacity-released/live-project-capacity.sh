#!/usr/bin/env bash
# Reproduce against the real capacity/spawn entrypoints and a private tmux server.
# Oracle: released+agent-free records hold zero places; live/unknown and
# ordinary uncleaned records retain a place (author's intent and lane contract).
set -euo pipefail
ROOT=$1
EVIDENCE=$2
cd "$ROOT"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_CAPACITY_MEMINFO FM_RESOURCE_CGROUP_FILE FM_CAPACITY_PRESSURE_FILE TASKS_AXI_FILE TASKS_AXI_BACKEND
LAB="$ROOT/.lab"
[ ! -e "$LAB" ]
mkdir "$LAB"
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf -- "$LAB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
export FM_HOME="$LAB" FM_BACKEND=tmux TMUX_TMPDIR="$LAB/tmux"
# A genuine CLI, no prompt, credential changes, fake executable or fake login.
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab -f /dev/null new-session -d -s primary -n codex-live -x 100 -y 30 -c "$ROOT" -e FM_HOME="$LAB" codex
export TMUX
TMUX=$(tmux -L fm-lab display-message -p -t primary '#{socket_path},#{pid},0')
tmux -L fm-lab new-window -d -t primary -n dead -c "$LAB" 'bash --noprofile --norc'
tmux -L fm-lab new-window -d -t primary -n uncertain -c "$LAB" 'sleep 300'
. tests/git-config-helpers.sh
git init -q "$LAB/project"
git -C "$LAB/project" -c user.name=CapacityLab -c user.email=lab@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m initial
printf '20 0\n' > "$LAB/config/lane-capacity"
printf 'project 1\n' > "$LAB/config/project-capacity"
printf 'codex\n' > "$LAB/config/crew-harness"
python3 - "$LAB" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
(p/'config/machine-admission.json').write_text(json.dumps({'schema':'fm-machine-admission.v1','memory_floor_gib':0,'memory_full_avg60_max':100,'disk_floor_gib':0,'disk_paths':[str(p)]})+'\n')
PY
. bin/fm-wake-lib.sh
. bin/fm-backend.sh
. bin/fm-secondmate-registry-lib.sh
. bin/fm-project-capacity-lib.sh
STATE="$LAB/state"
CONFIG="$LAB/config"
PROJECT="$LAB/project"
LOCK=$(fm_treehouse_project_lock_path "$PROJECT")
write_record() {
  local id=$1 target=$2 worktree=$3
  printf 'kind=ship\nbackend=tmux\nwindow=%s\nworktree=%s\nproject=%s\nharness=codex\nmode=local-only\n' "$target" "$worktree" "$PROJECT" > "$STATE/$id.meta"
}
check_count() {
  local label=$1 expected=$2
  fm_project_capacity_occupants "$LOCK" "$PROJECT" "$STATE" new-task
  printf '%s: project_places=%s holders=[%s]\n' "$label" "$FM_PROJECT_CAPACITY_OCCUPANTS" "$FM_PROJECT_CAPACITY_OCCUPANT_IDS"
  [ "$FM_PROJECT_CAPACITY_OCCUPANTS" -eq "$expected" ]
}
check_spawn() {
  local expected=$1 label=$2 rc=0 out
  # No brief intentionally: accepted capacity stops at subsequent brief
  # validation, so this public-CLI probe never launches another worker.
  out=$(bin/fm-spawn.sh probe "$PROJECT" --mode local-only --yolo off 2>&1) || rc=$?
  printf '%s: exit=%s\n%s\n' "$label" "$rc" "$out"
  if [ "$expected" = defer ]; then
    [ "$rc" -eq 75 ]
    [[ "$out" = *'deferred: project project admits 1 worker(s)'* ]]
  else
    [ "$rc" -eq 1 ]
    [[ "$out" = *'no brief at inaccessible data path'* ]]
    [[ "$out" != *'deferred:'* ]]
  fi
  [ ! -e "$STATE/probe.meta" ]
  [ ! -e "$LAB/data/probe/launch-brief.md" ]
}
for n in 1 2 3; do write_record "released-$n" primary:missing "$STATE/released-$n.released-copy"; done
for n in 4 5; do write_record "released-$n" primary:dead "$STATE/released-$n.released-copy"; done
printf 'Endpoint proofs: absent=%s shell=%s other=%s\n' "$(fm_backend_agent_state tmux primary:missing)" "$(fm_backend_agent_state tmux primary:dead)" "$(fm_backend_agent_state tmux primary:uncertain)"
[ "$(fm_backend_agent_state tmux primary:missing)" = missing ]
[ "$(fm_backend_agent_state tmux primary:dead)" = dead ]
[ "$(fm_backend_agent_state tmux primary:uncertain)" = ambiguous ]
# Baseline implementation against identical real metadata and endpoints.
git show 5530c4c908ecb261eeb6d97df91b672ef7540a30:bin/fm-project-capacity-lib.sh > "$LAB/base-lib.sh"
( . "$LAB/base-lib.sh"; check_count 'Before fix, five exited released records' 5 )
check_count 'After fix, five exited released records' 0
bin/fm-capacity.sh --json > "$EVIDENCE/released-lanes.json"
jq -e '.lanes == 0 and .free_lanes == 20' "$EVIDENCE/released-lanes.json" > /dev/null
check_spawn admit 'Released records allow project admission'
write_record ordinary primary:missing "$LAB/ordinary-unavailable-worktree"
check_count 'An ordinary exited record retains its place' 1
check_spawn defer 'An ordinary exited record still blocks at cap'
rm "$STATE/ordinary.meta"
write_record released-other primary:uncertain "$STATE/released-other.released-copy"
check_count 'Ambiguous liveness retains a released record' 1
check_spawn defer 'Ambiguous liveness still blocks at cap'
rm "$STATE/released-other.meta"
write_record released-unreadable invalid-target "$STATE/released-unreadable.released-copy"
[ "$(fm_backend_agent_state tmux invalid-target)" = unreadable ]
check_count 'Unreadable liveness retains a released record' 1
check_spawn defer 'Unreadable liveness still blocks at cap'
rm "$STATE/released-unreadable.meta"
# Wait for the real installed Codex to become visible, never substitute it.
for n in $(seq 1 20); do
  live_window=$(tmux -L fm-lab display-message -p -t primary:codex-live '#{window_name}')
  state=$(fm_backend_agent_state tmux "primary:$live_window")
  [ "$state" != alive ] || break
  sleep 0.5
done
printf 'Real Codex endpoint: target=primary:%s state=%s grid=%s\n' "$live_window" "$state" "$(tmux -L fm-lab display-message -p -t primary:codex-live '#{pane_width}x#{pane_height}')"
tmux -L fm-lab capture-pane -p -t primary:codex-live > "$EVIDENCE/codex-endpoint.txt"
[ "$state" = alive ]
write_record released-live "primary:$live_window" "$STATE/released-live.released-copy"
check_count 'A real live Codex retains its released record' 1
check_spawn defer 'Real live Codex still blocks at cap'
printf 'Same private server endpoints after all probes:\n'
tmux -L fm-lab list-windows -t primary -F '#{window_name}: #{pane_current_command}'
printf 'All live capacity checks passed; cleanup trap kills the private server and removes the lab.\n'
