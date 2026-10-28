#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M61T4DT0DWZ6683608ERTGB5
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "$ROOT/.dXXXXXX")
bash bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME=$LAB TMUX_TMPDIR="$LAB/tmux"
mkdir -p "$LAB/tmux"
tmux -L fm-lab new-session -d -s primary -x 160 -y 40 -c "$ROOT" 'bash --noprofile --norc'
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),0,0"
cleanup() { tmux -L fm-lab kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
cat > "$LAB/state/mate.meta" <<EOF
window=primary:0
backend=tmux
endpoint_task_id=mate
worktree=$ROOT
project=$ROOT
harness=claude
kind=secondmate
mode=secondmate
home=$LAB
projects=alpha
EOF
. bin/fm-task-inbox-lib.sh
. bin/fm-pending-reply-lib.sh
payload=$'Status only; no reply required.\nPreserve the second line.'
request=11111111111111111111111111111111
printf '$ fm-send mate --one-way <two-line steer>\n'
FM_SEND_REQUEST_ID=$request bash bin/fm-send.sh mate --one-way "$payload"
rec="$LAB/state/mate.inbox/001.msg"
cat "$rec"
[ -z "$(ls -A "$LAB/state/pending-replies" 2>/dev/null || true)" ]
printf 'pending-replies after one-way: empty\n'
printf '$ retry the identical request before and after acknowledgement\n'
FM_SEND_REQUEST_ID=$request bash bin/fm-send.sh mate --one-way "$payload"
[ ! -e "$LAB/state/mate.inbox/002.msg" ]
mv "$rec" "$LAB/state/mate.inbox/handled/"
FM_SEND_REQUEST_ID=$request bash bin/fm-send.sh mate --one-way "$payload"
[ ! -e "$LAB/state/mate.inbox/002.msg" ]
printf '$ deliberate repeat with a new request identity\n'
FM_SEND_REQUEST_ID=22222222222222222222222222222222 bash bin/fm-send.sh mate --one-way "$payload"
[ -f "$LAB/state/mate.inbox/002.msg" ]
printf '$ reuse first identity with conflicting body (must refuse)\n'
if FM_SEND_REQUEST_ID=$request bash bin/fm-send.sh mate --one-way 'different steer'; then exit 1; fi
[ ! -e "$LAB/state/mate.inbox/003.msg" ]
for args in '--fire-and-forget 0123456789abcdef' '--key Enter' '--resolve-key missing'; do
  printf '$ reject --one-way %s\n' "$args"
  if bash bin/fm-send.sh mate --one-way $args; then exit 1; fi
done
printf '$ ordinary correlated send for a notice and an unrelated genuine ask\n'
bash bin/fm-send.sh mate 'Notice already acted on; no reply needed'
bash bin/fm-send.sh mate 'Please report genuine task completion'
corr=$(fm_task_inbox_body "$LAB/state/mate.inbox/003.msg" | sed -n 's/.*corr=\([a-f0-9]\{16\}\).*/\1/p')
other=$(fm_task_inbox_body "$LAB/state/mate.inbox/004.msg" | sed -n 's/.*corr=\([a-f0-9]\{16\}\).*/\1/p')
[ -n "$corr" ] && [ -n "$other" ] && [ "$corr" != "$other" ]
acked_rec="$LAB/state/pending-replies/$corr"
other_rec="$LAB/state/pending-replies/$other"
mv "$LAB/state/mate.inbox/003.msg" "$LAB/state/mate.inbox/handled/"
[ "$(fm_pending_reply_get "$acked_rec" phase)" != resolved ]
printf 'moving the inbox record to handled left its correlation open: %s\n' "$corr"
# Seed the documented persisted escalation state for both real send-created correlations.
for id in "$corr" "$other"; do
  file="$LAB/state/pending-replies/$id"
  printf 'blocked [key=pending-reply-%s]: %s\n' "$id" "$(fm_pending_reply_escalation_payload "$file" missed)" >> "$LAB/state/mate.status"
  fm_pending_reply_set "$file" phase escalated
  fm_pending_reply_set "$file" escalated_epoch "$(date +%s)"
done
cp "$LAB/state/mate.status" "$EVIDENCE/correlation-status-before.txt"
printf '$ acknowledge exact notice correlation\n'
bash bin/fm-pending-reply-ack-handled.sh mate "$corr"
bash bin/fm-pending-reply-ack-handled.sh mate "$corr"
[ "$(fm_pending_reply_get "$acked_rec" phase)" = resolved ]
[ "$(fm_pending_reply_get "$acked_rec" resolved_via)" = handled ]
[ "$(fm_pending_reply_get "$other_rec" phase)" = escalated ]
touch "$LAB/state/wrong.status"
if bash bin/fm-pending-reply-ack-handled.sh wrong "$other"; then exit 1; fi
if bash bin/fm-pending-reply-ack-handled.sh mate invalid; then exit 1; fi
open=$(status_open_decisions "$LAB/state/mate.status")
case "$open" in *"pending-reply-$corr"*) exit 1;; esac
case "$open" in *"pending-reply-$other"*) ;; *) exit 1;; esac
printf 'Remaining open decision:\n%s\n' "$open"
cp "$LAB/state/mate.status" "$EVIDENCE/correlation-status-after.txt"
cp "$acked_rec" "$EVIDENCE/correlation-acked.record"
cp "$other_rec" "$EVIDENCE/correlation-kept.record"
printf 'PASS: one-way durability, identity, conflicts, flag guards, explicit closure, unrelated debt preservation\n'
