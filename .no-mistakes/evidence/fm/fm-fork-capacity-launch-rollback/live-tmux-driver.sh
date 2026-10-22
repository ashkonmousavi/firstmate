#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M5GVD18FTFEZEN8153998CKS
R=$ROOT/.test-runtime/live-claude
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
rc=0
"$ROOT/bin/fm-spawn.sh" seat-keep "$R/project" --harness claude --model sonnet --mode no-mistakes --yolo off > "$E/tmux-launch.log" 2>&1 || rc=$?
printf 'initial spawn exit=%s\n' "$rc"
cat "$E/tmux-launch.log"
[ "$rc" -ne 0 ]
[ "$(wc -l < "$R/start-attempts")" -eq 2 ]
for f in seat-keep.meta seat-keep.busy-gen seat-keep.busy-state; do test -s "$FM_HOME/state/$f"; done
cp "$FM_HOME/state/seat-keep.meta" "$E/tmux-retained.meta"
cp "$FM_HOME/state/seat-keep.busy-gen" "$E/tmux-retained.busy-gen"
tmux -S "$SOCKET" list-windows -t primary -F '#{window_name} #{window_id} #{pane_current_command}'
tmux -S "$SOCKET" capture-pane -p -t '=primary:=fm-seat-keep' > "$E/tmux-worker-screen.txt"
cp "$FM_HOME/state/seat-keep.meta" "$R/before.meta"
cp "$FM_HOME/state/seat-keep.busy-gen" "$R/before.gen"
for id in seat-next seat-keep; do
  rc=0
  "$ROOT/bin/fm-spawn.sh" "$id" "$R/project" --harness claude --model sonnet --mode no-mistakes --yolo off > "$E/tmux-retry-$id.log" 2>&1 || rc=$?
  cat "$E/tmux-retry-$id.log"
  printf 'retry %s exit=%s\n' "$id" "$rc"
  [ "$rc" -eq 75 ]
done
test ! -e "$FM_HOME/state/seat-next.meta"
cmp "$R/before.meta" "$FM_HOME/state/seat-keep.meta"
cmp "$R/before.gen" "$FM_HOME/state/seat-keep.busy-gen"
printf 'retained record and busy generation unchanged after both refusals\n'
tmux -S "$SOCKET" kill-window -t '=primary:=fm-seat-keep'
touch "$R/close-on-start"
# Retrying the old id re-reads absence and releases its retained record. A new
# injected backlog refusal then proves the new endpoint's record also stays.
rc=0
"$ROOT/bin/fm-spawn.sh" seat-keep "$R/project" --harness claude --model sonnet --mode no-mistakes --yolo off > "$E/tmux-stale-retry.log" 2>&1 || rc=$?
cat "$E/tmux-stale-retry.log"
printf 'stale same-id retry exit=%s\n' "$rc"
[ "$rc" -ne 0 ]
test ! -e "$FM_HOME/state/seat-keep.meta"
test ! -e "$FM_HOME/state/seat-keep.busy-gen"
printf 'fresh absence read removed the old record and retired its generation\n'
rm "$R/fail-start" "$R/close-on-start"
"$ROOT/bin/fm-spawn.sh" seat-next "$R/project" --harness claude --model sonnet --mode no-mistakes --yolo off > "$E/tmux-next-admitted.log" 2>&1
cat "$E/tmux-next-admitted.log"
test -s "$FM_HOME/state/seat-next.meta"
printf 'next id admitted after proven absence\n'

