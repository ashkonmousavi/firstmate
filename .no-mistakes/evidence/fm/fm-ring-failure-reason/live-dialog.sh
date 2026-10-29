#!/usr/bin/env bash
set -eu
export RING_ROOT="$PWD" RING_LAB_SESSION=fm-lab-ring-reasons-01m64 RING_ORIGINAL_PATH="$PATH"
export TMPDIR="$PWD/.tmp-ring-validation" FM_HERDR_LAB_STATE_DIR="$PWD/.tmp-ring-validation/herdr-state"
export PATH="$PWD/.tmp-ring-validation/bin:$PATH" FM_HOME="$(cat .tmp-ring-validation/lab-home)"
. bin/fm-task-inbox-lib.sh
fm_backend_source herdr
rec=$(fm_task_inbox_write "$FM_HOME/state" preflight 'Live validation only; preserve this record.')
cp "$rec" "$FM_HOME/preflight-original.msg"
target="$RING_LAB_SESSION:w1:p1"
rc=0
fm_task_inbox_ring herdr "$target" "$rec" > "$FM_HOME/success.stdout" || rc=$?
printf 'Fresh ring: rc=%s reason=%s sibling=%s stdout_bytes=%s\n' "$rc" "$FM_TASK_INBOX_RING_REASON" "$(cat "${rec%.msg}.ring-reason")" "$(wc -c < "$FM_HOME/success.stdout")"
cmp "$rec" "$FM_HOME/preflight-original.msg"
[ "$rc" = 2 ] && [ "$FM_TASK_INBOX_RING_REASON" = preflight-dialog ] && [ ! -s "$FM_HOME/success.stdout" ]
