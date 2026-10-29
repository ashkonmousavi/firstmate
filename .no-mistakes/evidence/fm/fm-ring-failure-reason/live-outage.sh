#!/usr/bin/env bash
set -eu
export RING_ROOT="$PWD" RING_LAB_SESSION=fm-lab-ring-reasons-01m64 RING_ORIGINAL_PATH="$PATH"
export TMPDIR="$PWD/.tmp-ring-validation" FM_HERDR_LAB_STATE_DIR="$PWD/.tmp-ring-validation/herdr-state"
export RING_OUTAGE_LOG=~/.no-mistakes/evidence/01M64NPQ8218XYJRT9WNGFRNBA/outage-stop.json
export PATH="$PWD/.tmp-ring-validation/bin:$PATH" FM_HOME="$(cat .tmp-ring-validation/lab-home)"
. bin/fm-task-inbox-lib.sh
rec=$(fm_task_inbox_write "$FM_HOME/state" outage 'Do not execute anything; this is outage validation.')
cp "$rec" "$FM_HOME/outage-original.msg"
printf 'Before ring, real agent state: %s\n' "$(fm_backend_agent_state herdr "$RING_LAB_SESSION:w1:p1")"
touch .tmp-ring-validation/outage-armed
rc=0
fm_task_inbox_ring herdr "$RING_LAB_SESSION:w1:p1" "$rec" > "$FM_HOME/outage.stdout" || rc=$?
printf 'After actual Enter, guarded lab server stop: %s\n' "$(cat "$RING_OUTAGE_LOG")"
printf 'Outage ring: rc=%s reason=%s stdout_bytes=%s sibling=%s\n' "$rc" "$FM_TASK_INBOX_RING_REASON" "$(wc -c < "$FM_HOME/outage.stdout")" "$(cat "${rec%.msg}.ring-reason")"
[ "$rc" = 4 ] && [ "$FM_TASK_INBOX_RING_REASON" = status-unknown ] && [ ! -s "$FM_HOME/outage.stdout" ]
cmp "$rec" "$FM_HOME/outage-original.msg"
printf 'Outage retained the original .msg bytes. No backend responses were fabricated.\n'
