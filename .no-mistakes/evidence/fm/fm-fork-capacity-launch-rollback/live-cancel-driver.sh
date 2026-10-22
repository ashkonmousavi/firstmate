#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M5GVD18FTFEZEN8153998CKS
R=$ROOT/.test-runtime/live-cancel
mkdir -p "$R"
export TMPDIR=$R
export FM_HOME=$R/home
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND FM_GATE_REFUSE_BYPASS
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
mkdir -p "$R/inject" "$R/project"
export TREEHOUSE_ROOT=$R/pool HISTFILE=/dev/null SHELL=/bin/bash
export FM_SPAWN_NO_GUARD=1
printf '999999 0\n' > "$FM_HOME/config/lane-capacity"
printf 'project 1\n' > "$FM_HOME/config/project-capacity"
printf 'codex\n' > "$FM_HOME/config/crew-harness"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$FM_HOME/.tasks.toml"
REAL_TASKS=$(command -v tasks-axi)
cat > "$R/inject/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = start ] && [ -f "$R/fail-start" ]; then
  printf 'start attempt\n' >> "$R/start-attempts"
  if [ -f "$R/close-on-start" ]; then tmux kill-window -t '=primary:=fm-seat-keep' 2>/dev/null || true; fi
  sleep 2
  echo 'error: injected backlog write refusal' >&2
  exit 1
fi
exec "$REAL_TASKS" "\$@"
EOF
chmod +x "$R/inject/tasks-axi"
export PATH=$R/inject:$PATH
for id in seat-keep seat-next; do
  mkdir -p "$FM_HOME/data/$id"
  printf '# Task\n## Captain\x27s intent\nWait for instructions. Do not run any tools.\n\n## Firstmate spec\nDisposable seat retention validation.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' > "$FM_HOME/data/$id/brief.md"
  tasks-axi add "$id" 'Disposable seat validation' --kind ship --file "$FM_HOME/data/backlog.md"
done
git init -q -b main "$R/project"
printf 'disposable\n' > "$R/project/README.md"
git -C "$R/project" add README.md
git -C "$R/project" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
git clone -q --bare "$R/project" "$R/origin.git"
git -C "$R/project" remote add origin "$R/origin.git"
SOCKET=$ROOT/.live-socket
cleanup() { tmux -S "$SOCKET" kill-server 2>/dev/null || true; }
trap cleanup EXIT
tmux -f /dev/null -S "$SOCKET" new-session -d -s primary -x 120 -y 40 -c "$R/project" 'bash --noprofile --norc'
export TMUX=$SOCKET,1,0 FM_BACKEND=tmux
touch "$R/fail-start"
"$ROOT/bin/fm-spawn.sh" seat-keep "$R/project" --harness claude --model sonnet --mode no-mistakes --yolo off > "$E/tmux-cancel-launch.log" 2>&1 &
spawn_pid=$!
for i in $(seq 1 900); do
 [ ! -e "$R/start-attempts" ] || break
 kill -0 "$spawn_pid" || { cat "$E/tmux-cancel-launch.log"; exit 1; }
 sleep 0.1
done
test -e "$R/start-attempts"
printf 'TERM sent during backlog commit after launch delivery, pid=%s\n' "$spawn_pid"
kill -TERM "$spawn_pid"
rc=0
wait "$spawn_pid" || rc=$?
cat "$E/tmux-cancel-launch.log"
printf 'cancelled spawn exit=%s\n' "$rc"
[ "$rc" -ne 0 ]
for f in seat-keep.meta seat-keep.busy-gen seat-keep.busy-state; do test -s "$FM_HOME/state/$f"; done
tmux -S "$SOCKET" list-windows -t primary -F '#{window_name} #{pane_current_command}'
printf 'cancelled spawn retained record and busy generation while worker remains\n'
for id in seat-next seat-keep; do
 rc=0
 "$ROOT/bin/fm-spawn.sh" "$id" "$R/project" --harness claude --model sonnet --mode no-mistakes --yolo off > "$E/tmux-cancel-retry-$id.log" 2>&1 || rc=$?
 cat "$E/tmux-cancel-retry-$id.log"
 [ "$rc" -eq 75 ]
done
