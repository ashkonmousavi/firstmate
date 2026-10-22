#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M5H2YJS9QER9Z49SC5S97NYQ
LAB=$ROOT/.c
WORLD=$ROOT/.live-cancel
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TASKS_AXI_FILE TASKS_AXI_BACKEND TMUX HERDR_ENV HERDR_SESSION
export FM_HOME=$LAB TMUX_TMPDIR=$LAB/tmux FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1
export CLAUDE_CONFIG_DIR=$WORLD/claude-config DISABLE_AUTOUPDATER=1
export TREEHOUSE_ROOT=$WORLD/pool
cleanup() { tmux -L fm-lab kill-server 2>/dev/null || true; chmod -R u+w "$LAB" "$WORLD" 2>/dev/null || true; rm -rf "$LAB" "$WORLD"; }
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux" "$WORLD/bin" "$WORLD/project"
export TMPDIR=$WORLD/tmp
mkdir -p "$TMPDIR"
printf '999999 0\n' > "$LAB/config/lane-capacity"
printf 'project 1\n' > "$LAB/config/project-capacity"
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$LAB/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
for id in lv-seat lv-next; do
 mkdir -p "$LAB/data/$id"
 printf '# Task\n## Captain\x27s intent\nExercise isolated seat retention.\n\n## Firstmate spec\nRun a harmless timed worker.\n\n# Definition of done\nDelivery contract: mode=local-only\n' > "$LAB/data/$id/brief.md"
 tasks-axi add "$id" "isolated seat check" --kind ship --file "$LAB/data/backlog.md"
done
git -C "$WORLD/project" init -q
printf 'fixture\n' > "$WORLD/project/README.md"
git -C "$WORLD/project" add README.md
git -C "$WORLD/project" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
git clone -q --bare "$WORLD/project" "$WORLD/origin.git"
git -C "$WORLD/project" remote add origin "$WORLD/origin.git"
REAL_TASKS=$(command -v tasks-axi)
export REAL_TASKS
cat > "$WORLD/bin/tasks-axi" <<'WRAP'
#!/usr/bin/env bash
if [ "${1:-}" = start ]; then
 printf 'start attempted: %s\n' "$*" >> "$FM_HOME/start-attempts"
 if [ -f "$FM_HOME/close-on-start" ]; then
   target=$(sed -n 's/^window=//p' "$FM_HOME/state/$2.meta")
   tmux kill-window -t "$target" 2>/dev/null || true
 fi
 while [ ! -e "$FM_HOME/release-start" ]; do sleep 0.1; done
 echo 'error: injected unavailable backlog writer' >&2
 exit 1
fi
exec "$REAL_TASKS" "$@"
WRAP
chmod +x "$WORLD/bin/tasks-axi"
export PATH="$WORLD/bin:$PATH"
tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$ROOT"
export TMUX=$(tmux -L fm-lab display-message -p '#{socket_path}'),1,0
spawn() { "$ROOT/bin/fm-spawn.sh" "$1" "$WORLD/project" --mode local-only --yolo off 'claude --version; sleep 180'; }
"$ROOT/bin/fm-spawn.sh" lv-seat "$WORLD/project" --mode local-only --yolo off 'claude --version; sleep 180' > "$E/tmux-cancelled.txt" 2>&1 &
spawn_pid=$!
for i in $(seq 1 600); do
 [ ! -f "$LAB/start-attempts" ] || break
 sleep 0.1
done
[ -s "$LAB/start-attempts" ]
[ -s "$LAB/state/lv-seat.meta" ]
cp "$LAB/state/lv-seat.meta" "$LAB/before"
cp "$LAB/state/lv-seat.busy-gen" "$LAB/gen-before"
kill -TERM "$spawn_pid"
touch "$LAB/release-start"
rc=0
wait "$spawn_pid" || rc=$?
cat "$E/tmux-cancelled.txt"
[ "$rc" -ne 0 ]
[ "$(wc -l < "$LAB/start-attempts")" -eq 2 ]
cmp "$LAB/before" "$LAB/state/lv-seat.meta"
cmp "$LAB/gen-before" "$LAB/state/lv-seat.busy-gen"
tmux -L fm-lab list-windows -t primary -F '#{window_name} #{pane_current_command}'
echo 'PASS: TERM after launch delivery and failed backlog starts retains the live endpoint, task record, and exact busy generation.'
