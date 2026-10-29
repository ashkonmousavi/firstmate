#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M63VRJ4X60FN2Q5A00KHKAPB
ORIGINAL_HOME=$HOME
LAB=$(mktemp -d "$ROOT/.test-recovery-tmp/lab.XXXXXX")
export FM_HOME=$LAB
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID TMUX TMUX_PANE
bin/fm-lab-home.sh create "$LAB"
SOCKDIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
export TMUX_TMPDIR=$SOCKDIR TMUX="$SOCKDIR/tmux-$(id -u)/fm-lab,0,0"
export HOME="$LAB/user" CODEX_HOME="$LAB/user/.codex"
mkdir -p "$CODEX_HOME" "$LAB/tmp"
export TMPDIR="$LAB/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
ln -s "$ORIGINAL_HOME/.codex/auth.json" "$CODEX_HOME/auth.json"
printf 'model = "gpt-6.1-sol"\nmodel_reasoning_effort = "low"\n' > "$CODEX_HOME/config.toml"
ID="recovery-lab-$$"
cleanup() {
  code=$?
  tmux -L fm-lab list-panes -a -F '#{pane_pid}' > "$E/lab-pane-pids.txt" 2>/dev/null || true
  tmux -L fm-lab kill-server 2>/dev/null || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" || true
  python3 - "$LAB" <<'CLEANUP'
import os, shutil, sys
for folder, dirs, files in os.walk(sys.argv[1]):
    os.chmod(folder, 0o700)
shutil.rmtree(sys.argv[1])
CLEANUP
  printf 'LAB_CLEANUP exit=%s\n' "$code"
}
trap cleanup EXIT
printf '1 0\n' > "$LAB/config/lane-capacity"
jq -n --arg path "$LAB" '{schema:"fm-machine-admission.v1",memory_floor_gib:0,memory_full_avg60_max:100,disk_floor_gib:0,disk_paths:[$path]}' > "$LAB/config/machine-admission.json"
mkdir -p "$LAB/projects/sample" "$LAB/data/$ID"
git -C "$LAB/projects/sample" init -q -b main
git -C "$LAB/projects/sample" -c user.name=lab -c user.email=lab@example.invalid commit -qm initial --allow-empty
git -C "$LAB/projects/sample" worktree add -qb task "$LAB/copy"
printf 'PRESERVE-THIS-UNLANDED-WORK\n' > "$LAB/copy/unlanded.txt"
git -C "$LAB/copy" add unlanded.txt
git -C "$LAB/copy" -c user.name=lab -c user.email=lab@example.invalid commit -qm unpublished
HEAD_BEFORE=$(git -C "$LAB/copy" rev-parse HEAD)
cat > "$LAB/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
For this disposable recovery proof, read unlanded.txt and reply RECOVERY_READY. Do not edit, commit, run validation pipelines, contact services, or launch other processes except the file read.

## Firstmate spec
This is an isolated lab. Preserve unlanded.txt and remain idle after replying RECOVERY_READY.
EOF
cat > "$LAB/state/$ID.meta" <<EOF
window=lab-recovered:fm-$ID
endpoint_task_id=$ID
backend=tmux
worktree=$LAB/copy
project=$LAB/projects/sample
harness=codex
kind=scout
mode=local-only
yolo=off
model=gpt-6.1-sol
effort=low
spawn_gen=s1.1.1
EOF
for later in z-next zz-last; do
  sed "s/$ID/$later/g" "$LAB/state/$ID.meta" > "$LAB/state/$later.meta"
  mkdir -p "$LAB/data/$later"
  cp "$LAB/data/$ID/brief.md" "$LAB/data/$later/brief.md"
done
printf 'done: implementation complete, no validation run started\n' > "$LAB/state/$ID.status"
printf '%s\n' 'BEFORE: real isolated tmux socket has no server'
if tmux -L fm-lab list-sessions; then exit 80; fi
printf '%s\n' 'BEFORE: task reconciliation'
"$ROOT/bin/fm-crew-state.sh" "$ID"
printf '%s\n' 'RECOVERY: deferred startup phase'
printf '%s\n' "$$" > "$LAB/state/.lock"
out=$(FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_NETWORK_LOCK_PID=$$ "$ROOT/bin/fm-bootstrap.sh")
echo "$out"
grep -q "CREW_RECOVERY: relaunched $ID after missing" <<< "$out"
grep -q 'CREW_RECOVERY: z-next: relaunch deferred' <<< "$out"
! grep -q 'CREW_RECOVERY: zz-last' <<< "$out"
[ ! -e "$LAB/state/zz-last.control-relaunch" ]
echo 'SERIAL_CAPACITY: first real agent launched; next deferred; third untouched' 
printf '%s\n' 'AFTER: persisted task metadata'
cat "$LAB/state/$ID.meta"
printf '%s\n' 'AFTER: real tmux endpoints'
tmux -L fm-lab list-panes -a -F '#{session_name}:#{window_name} #{pane_current_command} #{pane_current_path} #{pane_width}x#{pane_height}'
for i in $(seq 1 60); do
  tmux -L fm-lab capture-pane -p -t "lab-recovered:fm-$ID" > "$E/live-scout-pane.txt"
  if grep -q 'Trust and continue' "$E/live-scout-pane.txt"; then tmux -L fm-lab send-keys -t "lab-recovered:fm-$ID" Enter; fi
  if grep -q '^• RECOVERY_READY'  "$E/live-scout-pane.txt"; then break; fi
  sleep 1
done
cat "$E/live-scout-pane.txt"
grep -q "^• RECOVERY_READY" "$E/live-scout-pane.txt"
[ "$(git -C "$LAB/copy" rev-parse HEAD)" = "$HEAD_BEFORE" ]
[ -z "$(git -C "$LAB/copy" status --porcelain)" ]
printf '%s\n' 'AFTER: preserved unlanded file'
cat "$LAB/copy/unlanded.txt"
[ "$(cat "$LAB/copy/unlanded.txt")" = PRESERVE-THIS-UNLANDED-WORK ]
cp "$LAB/state/$ID.meta" "$LAB/before.meta"
printf '%s\n' 'SECOND PASS: healthy replacement must stay unchanged'
FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_NETWORK_LOCK_PID=$$ "$ROOT/bin/fm-bootstrap.sh"
cmp "$LAB/before.meta" "$LAB/state/$ID.meta"
printf '%s\n' 'HEALTHY_METADATA_UNCHANGED'
tmux -L fm-lab list-windows -a -F '#{window_name} #{window_id}'
