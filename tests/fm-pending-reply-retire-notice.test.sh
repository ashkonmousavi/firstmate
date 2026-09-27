#!/usr/bin/env bash
# Exact historical notice retirement closes only its own pending-reply blocker.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"

RETIRE="$ROOT/bin/fm-pending-reply-retire-notice.sh"
home=$(fm_test_tmproot fm-retire-notice)
mkdir -p "$home/state"
touch "$home/state/mate.status"
notice=$(fm_pending_reply_create "$home" "$home/state" mate 'routine reread notice')
request=$(fm_pending_reply_create "$home" "$home/state" mate 'please report completion')
notice_rec=$(fm_pending_reply_path "$home/state" "$notice")
request_rec=$(fm_pending_reply_path "$home/state" "$request")
for rec in "$notice_rec" "$request_rec"; do
  corr=$(fm_pending_reply_get "$rec" corr_id)
  payload=$(fm_pending_reply_escalation_payload "$rec" missed)
  printf 'blocked [key=pending-reply-%s]: %s\n' "$corr" "$payload" >> "$home/state/mate.status"
  fm_pending_reply_set "$rec" escalated_epoch 123
  fm_pending_reply_set "$rec" phase escalated
done

before=$(status_open_decisions "$home/state/mate.status")
[ "$(printf '%s\n' "$before" | grep -c 'pending-reply-')" -eq 2 ] || fail "fixture should have two open blockers"
FM_HOME="$home" "$RETIRE" mate "$notice" >/dev/null || fail "exact notice retirement failed"
after=$(status_open_decisions "$home/state/mate.status")
case "$after" in *"pending-reply-$notice"*) fail "retired notice blocker remains open" ;; esac
case "$after" in *"pending-reply-$request"*) ;; *) fail "unrelated reply blocker was closed" ;; esac
[ "$(fm_pending_reply_get "$notice_rec" resolved_via)" = notice ] || fail "notice resolution not recorded"
[ "$(fm_pending_reply_get "$request_rec" phase)" = escalated ] || fail "unrelated request record changed"
FM_HOME="$home" "$RETIRE" mate "$notice" >/dev/null || fail "retirement must be idempotent"
if FM_HOME="$home" "$RETIRE" other "$request" >/dev/null 2>&1; then fail "wrong task identity accepted"; fi
if FM_HOME="$home" "$RETIRE" mate 'bad-id' >/dev/null 2>&1; then fail "bad correlation accepted"; fi
pass "historical notice retirement closes only the exact correlation"
