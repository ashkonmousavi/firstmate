#!/usr/bin/env bash
set -eu
R=$PWD/.test-runtime/live-cancel
SOCKET=$PWD/.b
cleanup() { chmod 700 .deny; tmux -S "$SOCKET" kill-server 2>/dev/null || true; }
trap cleanup EXIT
export FM_HOME=$R/home FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 HISTFILE=/dev/null
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND FM_GATE_REFUSE_BYPASS
printf 'project 1\n' > "$FM_HOME/config/project-capacity"
cp "$FM_HOME/state/seat-keep.meta" "$R/boundary-original.meta"
cp "$FM_HOME/state/seat-keep.busy-gen" "$R/boundary-original.gen"
tmux -f /dev/null -S "$SOCKET" new-session -d -s primary -x 120 -y 40 'sleep 300'
tmux -S "$SOCKET" new-window -d -t primary -n fm-seat-keep 'sleep 300'
rm .deny/s
ln -s ../.b .deny/s
for case in unreadable empty zellij cmux paseo orca; do
 export TMUX=$SOCKET,1,0
 cp "$R/boundary-original.meta" "$FM_HOME/state/seat-keep.meta"
 case "$case" in
 unreadable) chmod 000 .deny; export TMUX=$PWD/.deny/s,1,0 ;;
 empty) sed -i 's/^window=.*/window=/' "$FM_HOME/state/seat-keep.meta" ;;
 *) printf 'backend=%s\nterminal=unproven-endpoint\n' "$case" >> "$FM_HOME/state/seat-keep.meta" ;;
 esac
 cp "$FM_HOME/state/seat-keep.meta" "$R/boundary-before.meta"
 printf '\nStored endpoint case=%s\n' "$case"
 rc=0
 bin/fm-spawn.sh seat-keep "$R/project" --backend tmux --harness claude --model sonnet --mode no-mistakes --yolo off || rc=$?
 printf 'same-id admission exit=%s\n' "$rc"
 [ "$rc" -eq 75 ]
 cmp "$R/boundary-before.meta" "$FM_HOME/state/seat-keep.meta"
 cmp "$R/boundary-original.gen" "$FM_HOME/state/seat-keep.busy-gen"
 chmod 700 .deny
 printf 'record and generation retained unchanged\n'
done
