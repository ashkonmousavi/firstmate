#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
home=$ROOT/.validation-lab/ack-home
bin/fm-lab-home.sh create "$home" >/dev/null
unset FM_STATE_OVERRIDE FM_PENDING_REPLY_DIR_OVERRIDE
. bin/fm-pending-reply-lib.sh
: > "$home/state/mate.status"
a=$(fm_pending_reply_create "$home" "$home/state" mate 'status only')
b=$(fm_pending_reply_create "$home" "$home/state" mate 'report completion')
for corr in "$a" "$b"; do
 rec=$(fm_pending_reply_path "$home/state" "$corr")
 printf 'blocked [key=pending-reply-%s]: %s\n' "$corr" "$(fm_pending_reply_escalation_payload "$rec" missed)" >> "$home/state/mate.status"
 fm_pending_reply_set "$rec" escalated_epoch 123
 fm_pending_reply_set "$rec" phase escalated
done
mkdir -p "$home/state/mate.inbox/handled"
printf 'from-firstmate corr=%s status only\n' "$a" > "$home/state/mate.inbox/001.msg"
mv "$home/state/mate.inbox/001.msg" "$home/state/mate.inbox/handled/"
printf 'AFTER INBOX ACK ONLY: phase=%s\n' "$(fm_pending_reply_get "$(fm_pending_reply_path "$home/state" "$a")" phase)"
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$home/state" "$a")" phase)" = escalated ]
FM_HOME="$home" bin/fm-pending-reply-ack-handled.sh mate "$a"
FM_HOME="$home" bin/fm-pending-reply-ack-handled.sh mate "$a"
printf 'WRONG TASK ATTEMPT:\n'
if FM_HOME="$home" bin/fm-pending-reply-ack-handled.sh other "$a"; then exit 1; fi
printf 'ACKNOWLEDGED RECORD:\n'
cat "$(fm_pending_reply_path "$home/state" "$a")"
printf 'UNRELATED RECORD STILL OPEN: phase=%s\n' "$(fm_pending_reply_get "$(fm_pending_reply_path "$home/state" "$b")" phase)"
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$home/state" "$b")" phase)" = escalated ]
printf 'PARENT STATUS:\n'
cat "$home/state/mate.status"
