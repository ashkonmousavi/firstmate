#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.test-recovery-tmp/guards.XXXXXX")
export FM_HOME=$LAB
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID TMUX TMUX_PANE
bin/fm-lab-home.sh create "$LAB"
SOCKDIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
export TMUX_TMPDIR=$SOCKDIR TMUX="$SOCKDIR/tmux-$(id -u)/fm-lab,0,0"
export HOME="$LAB/user" TMPDIR="$LAB/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$TMPDIR"
cleanup() {
  result=$?
  tmux -L fm-lab kill-server 2>/dev/null || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB"
  python3 - "$LAB" <<'CLEANUP'
import os, shutil, sys
for folder, dirs, files in os.walk(sys.argv[1]): os.chmod(folder,0o700)
shutil.rmtree(sys.argv[1])
CLEANUP
  echo "GUARDS_CLEANUP exit=$result"
}
trap cleanup EXIT
printf '0 0\n' > "$LAB/config/lane-capacity"
jq -n --arg path "$LAB" '{schema:"fm-machine-admission.v1",memory_floor_gib:0,memory_full_avg60_max:100,disk_floor_gib:0,disk_paths:[$path]}' > "$LAB/config/machine-admission.json"
git -C "$LAB/projects" init -q -b main
git -C "$LAB/projects" -c user.name=lab -c user.email=lab@example.invalid commit -qm initial --allow-empty
git -C "$LAB/projects" worktree add -qb clean "$LAB/clean"
git -C "$LAB/projects" worktree add -qb dirty "$LAB/dirty"
echo KEEP_DIRTY > "$LAB/dirty/dirty.txt"
meta() {
  local id=$1 wt=$2 harness=${3:-codex} gen=${4:-s1.1.1}
  cat > "$LAB/state/$id.meta" <<EOF
window=guard-session:fm-$id
endpoint_task_id=$id
backend=tmux
worktree=$wt
project=$LAB/projects
harness=$harness
kind=ship
mode=local-only
yolo=off
model=default
effort=low
spawn_gen=$gen
EOF
  mkdir -p "$LAB/data/$id"
  printf '# Task\n## Captain\x27s intent\nPreserve the lab file.\n\n## Firstmate spec\nRemain idle.\n' > "$LAB/data/$id/brief.md"
}
bootstrap() { FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_NETWORK_LOCK_PID=$$ "$ROOT/bin/fm-bootstrap.sh"; }
printf '%s\n' "$$" > "$LAB/state/.lock"
meta clean-task "$LAB/clean"
meta held-task "$LAB/dirty"
echo 'captain-held: pending decision' > "$LAB/state/held-task.status"
mkdir -p "$LAB/foreign/state"
meta foreign-task "$LAB/dirty"
mv "$LAB/state/foreign-task.meta" "$LAB/foreign/state/foreign-task.meta"
ln -s "$LAB/foreign/state/foreign-task.meta" "$LAB/state/foreign-task.meta"
meta status-link "$LAB/dirty"
echo working > "$LAB/foreign/status"
ln -s "$LAB/foreign/status" "$LAB/state/status-link.status"

echo 'GUARDS: clean, captain-held, foreign meta and linked status must not recover'
out=$(bootstrap); echo "$out"
! grep -q 'CREW_RECOVERY:' <<< "$out"
[ -z "$(ls "$LAB/state"/*.control-relaunch 2>/dev/null || true)" ]
[ "$(cat "$LAB/dirty/dirty.txt")" = KEEP_DIRTY ]
echo 'PASS: ineligible records untouched; work preserved'
# Remove metadata from the lab state only to isolate the next scenario.
python3 - "$LAB/state" <<'PY'
from pathlib import Path
import sys
for p in Path(sys.argv[1]).glob('*.meta'): p.unlink()
PY
for gen in missing broken "s$(date +%s).1.1" s999999999999.1.1; do
  meta absence-task "$LAB/dirty" codex "$gen"
  cp "$LAB/state/absence-task.meta" "$LAB/original.meta"
  rc=0
  out=$("$ROOT/bin/fm-control.sh" absence-task relaunch --note 'adversarial absence check' 2>&1) || rc=$?
  echo "ABSENCE generation=$gen rc=$rc"
  echo "$out"
  [ "$rc" = 1 ]
  grep -q 'absence cannot be proven' <<< "$out"
  cmp "$LAB/original.meta" "$LAB/state/absence-task.meta"
done
echo 'PASS: uncertain absence refused without altering metadata'
python3 - "$LAB/state/absence-task.meta" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink()
PY
meta a-first "$LAB/dirty" invalid-harness
meta b-next "$LAB/dirty" invalid-harness
meta c-last "$LAB/dirty" invalid-harness
for phase in detect-only stale-lock; do
  echo "PHASE_BOUNDARY $phase"
  if [ "$phase" = detect-only ]; then
    out=$(FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh")
  else
    out=$(FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_NETWORK_LOCK_PID=999999999 "$ROOT/bin/fm-bootstrap.sh")
  fi
  echo "$out"
  ! grep -q 'CREW_RECOVERY:' <<< "$out"
  [ ! -e "$LAB/state/a-first.control-relaunch" ]
done
echo 'PASS: detect-only and stale deferred workers cannot relaunch'
# Valid harnesses hit the real capacity reader before a new endpoint exists.
for id in a-first b-next c-last; do meta "$id" "$LAB/dirty"; done
rc=0
full=$("$ROOT/bin/fm-control.sh" a-first relaunch --note 'capacity proof' --if-recoverable 2>&1) || rc=$?
echo "DIRECT_CAPACITY rc=$rc"
echo "$full"
[ "$rc" = 75 ]
grep -q 'lane' <<< "$full"
echo 'CAPACITY: zero lanes defers first attempt and leaves later tasks for next pass'
out=$(bootstrap); echo "$out"
grep -q 'CREW_RECOVERY: a-first: relaunch deferred' <<< "$out"
! grep -q 'CREW_RECOVERY: b-next' <<< "$out"
[ ! -e "$LAB/state/b-next.control-relaunch" ]
echo 'PASS: capacity stops serial recovery'
# A real invalid harness refusal is a deterministic pre-launch failure.
printf '5 0\n' > "$LAB/config/lane-capacity"
for id in a-first b-next c-last; do meta "$id" "$LAB/dirty" invalid-harness; done
rc=0
full=$("$ROOT/bin/fm-control.sh" a-first relaunch --note 'failure proof' --if-recoverable 2>&1) || rc=$?
echo "DIRECT_FAILURE rc=$rc"
echo "$full"
[ "$rc" = 1 ]
grep -q 'harness' <<< "$full"
echo 'FAILURE_BOUND: invalid recorded harness stops at first launch failure'
out=$(bootstrap); echo "$out"
grep -q 'CREW_RECOVERY: a-first: relaunch failed' <<< "$out"
! grep -q 'CREW_RECOVERY: b-next' <<< "$out"
[ ! -e "$LAB/state/b-next.control-relaunch" ]
meta a-first "$LAB/clean" invalid-harness
echo 'NEXT_PASS: once first copy is clean, second retained task is attempted'
out=$(bootstrap); echo "$out"
grep -q 'CREW_RECOVERY: b-next: relaunch failed' <<< "$out"
! grep -q 'CREW_RECOVERY: c-last' <<< "$out"
[ "$(cat "$LAB/dirty/dirty.txt")" = KEEP_DIRTY ]
echo 'PASS: failures preserve records and work for the next pass'
