#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M5H2YJS9QER9Z49SC5S97NYQ
LAB=$ROOT/.g
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TASKS_AXI_FILE TASKS_AXI_BACKEND TMUX HERDR_ENV HERDR_SESSION
export FM_HOME=$LAB TMUX_TMPDIR=$LAB/tmux FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1
cleanup() { chmod u+rwx "$LAB/tmux"; tmux -L fm-lab kill-server 2>/dev/null || true; chmod -R u+w "$LAB"; python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$LAB"; }
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/project" "$LAB/data/guard"
printf '999999 0\n' > "$LAB/config/lane-capacity"
printf '# Task\n## Captain\x27s intent\nCheck conservative seat retention.\n\n## Firstmate spec\nRefuse duplicate endpoints.\n\n# Definition of done\nDelivery contract: mode=local-only\n' > "$LAB/data/guard/brief.md"
git -C "$LAB/project" init -q
printf 'fixture\n' > "$LAB/project/README.md"
git -C "$LAB/project" add README.md
git -C "$LAB/project" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
git clone -q --bare "$LAB/project" "$LAB/origin.git"
git -C "$LAB/project" remote add origin "$LAB/origin.git"
tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$ROOT"
tmux -L fm-lab new-window -d -t primary: -n fm-guard -c "$LAB/project" 'sleep 180'
export TMUX=$(tmux -L fm-lab display-message -p '#{socket_path}'),1,0
write_meta() { printf 'window=primary:fm-guard\nproject=%s\nkind=ship\nharness=claude\n' "$LAB/project" > "$LAB/state/guard.meta"; }
write_meta
"$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" guard >/dev/null
for mode in listed unreadable missing-target unsupported; do
 write_meta
 case "$mode" in
 unreadable) chmod 000 "$LAB/tmux" ;;
 missing-target) sed -i '/^window=/d' "$LAB/state/guard.meta" ;;
 unsupported) printf 'backend=orca\nendpoint=unprovable\n' >> "$LAB/state/guard.meta" ;;
 esac
 cp "$LAB/state/guard.meta" "$LAB/before"
 cp "$LAB/state/guard.busy-gen" "$LAB/gen-before"
 set +e
 "$ROOT/bin/fm-spawn.sh" guard "$LAB/project" --mode local-only --yolo off 'sleep 180' > "$E/guard-$mode.txt" 2>&1
 rc=$?
 set -e
 chmod 700 "$LAB/tmux"
 cat "$E/guard-$mode.txt"
 [ "$rc" -ne 0 ]
 cmp "$LAB/before" "$LAB/state/guard.meta"
 cmp "$LAB/gen-before" "$LAB/state/guard.busy-gen"
 [ "$(tmux -L fm-lab list-windows -t primary -F '#{window_name}' | wc -l)" -eq 2 ]
 echo "PASS: uncapped same-id retry refuses $mode endpoint proof and preserves record and generation."
done
# Independently inspect the real pane still executing the harmless process.
tmux -L fm-lab list-panes -t primary:fm-guard -F '#{pane_pid} #{pane_current_command} #{pane_width}x#{pane_height}'
