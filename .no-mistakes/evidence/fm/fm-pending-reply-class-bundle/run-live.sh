#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M65B69RB6KVB3GE3TWHGKXGE
LABROOT="$ROOT/.lv"
mkdir -p "$LABROOT/tmp" "$LABROOT/account"
export TMPDIR="$LABROOT/tmp"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_PENDING_REPLY_SEND_HOOK FM_PENDING_REPLY_REMOTE_PROBE_HOOK
. bin/fm-pending-reply-lib.sh
. bin/fm-task-inbox-lib.sh
export FM_PENDING_REPLY_GRACE_SECS=0 FM_SEND_SETTLE=0 FM_SSH_BIN="$LABROOT/ssh"
WATCH_PID=''
stop_watch() {
  if [ -n "$WATCH_PID" ]; then
    kill -TERM -- "-$WATCH_PID" 2>/dev/null || true
    rc=0; wait "$WATCH_PID" || rc=$?
    printf 'watcher exit=%s (0=wake,143=deliberate test stop)\n' "$rc"
    case "$rc" in 0|143) ;; *) return "$rc" ;; esac
    WATCH_PID=''
  fi
}
trap 'stop_watch' EXIT
for name in p r; do bin/fm-lab-home.sh create "$LABROOT/$name"; done
P="$LABROOT/p"; R="$LABROOT/r"; S="$P/state"
export FM_HOME="$P"
printf 'rsm\n' > "$R/.fm-secondmate-home"
ln -s "$ROOT/AGENTS.md" "$R/AGENTS.md"
mkdir "$R/bin"
mkdir -p "$R/state/parent-route"
cat > "$R/state/parent-route/rsm.meta" <<EOF
window=fm-remote:p1
backend=herdr
endpoint_task_id=rsm
harness=claude
herdr_session=fm-remote
herdr_workspace_id=w1
herdr_tab_id=t1
herdr_pane_id=p1
EOF
cat > "$P/data/secondmates.md" <<EOF
- rsm - disposable remote (host: fm-validation; root: $ROOT; home: $R; scope: test; projects: none; added 2026-10-29)
EOF
cat > "$S/rsm.meta" <<EOF
kind=secondmate
mode=secondmate
remote_host=fm-validation
remote_root=$ROOT
remote_backend=herdr
EOF
start_watch() {
  drain=$(FM_HOME="$P" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  ack=$(printf '%s\n' "$drain" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
  if [ -n "$ack" ]; then
    read -r -a ack_args <<< "$ack"
    FM_HOME="$P" "$ROOT/bin/fm-wake-drain.sh" "${ack_args[@]}" >/dev/null
  fi
  touch "$S/.secondmate-liveness-tick" "$S/home-summary.json"
  setsid env FM_HOME="$P" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=3600 FM_HOME_SUMMARY_INTERVAL=3600 FM_TASK_INBOX_GRACE_SECS=1 FM_SECONDMATE_LIVENESS_SECS=3600 "$ROOT/bin/fm-watch.sh" >> "$EVIDENCE/watcher-runtime.log" 2>&1 &
  WATCH_PID=$!
}
get() { fm_pending_reply_get "$(fm_pending_reply_path "$S" "$1")" "$2"; }
wait_phase() {
  for ((tries=0;tries<200;tries++)); do
    [ "$(get "$1" phase)" != "$2" ] || return 0
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then stop_watch; start_watch; fi
    sleep 0.1
  done
  printf 'FAILED expected %s phase=%s actual=%s\n' "$1" "$2" "$(get "$1" phase)"; return 1
}
printf '\nSCENARIO A2: full-body notices versus reporting requests\n'
notice_bodies=(
 'No reply needed. The walk results are attached.'
 'No reply needed. Results are in data/report.md.'
 'No action needed. Results are in data/report.md.'
 'walk end: checkpoint finished.'
 'Firstmate updated to v-test.'
 'A long message body preceding the waiver deliberately extends beyond the stored summary size, by including enough unrelated informational words for this verification. No reply needed. Results attached.'
)
request_bodies=(
 'walk end: checkpoint finished. Can you report the failures?'
 'walk end: checkpoint finished. When ready, report the failures.'
 'No reply needed. Please report back after the check.'
 'No reply needed. When ready, reply with the failures.'
 'Please investigate why "No reply needed" notices open blockers and report the result.'
)
notices=(); requests=()
for body in "${notice_bodies[@]}"; do corr=$(fm_pending_reply_create "$P" "$S" notice "$body"); notices+=("$corr"); fm_pending_reply_mark_delivery_unknown "$S" "$corr"; printf 'notice body=%q corr=%s one_way=%s\n' "$body" "$corr" "$(get "$corr" one_way)"; done
for body in "${request_bodies[@]}"; do corr=$(fm_pending_reply_create "$P" "$S" request "$body"); requests+=("$corr"); fm_pending_reply_mark_delivered "$S" "$corr"; printf 'request body=%q corr=%s one_way=%s\n' "$body" "$corr" "$(get "$corr" one_way)"; done
start_watch
for corr in "${notices[@]}"; do wait_phase "$corr" resolved; [ "$(get "$corr" resolved_via)" = one-way-notice ]; printf 'notice corr=%s phase=%s resolved_via=%s\n' "$corr" "$(get "$corr" phase)" "$(get "$corr" resolved_via)"; done
for corr in "${requests[@]}"; do [ "$(get "$corr" phase)" = awaiting_report ]; [ -z "$(get "$corr" one_way)" ]; printf 'request corr=%s phase=%s\n' "$corr" "$(get "$corr" phase)"; done
stop_watch
# Retire fixture reporting requests from further scenarios by supplying actual correlated parent-channel results.
for corr in "${requests[@]}"; do printf 'working: result received corr=%s\n' "$corr" >> "$S/request.status"; done
printf '\nSCENARIO D1: real SSH probe, unread then handled then absent\n'
landed=$(fm_pending_reply_create "$P" "$S" rsm 'report the landed build')
missing=$(fm_pending_reply_create "$P" "$S" rsm 'report the missing build')
rec=$(fm_task_inbox_write_idempotent "$R/state/parent-route" rsm "corr=$landed report the landed build")
answer=$(bin/fm-on.sh rsm fm-remote-secondmate-control.sh probe rsm "$landed"); printf 'unread probe corr=%s answer=%s\n' "$landed" "$answer"; [ "$answer" = landed ]
mv "$rec" "${rec%/*}/handled/${rec##*/}"
answer=$(bin/fm-on.sh rsm fm-remote-secondmate-control.sh probe rsm "$landed"); printf 'handled probe corr=%s answer=%s\n' "$landed" "$answer"; [ "$answer" = landed ]
answer=$(bin/fm-on.sh rsm fm-remote-secondmate-control.sh probe rsm "$missing"); printf 'absent probe corr=%s answer=%s\n' "$missing" "$answer"; [ "$answer" = absent ]
fm_pending_reply_mark_delivery_unknown "$S" "$landed"
fm_pending_reply_prepare_delivery "$S" "$missing"
start_watch
wait_phase "$landed" awaiting_report
wait_phase "$missing" escalated
[ -n "$(get "$landed" delivered_epoch)" ]
printf 'found remote corr=%s phase=%s delivered_epoch=%s\n' "$landed" "$(get "$landed" phase)" "$(get "$landed" delivered_epoch)"
printf 'missing remote corr=%s phase=%s\n' "$missing" "$(get "$missing" phase)"
cat "$S/rsm.status"
stop_watch
# Close both with genuine correlated reports before the slow-transport scenario.
printf 'working: completed corr=%s\nworking: completed corr=%s\n' "$landed" "$missing" >> "$S/rsm.status"
fm_pending_reply_try_resolve "$S" "$landed"
fm_pending_reply_try_resolve "$S" "$missing"
printf '\nNotice and real SSH probe scenarios passed.\n'
