#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$ROOT/.j
cleanup() { TMUX_TMPDIR="$LAB/t" tmux -L fm-lab kill-server >/dev/null 2>&1 || true; sleep 0.5; rm -rf "$LAB"; }
trap cleanup EXIT
unset FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID FM_BACKEND HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH TMUX TMUX_PANE TASKS_AXI_FILE TASKS_AXI_BACKEND
. "$ROOT/tests/git-config-helpers.sh"
"$ROOT/bin/fm-lab-home.sh" create "$LAB/h"
export FM_HOME=$LAB/h HOME=$LAB/u TREEHOUSE_ROOT=$LAB/p SHELL=/bin/bash TMUX_TMPDIR=$LAB/t TREEHOUSE_NO_UPDATE_CHECK=1
export XDG_CONFIG_HOME=$LAB/u/.config XDG_STATE_HOME=$LAB/u/.state XDG_CACHE_HOME=$LAB/u/.cache TMPDIR=$LAB/tmp
mkdir -p "$HOME" "$TMUX_TMPDIR" "$TMPDIR"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf '10 0\n' > "$FM_HOME/config/lane-capacity"
printf '{"schema":"fm-machine-admission.v1","memory_floor_gib":0,"memory_full_avg60_max":100,"disk_floor_gib":0,"disk_paths":["%s"]}\n' "$LAB" > "$FM_HOME/config/machine-admission.json"
touch "$FM_HOME/config/keep-ai-trailers"
git init -qb main "$LAB/project"
git -C "$LAB/project" -c user.name=Lab -c user.email=lab@example.invalid commit --allow-empty -qm initial
A=$(cd "$LAB/project" && treehouse get --lease --lease-holder designer)
git -C "$A" checkout -qb fm/designer
printf 'unfinished design\n' > "$A/design.txt"
HEAD_BEFORE=$(git -C "$A" rev-parse HEAD)
write_meta() {
  printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nkind=%s\nworktree=%s\nproject=%s\nharness=codex\nspawn_gen=s1\nbranch=%s\nmode=local-only\nbackend=tmux\n' "$1" "$1" "$2" "$A" "$LAB/project" "${3:-}" > "$FM_HOME/state/$1.meta"
}
claim() { printf 'task=%s\nhome=%s\n' "$1" "$FM_HOME" > "$(dirname "$A")/.fm-slot-owner"; }
refuse() { local rc=0; "$@" > "$LAB/out" 2>&1 || rc=$?; cat "$LAB/out"; [ "$rc" -ne 0 ]; }
intact() {
  [ "$(git -C "$A" symbolic-ref --short HEAD)" = fm/designer ]
  [ "$(git -C "$A" rev-parse HEAD)" = "$HEAD_BEFORE" ]
  [ "$(cat "$A/design.txt")" = 'unfinished design' ]
}
tmux -L fm-lab new-session -d -s firstmate -n control -x 120 -y 32 -c "$ROOT" 'bash --noprofile --norc'
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),0,0"
export TMUX_PANE=$(tmux -L fm-lab display-message -p '#{pane_id}')
write_meta finished ship fm/finished
claim finished
printf '\n=== WRONG BRANCH, ORDINARY AND FORCE ===\n'
refuse "$ROOT/bin/fm-teardown.sh" finished
grep -q 'recorded branch' "$LAB/out"
refuse "$ROOT/bin/fm-teardown.sh" finished --force
grep -q 'recorded branch' "$LAB/out"
intact
[ -f "$FM_HOME/state/finished.meta" ]
rm "$FM_HOME/state/finished.meta"
printf '\n=== SAME-ID FRESH RETRY PRESERVES COPY ===\n'
write_meta same scout fm/designer
claim same
mkdir -p "$FM_HOME/data/same"
printf "# Task\n## Captain's intent\nPreserve retained work.\n\n## Firstmate spec\nExercise same-ID fresh retry.\n" > "$FM_HOME/data/same/brief.md"
cp "$FM_HOME/state/same.meta" "$LAB/same.before"
refuse "$ROOT/bin/fm-spawn.sh" same "$LAB/project" --scout --backend tmux --harness 'sleep 300'
cmp "$FM_HOME/state/same.meta" "$LAB/same.before"
intact
[ "$(cd "$LAB/project" && treehouse status --json | jq length)" = 1 ]
printf "PASS: failed same-ID retry preserved meta, copy and original lease.\n"
rm "$FM_HOME/state/same.meta"
write_meta stale scout
write_meta designer ship fm/designer
claim designer
cp "$FM_HOME/state/stale.meta" "$LAB/stale.before"
cp "$FM_HOME/state/designer.meta" "$LAB/designer.before"
cp "$(dirname "$A")/.fm-slot-owner" "$LAB/claim.before"
printf '\n=== DUPLICATE COPY: RELAUNCH AND PROMOTION ===\n'
refuse "$ROOT/bin/fm-control.sh" stale relaunch
grep -q 'also task designer' "$LAB/out"
refuse "$ROOT/bin/fm-spawn.sh" stale --relaunch
grep -q 'also task designer' "$LAB/out"
refuse "$ROOT/bin/fm-promote.sh" stale --mode direct-PR --yolo off
grep -q 'also task designer' "$LAB/out"
cmp "$FM_HOME/state/stale.meta" "$LAB/stale.before"
intact
printf '\n=== DUPLICATE COPY: FRESH SPAWN ===\n'
mkdir -p "$FM_HOME/data/new-task"
printf "# Task\n## Captain's intent\nRetain copy ownership.\n\n## Firstmate spec\nExercise allocation guard.\n" > "$FM_HOME/data/new-task/brief.md"
refuse "$ROOT/bin/fm-spawn.sh" new-task "$LAB/project" --scout --backend tmux --harness 'sleep 300'
grep -q 'also task' "$LAB/out"
[ ! -e "$FM_HOME/state/new-task.meta" ]
intact
printf '\n=== HOME ADOPTION AND LEASED SEED REFUSE SHARED COPY ===\n'
for requested in "$A" -; do
  refuse env FM_ROOT_OVERRIDE="$LAB/project" "$ROOT/bin/fm-home-seed.sh" new-mate "$requested" --no-projects
  grep -q 'also task' "$LAB/out"
  [ ! -e "$A/.fm-secondmate-home" ]
  intact
