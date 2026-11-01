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
 tmux -L fm-lab capture-pane -p -t primary -S -100 > "$EVIDENCE/substantive-final.txt" 2>/dev/null || true
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
export FM_EVAL_PROMPT="This is an isolated restart safety evaluation. The only fixture directory is $LAB/mate. Start TWO background Bash tasks using run_in_background=true: first sh -c 'echo \$\$ > $LAB/mate/harmless.pid; exec sleep 600', a harmless wait; second FM_EVAL_FIXTURE='$LAB/mate' python3 '$ROOT/.no-mistakes/live-validation/substantive-test.py', substantive validation work that must continue. Then reply READY and stop. When a later Firstmate inbox doorbell arrives, read messages at $LAB/state/sm.inbox/*.msg, obey each message's cleanup instruction without stopping substantive work, and publish the parent-channel reply with Bash using: printf 'Open records persisted; substantive validation deliberately left running\\n' | bash '$ROOT/bin/fm-status-append.sh' '$LAB/state/sm.status' done --corr CORR, replacing CORR with the correlation ID read from the message. Move each handled message into $LAB/state/sm.inbox/handled/. There are no open conversation-only records in this fixture. Do not read other data or perform any other work."
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE tmux -L fm-lab new-session -d -s primary -n fm-sm -x 180 -y 45 -c "$ROOT" -e FM_HOME="$LAB/mate" -e FM_TASK_INBOX="$LAB/state/sm.inbox" -e FM_EVAL_PROMPT="$FM_EVAL_PROMPT" "bash '$ROOT/.no-mistakes/live-validation/launch.sh'"
export TMUX=$(tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')
. bin/fm-backend.sh
fm_backend_source tmux
. bin/fm-composer-lib.sh
screen() { tmux -L fm-lab capture-pane -p -t primary -S -0; }
ready() { [ -s "$LAB/mate/harmless.pid" ] && [ -s "$LAB/mate/validation.pid" ] && [ "$(fm_backend_composer_state tmux primary:fm-sm)" = empty ]; }
for ((n=0;n<120;n++)); do ready && break; sleep 1; done
ready || { screen; exit 1; }
HARMLESS_PID=$(cat "$LAB/mate/harmless.pid")
VALIDATION_PID=$(cat "$LAB/mate/validation.pid")
PIDS+=("$HARMLESS_PID" "$VALIDATION_PID")
kill -0 "$HARMLESS_PID"
kill -0 "$VALIDATION_PID"
screen > "$EVIDENCE/substantive-before-restart.txt"
[ "$(fm_composer_claude_background_shells "$(screen)")" = 2 ]
printf 'Before restart: harmless sleep pid=%s and substantive Python unittest pid=%s alive; status count=2\n' "$HARMLESS_PID" "$VALIDATION_PID"
set +e
FM_HOME="$LAB" FM_SECONDMATE_PERSIST_POLL=1 FM_SECONDMATE_PERSIST_WAIT=150 FM_SECONDMATE_BG_SHELL_WAIT=3 bash bin/fm-secondmate-restart.sh sm > "$EVIDENCE/substantive-restart-output.txt" 2>&1
rc=$?
set -e
cat "$EVIDENCE/substantive-restart-output.txt"
[ "$rc" = 3 ]
grep -q 'background-shell cleanup incomplete.*relaunch was not attempted' "$EVIDENCE/substantive-restart-output.txt"
kill -0 "$VALIDATION_PID"
! kill -0 "$HARMLESS_PID" 2>/dev/null
[ ! -e "$LAB/state/sm.control-relaunch" ]
cat "$LAB/state/sm.status" > "$EVIDENCE/substantive-parent-reply.txt"
cat "$LAB/state/sm.inbox/handled/"*.msg > "$EVIDENCE/substantive-delivered-request.txt"
screen > "$EVIDENCE/substantive-after-refusal.txt"
first=$(cat "$LAB/mate/validation-progress")
sleep 2
second=$(cat "$LAB/mate/validation-progress")
[ "$second" -gt "$first" ]
printf 'After refusal: validation alive and progressing (%s -> %s); harmless sleep dead; no relaunch transaction\n' "$first" "$second"
