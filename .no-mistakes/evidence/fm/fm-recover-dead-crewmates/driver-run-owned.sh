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

export NM_HOME="$LAB/nm"
mkdir -p "$NM_HOME"
no-mistakes axi status --run 01K00000000000000000000001 > "$LAB/empty-status" 2>&1 || true
meta owned-task "$LAB/dirty"
sed -i 's/mode=local-only/mode=no-mistakes/' "$LAB/state/owned-task.meta"
echo 'paused: validation owns branch' > "$LAB/state/owned-task.status"
HEAD_SHA=$(git -C "$LAB/dirty" rev-parse HEAD)
python3 - "$NM_HOME/state.sqlite" "$LAB" "$HEAD_SHA" <<'DATA'
import sqlite3, sys, time
c=sqlite3.connect(sys.argv[1]); home=sys.argv[2]; head=sys.argv[3]; now=int(time.time())
c.execute('INSERT INTO repos(id,working_path,upstream_url,default_branch,created_at) VALUES(?,?,?,?,?)',('lab-repo',home+'/projects','https://example.invalid/lab.git','main',now))
c.execute('INSERT INTO runs(id,repo_id,branch,head_sha,base_sha,worktree_dir,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)',('01K00000000000000000000001','lab-repo','dirty',head,head,home+'/dirty','running',now,now))
c.execute('INSERT INTO step_results(id,run_id,step_name,step_order,status) VALUES(?,?,?,?,?)',('lab-step','01K00000000000000000000001','review',1,'fix_review'))
c.commit()
DATA
printf '%s\n' 'REAL_STATUS: reading disposable persisted records; no daemon or pipeline was started'
(cd "$LAB/dirty" && no-mistakes axi status --run 01K00000000000000000000001)
for status in running completed failed; do
  python3 - "$NM_HOME/state.sqlite" "$status" <<'DATA'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]);c.execute('UPDATE runs SET status=?',(sys.argv[2],));c.commit()
DATA
  echo "RECONCILIATION status=$status"
  FM_CREW_STATE_KEEP_RUN=1 FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" owned-task | tee "$LAB/classification"
  grep -q 'source: run-step' "$LAB/classification"
  before=$(sha256sum "$LAB/state/owned-task.meta")
  rc=0
  out=$("$ROOT/bin/fm-control.sh" owned-task relaunch --note 'must remain with run owner' --if-recoverable 2>&1) || rc=$?
  echo "CONTROL rc=$rc $out"
  [ "$rc" = 3 ]
  [ "$before" = "$(sha256sum "$LAB/state/owned-task.meta")" ]
  out=$(bootstrap); echo "$out"
  ! grep -q 'CREW_RECOVERY:' <<< "$out"
  [ ! -e "$LAB/state/owned-task.control-relaunch" ]
done
echo 'PASS: active, parked and terminal attributed run records block recovery using the real status CLI'