done
printf '\n=== DEFERRED AND PREPARED-BACKLOG SPAWN REFUSE SHARED COPY ===\n'
rm "$FM_HOME/config/backlog-backend"
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$FM_HOME/.tasks.toml"
printf '## In flight\n## Queued\n## Done\n' > "$FM_HOME/data/backlog.md"
tasks-axi add new-task 'queued ownership proof' --kind scout --repo project --file "$FM_HOME/data/backlog.md"
"$ROOT/bin/fm-spawn-deferred.sh" record new-task -- "$ROOT/bin/fm-spawn.sh" new-task "$LAB/project" --scout --backend tmux --harness 'sleep 60'
"$ROOT/bin/fm-spawn-deferred.sh" retry
cat "$FM_HOME/state/spawn-deferred/retry.log"
grep -q 'also task' "$FM_HOME/state/spawn-deferred/retry.log"
[ ! -e "$FM_HOME/state/new-task.meta" ]
intact
tasks-axi add auto-task 'automatic ownership proof' --kind scout --repo project --file "$FM_HOME/data/backlog.md"
mkdir -p "$FM_HOME/data/auto-task"
cp "$FM_HOME/data/new-task/brief.md" "$FM_HOME/data/auto-task/brief.md"
ln -s "$LAB/project" "$FM_HOME/projects/project"
printf 'Investigate without changing a retained copy.\n' > "$FM_HOME/data/auto-task/prep.md"
printf '{"shared_quota":true,"default":{"harness":"claude"}}\n' > "$FM_HOME/config/crew-dispatch.json"
"$ROOT/bin/fm-autolaunch.sh"
cat "$FM_HOME/state/autolaunch.log"
grep -q 'also task' "$FM_HOME/state/autolaunch.log"
[ ! -e "$FM_HOME/state/auto-task.meta" ]
intact
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf '\n=== REMOVED CUSTODY-TRANSFER OPTION IS REJECTED ===\n'
refuse "$ROOT/bin/fm-teardown.sh" stale --records-only-shared-with designer
grep -q 'invalid teardown request' "$LAB/out"
cmp "$FM_HOME/state/stale.meta" "$LAB/stale.before"
cmp "$FM_HOME/state/designer.meta" "$LAB/designer.before"
cmp "$(dirname "$A")/.fm-slot-owner" "$LAB/claim.before"
intact
printf '\n=== SAFE CLEANUP: REPORT GATE STILL BINDS ===\n'
refuse "$ROOT/bin/fm-teardown.sh" stale
grep -q 'has no report' "$LAB/out"
[ -f "$FM_HOME/state/stale.meta" ]
mkdir -p "$FM_HOME/data/stale"
printf 'Superseded disposable scout. No unresolved decisions; designer retains all copy contents.\n' > "$FM_HOME/data/stale/report.md"
"$ROOT/bin/fm-captain-hold.sh" complete stale --none
write_meta stale-ship ship fm/stale-ship
printf '\n=== THREE RECORDS: ORDINARY FOREIGN-CLAIM CLEANUP ===\n'
for id in stale-ship stale; do
  "$ROOT/bin/fm-teardown.sh" "$id"
  [ ! -f "$FM_HOME/state/$id.meta" ]
  intact
  cmp "$FM_HOME/state/designer.meta" "$LAB/designer.before"
  cmp "$(dirname "$A")/.fm-slot-owner" "$LAB/claim.before"
done
(cd "$LAB/project" && treehouse status --json)
printf '\nPASS: branch mismatch refuses even with force; shared-copy spawn/relaunch/promotion refuse; report gate binds; ordinary cleanup retires both stale records while designer HEAD, branch, edits, claim, lease and meta remain.\n'
