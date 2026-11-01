#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M6ABEANQHANCK9Z0N0FC6S6P
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
bash bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/mate/state" "$LAB/mate/data" "$LAB/data/sm" "$LAB/state/sm.inbox/handled"
export TMUX_TMPDIR="$LAB/tmux"
export DISABLE_AUTOUPDATER=1 DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
PIDS=()
cleanup() {
 status=$?
 trap - EXIT
 tmux -L fm-lab capture-pane -p -t primary -S -100 > "$EVIDENCE/unreadable-final.txt" 2>/dev/null || true
 tmux -L fm-lab kill-server >/dev/null 2>&1 || true
 for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
 rm -rf "$LAB"
 printf 'cleanup exit=%s\n' "$status"
 exit "$status"
}
trap cleanup EXIT
printf 'claude\n' > "$LAB/config/secondmate-harness"
printf '# isolated evaluation\n' > "$LAB/data/sm/brief.md"
cat > "$LAB/state/sm.meta" <<EOF
window=primary:fm-sm
endpoint_task_id=sm
worktree=$ROOT
project=$ROOT
harness=claude
kind=secondmate
mode=secondmate
yolo=off
model=haiku
effort=low
home=$LAB/mate
backend=tmux
EOF
export FM_EVAL_PROMPT="This is an isolated restart safety evaluation. Reply READY and wait. When a Firstmate inbox doorbell arrives, read the .msg files at $LAB/state/sm.inbox. There are no open records or background jobs in this fixture. Publish a correlated parent reply with Bash: printf 'Open records persisted\\n' | bash '$ROOT/bin/fm-status-append.sh' '$LAB/state/sm.status' done --corr CORR, replacing CORR with the message correlation. In THAT SAME Bash tool invocation, immediately after the status append, run tmux kill-server (TMUX points only at this disposable socket) to deliberately simulate loss of the mate endpoint. Do not run a relaunch or any other command. Do not read other data."
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE tmux -L fm-lab new-session -d -s primary -n fm-sm -x 180 -y 45 -c "$ROOT" -e FM_HOME="$LAB/mate" -e FM_TASK_INBOX="$LAB/state/sm.inbox" -e FM_EVAL_PROMPT="$FM_EVAL_PROMPT" "bash '$ROOT/.no-mistakes/live-validation/launch.sh'"
export TMUX=$(tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')
. bin/fm-backend.sh
fm_backend_source tmux
. bin/fm-composer-lib.sh
screen() { tmux -L fm-lab capture-pane -p -t primary -S -0; }
ready() { [ "$(fm_backend_composer_state tmux primary:fm-sm)" = empty ] && screen | grep -q '^● READY'; }
for ((n=0;n<100;n++)); do ready && break; sleep 1; done
ready || { screen; exit 1; }
screen > "$EVIDENCE/unreadable-before-restart.txt"
set +e
FM_HOME="$LAB" FM_SECONDMATE_PERSIST_POLL=2 FM_SECONDMATE_PERSIST_WAIT=120 FM_SECONDMATE_BG_SHELL_WAIT=3 bash bin/fm-secondmate-restart.sh sm > "$EVIDENCE/unreadable-restart-output.txt" 2>&1
rc=$?
set -e
cat "$EVIDENCE/unreadable-restart-output.txt"
[ "$rc" = 3 ]
grep -q 'its screen could not be read; relaunch was not attempted' "$EVIDENCE/unreadable-restart-output.txt"
[ ! -e "$LAB/state/sm.control-relaunch" ]
cat "$LAB/state/sm.status" > "$EVIDENCE/unreadable-parent-reply.txt"
printf 'After correlated persist reply, the real lab endpoint vanished; restart refused unreadable screen without a relaunch transaction.\n'
