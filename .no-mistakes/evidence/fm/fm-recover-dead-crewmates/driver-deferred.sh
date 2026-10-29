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

meta a-first "$LAB/dirty"
meta b-next "$LAB/dirty"
. "$ROOT/bin/fm-session-lock-lib.sh"
anchor=$(fm_session_lock_anchor_pid)
[ -n "$anchor" ]
printf '%s\n' "$anchor" > "$LAB/state/.lock"
echo "REAL_HARNESS_LOCK anchor=$anchor"
echo 'DEFERRED_STAGE: real foreground stage runner, preserved lock owner, zero admission lanes'
"$ROOT/bin/fm-startup-network.sh" run --locked 1 --lock-pid $$
"$ROOT/bin/fm-startup-network.sh" report
cat "$LAB/state/.startup-network.status"
grep -qx 'state=done' "$LAB/state/.startup-network.status"
grep -qx 'rc=0' "$LAB/state/.startup-network.status"
grep -q 'CREW_RECOVERY: a-first: relaunch deferred' "$LAB/state/.startup-network.report"
[ ! -e "$LAB/state/b-next.control-relaunch" ]
echo 'PASS: real deferred startup stage publishes bounded recovery outcome'
