#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M6ABEANQHANCK9Z0N0FC6S6P
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
bash bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/mate"
export TMUX_TMPDIR="$LAB/tmux"
export DISABLE_AUTOUPDATER=1 DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
BACKGROUND_PID=
cleanup() {
 status=$?
 trap - EXIT
 tmux -L fm-lab capture-pane -p -t primary -S -100 > "$EVIDENCE/picker-final.txt" 2>/dev/null || true
 tmux -L fm-lab kill-server >/dev/null 2>&1 || true
 [ -z "$BACKGROUND_PID" ] || kill "$BACKGROUND_PID" 2>/dev/null || true
 rm -rf "$LAB"
 printf 'cleanup exit=%s\n' "$status"
 exit "$status"
}
trap cleanup EXIT
cat > "$LAB/state/sm.meta" <<EOF
window=primary:fm-sm
endpoint_task_id=sm
worktree=$LAB/mate
project=$LAB/mate
harness=claude
kind=scout
mode=scout
yolo=off
model=haiku
effort=low
backend=tmux
EOF
export FM_EVAL_PROMPT="Use Bash exactly once with run_in_background=true to run: sh -c 'echo \$\$ > $LAB/mate/harmless.pid; exec sleep 600'. Then reply READY and stop. This is a disposable exit-picker evaluation. Do not stop the task or change any other files."
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE tmux -L fm-lab new-session -d -s primary -n fm-sm -x 180 -y 45 -c "$ROOT" -e FM_HOME="$LAB" -e CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF=1 -e FM_EVAL_PROMPT="$FM_EVAL_PROMPT" "bash '$ROOT/.no-mistakes/live-validation/launch.sh'"
export TMUX=$(tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')
. bin/fm-backend.sh
fm_backend_source tmux
screen() { tmux -L fm-lab capture-pane -p -t primary -S -0; }
for ((n=0;n<100;n++)); do [ -s "$LAB/mate/harmless.pid" ] && [ "$(fm_backend_composer_state tmux primary:fm-sm)" = empty ] && break; sleep 1; done
BACKGROUND_PID=$(cat "$LAB/mate/harmless.pid")
kill -0 "$BACKGROUND_PID"
sleep 3
tmux -L fm-lab send-keys -t primary -l /exit
sleep 0.5
tmux -L fm-lab send-keys -t primary Enter
for ((n=0;n<15;n++)); do screen | grep -q '^ *Background work is running' && break; sleep 1; done
screen > "$EVIDENCE/picker-before-control.txt"
grep -q '^ *Background work is running' "$EVIDENCE/picker-before-control.txt"
set +e
FM_HOME="$LAB" FM_CONTROL_EXIT_WAIT=2 bash bin/fm-control.sh sm exit > "$EVIDENCE/picker-control-output.txt" 2>&1
rc=$?
set -e
cat "$EVIDENCE/picker-control-output.txt"
[ "$rc" = 1 ]
grep -q 'Refusing to type Enter' "$EVIDENCE/picker-control-output.txt"
kill -0 "$BACKGROUND_PID"
screen > "$EVIDENCE/picker-after-control.txt"
grep -q '^ *Background work is running' "$EVIDENCE/picker-after-control.txt"
printf 'Control exit refused the live picker, did not confirm it, and left the background task alive pid=%s\n' "$BACKGROUND_PID"
