#!/usr/bin/env bash
set -eu
export RING_ROOT="$PWD" RING_LAB_SESSION=fm-lab-ring-reasons-01m64 RING_ORIGINAL_PATH="$PATH" RING_REMAP_REMOTE=1
export TMPDIR="$PWD/.tmp-ring-validation" FM_HERDR_LAB_STATE_DIR="$PWD/.tmp-ring-validation/herdr-state"
export PATH="$PWD/.tmp-ring-validation/bin:$PATH" FM_HOME="$(cat .tmp-ring-validation/lab-home)"
printf 'rsm\n' > "$FM_HOME/.fm-secondmate-home"
ln -s "$PWD/AGENTS.md" "$FM_HOME/AGENTS.md"
ln -s "$PWD/bin" "$FM_HOME/bin"
mkdir -p "$FM_HOME/state/parent-route"
cat > "$FM_HOME/state/parent-route/rsm.meta" <<'META'
window=fm-remote:w1:p1
worktree=-
project=-
backend=herdr
endpoint_task_id=rsm
harness=claude
herdr_session=fm-remote
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=w1:p1
META
# Only the session argument is redirected: all responses come from real Herdr.
printf 'Isolation: map the controller fixed fm-remote session to %s; no SSH or fleet endpoint is used.\n' "$RING_LAB_SESSION"
export FM_COMPOSER_DIALOG_SINK="$FM_HOME/no-such-directory/dialog"
rc=0
bin/fm-remote-secondmate-control.sh send rsm 'Preserve this remote validation record.' > "$FM_HOME/send.stdout" 2> "$FM_HOME/send.stderr" || rc=$?
printf 'send exit=%s stdout=%s stderr=%s\n' "$rc" "$(cat "$FM_HOME/send.stdout")" "$(cat "$FM_HOME/send.stderr")"
[ "$rc" = 0 ] && grep -q 'reason=dialog-sink-failed' "$FM_HOME/send.stderr"
rec="$FM_HOME/state/parent-route/rsm.inbox/001.msg"
cp "$rec" "$FM_HOME/remote-original.msg"
out=$(bin/fm-remote-secondmate-control.sh inbox rsm ring 001.msg)
printf 'ring protocol: %s\n' "$out"
[ "$out" = 'rang 2 reason=dialog-sink-failed' ]
cat "${rec%.msg}.ring-reason"
printf 'ladder: %s\n' "$(cat "$FM_HOME/state/parent-route/rsm.inbox/.ring-state")"
out=$(bin/fm-remote-secondmate-control.sh inbox rsm due 0 1)
printf 'due protocol: %s\n' "$out"
[ "$out" = 'escalate 001.msg 1 reason=dialog-sink-failed' ]
[ ! -e "$FM_HOME/state/parent-route/rsm.inbox/.busy-state" ]
cmp "$rec" "$FM_HOME/remote-original.msg"
printf 'Remote notice, rang and escalation carry the same reason; .msg bytes unchanged and no remote busy budget created.\n'
