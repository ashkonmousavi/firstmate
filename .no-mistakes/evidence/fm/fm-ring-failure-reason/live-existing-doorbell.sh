#!/usr/bin/env bash
set -eu
export RING_ROOT="$PWD" RING_LAB_SESSION=fm-lab-ring-reasons-01m64 RING_ORIGINAL_PATH="$PATH"
export TMPDIR="$PWD/.tmp-ring-validation" FM_HERDR_LAB_STATE_DIR="$PWD/.tmp-ring-validation/herdr-state"
export FM_HOME="$(cat .tmp-ring-validation/lab-home)"
export RING_OUTAGE_LOG=~/.no-mistakes/evidence/01M64NPQ8218XYJRT9WNGFRNBA/existing-outage-stop.json
bin/fm-herdr-lab.sh provision "$RING_LAB_SESSION"
bin/fm-herdr-lab.sh run "$RING_LAB_SESSION" agent start ring-existing --kind claude --pane w1:p1 --timeout 15000
export PATH="$PWD/.tmp-ring-validation/bin:$PATH"
. bin/fm-task-inbox-lib.sh
fm_backend_source herdr
rec=$(fm_task_inbox_write "$FM_HOME/state" existing 'Live validation: no actions required.')
cp "$rec" "$FM_HOME/existing-original.msg"
line=$(fm_task_inbox_doorbell_line "$rec")
# The already-typed, owned doorbell exercises Enter-only confirmation.
fm_backend_herdr_send_literal "$RING_LAB_SESSION:w1:p1" "$line"
for i in $(seq 1 20); do
  if fm_task_inbox_composer_holds herdr "$RING_LAB_SESSION:w1:p1" "$line"; then break; fi
  sleep 0.1
done
fm_task_inbox_composer_holds herdr "$RING_LAB_SESSION:w1:p1" "$line"
printf 'Existing own doorbell shown before Enter.\n'
touch .tmp-ring-validation/outage-armed
rc=0
fm_task_inbox_ring herdr "$RING_LAB_SESSION:w1:p1" "$rec" > "$FM_HOME/existing.stdout" || rc=$?
printf 'After real Enter and guarded server stop: rc=%s reason=%s stdout_bytes=%s sibling=%s\n' "$rc" "$FM_TASK_INBOX_RING_REASON" "$(wc -c < "$FM_HOME/existing.stdout")" "$(cat "${rec%.msg}.ring-reason")"
[ "$rc" = 4 ] && [ "$FM_TASK_INBOX_RING_REASON" = post-enter-unreadable ] && [ ! -s "$FM_HOME/existing.stdout" ]
cmp "$rec" "$FM_HOME/existing-original.msg"
printf 'Existing-doorbell failure retained the original .msg bytes.\n'
