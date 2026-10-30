#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
S=$ROOT/.validation-lab
EV=~/.no-mistakes/evidence/01M6516DGGA228B9AYMG5Z2CK3
SESSION=fm-lab-delivery-01m6516
HELPER=$ROOT/bin/fm-herdr-lab.sh
export FM_HERDR_LAB_STATE_DIR="$S/herdr-state"
ORIGINAL_PATH=$PATH
export ORIGINAL_PATH HELPER SESSION
lab() { PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
cleanup() {
 rc=$?
 trap - EXIT
 PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" > "$EV/herdr-teardown.txt" 2>&1 || rc=1
 exit "$rc"
}
trap cleanup EXIT
"$HELPER" provision "$SESSION"
HOME_LAB=$S/herdr-home-ready
"$ROOT/bin/fm-lab-home.sh" create "$HOME_LAB" >/dev/null
mkdir -p "$S/herdr-shim"
cat > "$S/herdr-shim/herdr" <<'HERDR'
#!/usr/bin/env bash
set -eu
args=("$@")
n=${#args[@]}
[ "$n" -ge 2 ] && [ "${args[n-2]}" = --session ] && [ "${args[n-1]}" = "$SESSION" ] || exit 98
exec env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "${args[@]:0:n-2}"
HERDR
chmod +x "$S/herdr-shim/herdr"
export PATH="$S/herdr-shim:$ORIGINAL_PATH"
ws=$(lab workspace create --cwd "$ROOT" --label fm-mate --no-focus)
pane=$(jq -er '.result.root_pane.pane_id' <<< "$ws")
target=$SESSION:$pane
printf -v command 'env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDECODE FM_HOME=%q FM_TASK_INBOX=%q CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --setting-sources %q --settings %q' "$HOME_LAB" "$HOME_LAB/state/mate.inbox" '' '{"feedbackDrafts":"off"}'
lab pane run "$pane" "$command" >/dev/null
for i in $(seq 1 60); do
 screen=$(lab pane read "$pane" --source visible)
 if [[ "$screen" == *'Yes, I trust this folder'* ]]; then lab pane send-keys "$pane" Down Enter >/dev/null || true; fi
 [[ "$screen" != *'bypass permissions on'* ]] || break
 sleep 1
done
[[ "$screen" == *'bypass permissions on'* ]]
. "$ROOT/bin/fm-task-inbox-lib.sh"
export FM_HOME="$HOME_LAB"
for i in $(seq 1 60); do
  composer=$(fm_backend_composer_state herdr "$target" fm-mate)
  [ "$composer" != empty ] || break
  sleep 1
done
printf 'Ready composer=%s\n' "$composer"
if [ "$composer" != empty ]; then
 lab pane read "$pane" --source visible > "$EV/herdr-not-ready.txt"
 exit 1
fi
request=0123456789abcdef0123456789abcdef
message="Run exactly this shell command: touch '$HOME_LAB/acted'. Then move this message into handled/."
rec=$(fm_task_inbox_write_idempotent "$HOME_LAB/state" mate "$message" '' "$request")
again=$(fm_task_inbox_write_idempotent "$HOME_LAB/state" mate "$message" '' "$request")
[ "$rec" = "$again" ]
printf 'First and retry path: %s\n' "$rec"
rc=0
fm_task_inbox_ring herdr "$target" "$rec" fm-mate claude || rc=$?
printf 'Real Herdr ring exit=%s reason=%s\n' "$rc" "${FM_TASK_INBOX_RING_REASON:-}"
for i in $(seq 1 120); do
 [ ! -e "$HOME_LAB/acted" ] || [ ! -f "$HOME_LAB/state/mate.inbox/handled/001.msg" ] || break
 sleep 1
done
[ -e "$HOME_LAB/acted" ] && [ -f "$HOME_LAB/state/mate.inbox/handled/001.msg" ]
handled=$(fm_task_inbox_write_idempotent "$HOME_LAB/state" mate "$message" '' "$request")
[ "$handled" = "$HOME_LAB/state/mate.inbox/handled/001.msg" ]
printf 'Post-ack retry path: %s\n' "$handled"
if fm_task_inbox_write_idempotent "$HOME_LAB/state" mate different '' "$request"; then exit 1; fi
cat "$handled"
lab pane read "$pane" --source visible > "$EV/herdr-terminal.txt"
printf 'HERDR_LIVE_SUCCESS: one request record, worker acted and handled, conflicting reuse refused.\n'
