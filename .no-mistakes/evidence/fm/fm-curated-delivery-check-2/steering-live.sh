#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M63G7WF3X155CM0Z0SN1J1EQ
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
cleanup() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
# A real, unresponsive terminal validates enqueue without pretending to be a harness.
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s fixture -n fm-mate -x 220 -y 50 -c "$PWD" 'sleep 180'
export TMUX_TMPDIR="$LAB/tmux"
export TMUX=$(tmux -L fm-lab display-message -p -t fixture '#{socket_path}'),0,0
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_PENDING_REPLY_EXISTING_CORR FM_PENDING_REPLY_DIR_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TASK_ID
printf 'window=fixture:fm-mate\nendpoint_task_id=mate\nworktree=%s\nproject=%s\nharness=codex\nkind=secondmate\nmode=secondmate\nhome=%s\n' "$LAB" "$LAB" "$LAB" > "$LAB/state/mate.meta"
: > "$LAB/state/mate.status"
RID=0123456789abcdef0123456789abcdef
send_oneway() { FM_SEND_REQUEST_ID="$RID" "$ROOT/bin/fm-send.sh" mate --one-way 'Review the next delivery report; no reply needed.'; }
send_oneway
REC="$LAB/state/mate.inbox/001.msg"
cat "$REC"
[ ! -d "$LAB/state/pending-replies" ] || [ -z "$(ls -A "$LAB/state/pending-replies")" ]
send_oneway
[ "$(ls "$LAB/state/mate.inbox/"*.msg | wc -l)" -eq 1 ]
mkdir -p "$LAB/state/mate.inbox/handled"
mv "$REC" "$LAB/state/mate.inbox/handled/"
send_oneway
[ ! -f "$REC" ]
[ "$(ls "$LAB/state/mate.inbox/handled/"*.msg | wc -l)" -eq 1 ]
FM_SEND_REQUEST_ID=1123456789abcdef0123456789abcdef "$ROOT/bin/fm-send.sh" mate --one-way 'Review the next delivery report; no reply needed.'
[ -f "$LAB/state/mate.inbox/002.msg" ]
if FM_SEND_REQUEST_ID="$RID" "$ROOT/bin/fm-send.sh" mate --one-way 'A conflicting payload'; then exit 20; fi
for bad in '--fire-and-forget 0123456789abcdef' '--key Enter' '--resolve-key pending-test'; do
  if "$ROOT/bin/fm-send.sh" mate --one-way $bad 'not allowed'; then exit 21; fi
done
printf '\nOne-way retry identity retained after acknowledgement; an intentional repeat created 002.msg; conflicting reuse and incompatible flags refused.\n'
# Generate ordinary requests through the public CLI, then close exactly one.
"$ROOT/bin/fm-send.sh" mate 'Please report readiness.'
"$ROOT/bin/fm-send.sh" mate 'Please report the final result.'
. "$ROOT/bin/fm-pending-reply-lib.sh"
CORRS=("$LAB/state/pending-replies/"*)
[ "${#CORRS[@]}" -eq 2 ]
C1=${CORRS[0]##*/}
C2=${CORRS[1]##*/}
for corr in "$C1" "$C2"; do
 r=$(fm_pending_reply_path "$LAB/state" "$corr")
 printf 'blocked [key=pending-reply-%s]: %s\n' "$corr" "$(fm_pending_reply_escalation_payload "$r" missed)" >> "$LAB/state/mate.status"
 fm_pending_reply_set "$r" phase escalated
 fm_pending_reply_set "$r" escalated_epoch 123
done
"$ROOT/bin/fm-pending-reply-ack-handled.sh" mate "$C1"
"$ROOT/bin/fm-pending-reply-ack-handled.sh" mate "$C1"
[ "$(fm_pending_reply_get "${CORRS[0]}" resolved_via)" = handled ]
[ "$(fm_pending_reply_get "${CORRS[1]}" phase)" = escalated ]
if "$ROOT/bin/fm-pending-reply-ack-handled.sh" other "$C2"; then exit 22; fi
if "$ROOT/bin/fm-pending-reply-ack-handled.sh" mate bad-id; then exit 23; fi
printf '\nParent status after exact closure:\n'
cat "$LAB/state/mate.status"
printf '\nRemaining open decisions:\n'
status_open_decisions "$LAB/state/mate.status"
case "$(status_open_decisions "$LAB/state/mate.status")" in *"pending-reply-$C1"*) exit 24 ;; esac
case "$(status_open_decisions "$LAB/state/mate.status")" in *"pending-reply-$C2"*) ;; *) exit 25 ;; esac
printf '\nResolved correlation persisted as handled; unrelated correlation remains escalated.\n'
