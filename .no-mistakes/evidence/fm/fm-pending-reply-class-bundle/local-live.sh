#!/usr/bin/env bash
set -eu
ROOT=$PWD; LAB="$ROOT/.lv/l"; STATE="$LAB/state"; EVIDENCE=~/.no-mistakes/evidence/01M65B69RB6KVB3GE3TWHGKXGE
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" FM_SEND_SETTLE=0 FM_PENDING_REPLY_GRACE_SECS=0
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_PENDING_REPLY_SEND_HOOK FM_PENDING_REPLY_REMOTE_PROBE_HOOK
export TMUX=$(tmux -L fm-lab display-message -p -t primary '#{socket_path},#{pid},#{session_id}')
. bin/fm-pending-reply-lib.sh
. bin/fm-task-inbox-lib.sh
touch "$LAB/config/wait-no-turns"
cat > "$STATE/mate.meta" <<EOF
window=primary:fm-mate
endpoint_task_id=mate
worktree=$ROOT
project=$ROOT
harness=claude
kind=secondmate
mode=secondmate
yolo=off
home=$LAB
EOF
printf '\nSCENARIO E: real recovery enqueue with old decision; newer/equal/unknown decisions hold\n'
for scenario in old-default new-default equal unknown old-key-prose; do
  corr=$(fm_pending_reply_create "$LAB" "$STATE" mate "Report only a one-line verification response for scenario $scenario; do not use tools.")
  created=$(fm_pending_reply_get "$(fm_pending_reply_path "$STATE" "$corr")" created_epoch)
  case "$scenario" in
    old-default) event="needs-decision [at=$((created-120))]: choose"; expected=send ;;
    old-key-prose) event="needs-decision [at=$((created-120))] [key=choice]: choose"; expected=send ;;
    new-default) event="needs-decision [at=$((created+120))]: choose"; expected=hold ;;
    equal) event="needs-decision [at=$created]: choose"; expected=hold ;;
    unknown) event='needs-decision [at=bad]: choose'; expected=hold ;;
  esac
  printf '%s\n' "$event" > "$STATE/mate.status"
  if [ "$scenario" = old-key-prose ]; then printf 'working [at=%s]: mentions [key=choice], quoted [at=%s]\n' "$((created+60))" "$((created+180))" >> "$STATE/mate.status"; fi
  fm_pending_reply_mark_delivered "$STATE" "$corr"
  fm_pending_reply_observe_busy "$STATE" "$corr" busy
  fm_pending_reply_observe_busy "$STATE" "$corr" idle
  rc=0; fm_pending_reply_send_recovery "$STATE" "$corr" || rc=$?
  rec=$(fm_pending_reply_path "$STATE" "$corr")
  phase=$(fm_pending_reply_get "$rec" phase)
  attempted=$(fm_pending_reply_get "$rec" recovery_attempted_epoch)
  printf 'case=%s corr=%s request_epoch=%s decision=%q expected=%s recovery_exit=%s phase=%s attempted=%s\n' "$scenario" "$corr" "$created" "$event" "$expected" "$rc" "$phase" "$attempted"
  if [ "$expected" = hold ]; then [ "$rc" != 0 ]; [ -z "$attempted" ]; [ "$phase" = awaiting_report ];
  else
    [ "$rc" = 0 ]; [ "$phase" = recovery_sent ]; [ -n "$attempted" ]
    found=0
    for msg in "$STATE/mate.inbox"/*.msg "$STATE/mate.inbox/handled"/*.msg; do
      [ -f "$msg" ] || continue
      if fm_task_inbox_body "$msg" | grep -F "corr=$corr" >/dev/null; then
        printf 'actual enqueued recovery record=%s\n' "$msg"; fm_task_inbox_body "$msg"; printf '\n'; found=1
      fi
    done
    [ "$found" = 1 ]
  fi
  fm_pending_reply_send_recovery "$STATE" "$corr" >/dev/null 2>&1 && { echo 'unexpected second recovery'; exit 1; } || true
done
printf '\nSCENARIO A2 delivery CLI: full body notice persists through fm-send\n'
bin/fm-send.sh mate 'No reply needed. Results are in data/report.md.'
for rec in "$STATE/pending-replies"/*; do
  [ -f "$rec" ] || continue
  if [ "$(fm_pending_reply_get "$rec" one_way)" = 1 ]; then
    corr=$(fm_pending_reply_get "$rec" corr_id)
    fm_pending_reply_try_resolve "$STATE" "$corr"
    printf 'fm-send notice corr=%s phase=%s via=%s\n' "$corr" "$(fm_pending_reply_get "$rec" phase)" "$(fm_pending_reply_get "$rec" resolved_via)"
    [ "$(fm_pending_reply_get "$rec" phase)" = resolved ]
  fi
done
tmux -L fm-lab capture-pane -p -t primary > "$EVIDENCE/claude-lab-pane.txt"
printf '\nAll real Claude local delivery and recovery scenarios passed.\n'
