#!/usr/bin/env bash
set -eu
export FM_HOME="$(cat .tmp-ring-validation/lab-home)"
export TMPDIR="$PWD/.tmp-ring-validation"
export FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=1
. bin/fm-watch.sh
cat > "$STATE/rsm.meta" <<'META'
window=fm-remote:w1:p1
kind=secondmate
remote_host=disposable-local-transport
META
# Transport-only substitution: invoke the actual host-local controller directly,
# retaining its real stdout, stderr, exit status and durable inbox state.
remote_inbox_hop() { "$SCRIPT_DIR/fm-remote-secondmate-control.sh" inbox "$@"; }
remote_inbox_pass
printf 'Watcher stale wake: %s\n' "$(cat "$STATE/.wake-queue")"
grep -qF 'last ring reason=dialog-sink-failed' "$STATE/.wake-queue"
grep -qF '001.msg' "$STATE/.wake-queue"
printf 'Escalated marker: %s\n' "$(cat "$STATE/parent-route/rsm.inbox/.escalated")"
[ "$(cat "$STATE/parent-route/rsm.inbox/.escalated")" = 001.msg ]
remote_inbox_pass
[ "$(wc -l < "$STATE/.wake-queue")" = 1 ]
printf 'Second pass retained exactly one wake.\n'
