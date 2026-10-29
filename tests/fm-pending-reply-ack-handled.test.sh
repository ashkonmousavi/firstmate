#!/usr/bin/env bash
# The recipient acknowledgement closes only its own pending-reply blocker.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"

# Recipient acknowledgement closes one named correlation and leaves the other open.
ACK="$ROOT/bin/fm-pending-reply-ack-handled.sh"
home=$(fm_test_tmproot fm-ack-handled)
mkdir -p "$home/state"
touch "$home/state/mate.status"
acked=$(fm_pending_reply_create "$home" "$home/state" mate 'status only, no reply')
kept=$(fm_pending_reply_create "$home" "$home/state" mate 'please report completion')
acked_rec=$(fm_pending_reply_path "$home/state" "$acked")
kept_rec=$(fm_pending_reply_path "$home/state" "$kept")
for rec in "$acked_rec" "$kept_rec"; do
  corr=$(fm_pending_reply_get "$rec" corr_id)
  payload=$(fm_pending_reply_escalation_payload "$rec" missed)
  printf 'blocked [key=pending-reply-%s]: %s\n' "$corr" "$payload" >> "$home/state/mate.status"
  fm_pending_reply_set "$rec" escalated_epoch 123
  fm_pending_reply_set "$rec" phase escalated
done
out=$(FM_HOME="$home" "$ACK" mate "$acked") || fail "recipient acknowledgement failed"
[ "$out" = "handled, no reply needed: mate $acked" ] || fail "acknowledgement output differs: $out"
after=$(status_open_decisions "$home/state/mate.status")
case "$after" in *"pending-reply-$acked"*) fail "acknowledged blocker remains open" ;; esac
case "$after" in *"pending-reply-$kept"*) ;; *) fail "unrelated reply blocker was closed" ;; esac
grep -F "via=handled handled, no reply needed" "$home/state/mate.status" >/dev/null ||
  fail "the close note should say handled, no reply needed"
[ "$(fm_pending_reply_get "$acked_rec" resolved_via)" = handled ] || fail "handled resolution not recorded"
[ "$(fm_pending_reply_get "$kept_rec" phase)" = escalated ] || fail "unrelated request record changed"
FM_HOME="$home" "$ACK" mate "$acked" >/dev/null || fail "acknowledgement must be idempotent"
[ "$(fm_pending_reply_get "$acked_rec" resolved_via)" = handled ] || fail "a repeat acknowledgement changed the resolution"
if FM_HOME="$home" "$ACK" other "$acked" >/dev/null 2>&1; then fail "wrong task identity accepted"; fi
if FM_HOME="$home" "$ACK" mate 'bad-id' >/dev/null 2>&1; then fail "bad correlation accepted"; fi
pass "recipient acknowledgement closes only the named correlation as handled, no reply needed"
