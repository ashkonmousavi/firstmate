#!/usr/bin/env bash
# Stale pending-reply retirement keeps superseded records and leaves a live
# newest request open.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PENDING_REPLY_LIB="$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$PENDING_REPLY_LIB"

RETIRE="$ROOT/bin/fm-pending-reply-retire-stale.sh"
NOW=1700000000
export FM_PENDING_REPLY_NOW=$NOW

run_retire() {  # <home> <mode>
  local home=$1 mode=$2
  FM_HOME="$home" FM_PENDING_REPLY_NOW=$NOW "$RETIRE" "$mode"
}

seed_task() {  # <home> <task> <kind>  -- kind empty means no metadata
  local home=$1 task=$2 kind=$3
  mkdir -p "$home/state"
  if [ -n "$kind" ]; then
    printf 'kind=%s\n' "$kind" > "$home/state/$task.meta"
  fi
  : > "$home/state/$task.status"
}

open_reply() {  # <home> <task> <summary> <created_epoch>
  local home=$1 task=$2 summary=$3 created=$4 corr rec
  corr=$(fm_pending_reply_create "$home" "$home/state" "$task" "$summary")
  [ -n "$corr" ] || fail "could not create a pending reply for $task"
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  fm_pending_reply_set "$rec" created_epoch "$created" || fail "could not age $corr"
  printf '%s' "$corr"
}

home=$(fm_test_tmproot fm-retire-stale-transient)
seed_task "$home" mate secondmate
original=$(open_reply "$home" mate 'only delivered unanswered request' $((NOW - 90000)))
original_rec=$(fm_pending_reply_path "$home/state" "$original")
fm_pending_reply_mark_delivered "$home/state" "$original" || fail "could not deliver the original request"
replacement=$(open_reply "$home" mate 'replacement awaiting delivery' $((NOW - 50)))
for delivery_state in created attempted unknown escalated discarded marker-confirmed; do
  case "$delivery_state" in
    attempted) fm_pending_reply_prepare_delivery "$home/state" "$replacement" || fail "could not prepare replacement delivery" ;;
    unknown) fm_pending_reply_mark_delivery_unknown "$home/state" "$replacement" || fail "could not mark replacement delivery unknown" ;;
    escalated) fm_pending_reply_maybe_escalate "$home/state" "$replacement" || fail "could not escalate the undelivered replacement" ;;
    discarded)
      fm_pending_reply_discard_undelivered "$home/state" "$replacement" || fail "could not discard the failed replacement"
      [ ! -f "$(fm_pending_reply_path "$home/state" "$replacement")" ] || fail "failed replacement remained"
      ;;
    marker-confirmed)
      replacement=$(open_reply "$home" mate 'replacement awaiting delivery reconciliation' $((NOW - 40)))
      fm_pending_reply_write_delivery_confirmation "$home/state" "$replacement" confirmed "$NOW" || fail "could not record delivery confirmation"
      ;;
  esac
  dry=$(run_retire "$home" --dry-run) || fail "dry-run failed with $delivery_state replacement"
  [ -z "$dry" ] || fail "$delivery_state replacement incorrectly superseded the original request"
  applied=$(run_retire "$home" --apply) || fail "apply failed with $delivery_state replacement"
  [ -z "$applied" ] || fail "apply retired against a $delivery_state replacement"
  [ "$(fm_pending_reply_get "$original_rec" phase)" = awaiting_report ] || fail "$delivery_state replacement retired the original request"
  [ -z "$(fm_pending_reply_get "$original_rec" retired_reason)" ] || fail "$delivery_state replacement left a retirement reason"
  if grep -F "pending-reply-retired-stale:" "$home/state/mate.status" >/dev/null; then
    fail "$delivery_state replacement published a retirement note"
  fi
done
fm_pending_reply_reconcile_delivery "$home/state" "$replacement" || fail "could not reconcile confirmed replacement delivery"
transient=$(open_reply "$home" mate 'newest replacement still in transport' "$NOW")
dry=$(run_retire "$home" --dry-run) || fail "dry-run failed after confirmed replacement delivery"
printf '%s\n' "$dry" | grep -F "corr=$original age=90000 reason=superseded-by-$replacement" >/dev/null ||
  fail "the confirmed replacement was not chosen over a newer transient record"
applied=$(run_retire "$home" --apply) || fail "apply failed after confirmed replacement delivery"
printf '%s\n' "$applied" | grep -F "corr=$original age=90000 reason=superseded-by-$replacement" >/dev/null ||
  fail "apply did not cite the confirmed replacement"
fm_pending_reply_discard_undelivered "$home/state" "$transient" || fail "could not discard the newer transient replacement"
if fm_pending_reply_discard_undelivered "$home/state" "$replacement"; then
  fail "confirmed replacement could still be discarded"
fi
[ "$(fm_pending_reply_get "$original_rec" phase)" = resolved ] || fail "confirmed replacement did not retire the original request"
[ "$(fm_pending_reply_get "$original_rec" retired_reason)" = "superseded-by-$replacement" ] || fail "retirement cited a disposable successor"
[ -f "$(fm_pending_reply_path "$home/state" "$replacement")" ] || fail "the cited successor disappeared"
[ "$(fm_pending_reply_get "$original_rec" request_summary)" = 'only delivered unanswered request' ] || fail "retirement lost the original unanswered request"
pass "only a retained confirmed-delivery successor supersedes an unanswered request"

# A later request supersedes only the older record. The newest stays open.
home=$(fm_test_tmproot fm-retire-stale-super)
seed_task "$home" mate secondmate
older=$(open_reply "$home" mate 'first unanswered ask' $((NOW - 90000)))
newer=$(open_reply "$home" mate 'later ask still waiting' $((NOW - 50)))
fm_pending_reply_mark_delivered "$home/state" "$newer" || fail "could not confirm the successor delivery"
older_rec=$(fm_pending_reply_path "$home/state" "$older")
newer_rec=$(fm_pending_reply_path "$home/state" "$newer")
summary=$(fm_pending_reply_get "$older_rec" request_summary)
older_payload=$(fm_pending_reply_escalation_payload "$older_rec" missed)
newer_payload=$(fm_pending_reply_escalation_payload "$newer_rec" missed)
printf 'blocked [key=pending-reply-%s]: %s\n' "$older" "$older_payload" >> "$home/state/mate.status"
printf 'blocked [key=pending-reply-%s]: %s\n' "$newer" "$newer_payload" >> "$home/state/mate.status"
fm_pending_reply_set "$older_rec" escalated_epoch 123
fm_pending_reply_set "$older_rec" phase escalated
fm_pending_reply_set "$newer_rec" escalated_epoch 123
fm_pending_reply_set "$newer_rec" phase escalated
dry=$(run_retire "$home" --dry-run) || fail "dry-run failed for a superseded record"
printf '%s\n' "$dry" | grep -F "would-retire task=mate corr=$older age=90000 reason=superseded-by-$newer" >/dev/null ||
  fail "dry-run did not list the superseded record: $dry"
printf '%s\n' "$dry" | grep -F "corr=$newer" >/dev/null &&
  fail "dry-run listed the newest unanswered record"
[ "$(fm_pending_reply_get "$older_rec" phase)" = escalated ] || fail "dry-run changed the old record"
case "$(status_open_decisions "$home/state/mate.status")" in
  *"pending-reply-$older"*) ;;
  *) fail "dry-run closed the superseded blocker" ;;
esac
applied=$(run_retire "$home" --apply) || fail "apply failed for a superseded record"
printf '%s\n' "$applied" | grep -F "retired task=mate corr=$older age=90000 reason=superseded-by-$newer" >/dev/null ||
  fail "apply did not report the retirement: $applied"
[ "$(fm_pending_reply_get "$older_rec" phase)" = resolved ] || fail "superseded record was not resolved"
[ "$(fm_pending_reply_get "$older_rec" resolved_via)" = retired-stale ] || fail "resolved_via was not retired-stale"
[ "$(fm_pending_reply_get "$older_rec" retired_reason)" = "superseded-by-$newer" ] || fail "reason was not stored"
[ "$(fm_pending_reply_get "$older_rec" request_summary)" = "$summary" ] || fail "the unanswered request text was dropped"
[ -f "$older_rec" ] || fail "the retired record file was deleted"
[ "$(fm_pending_reply_get "$newer_rec" phase)" = escalated ] || fail "the newest record was retired"
grep -F "pending-reply-retired-stale: task=mate pending-reply-id=$older reason=superseded-by-$newer age=90000" \
  "$home/state/mate.status" >/dev/null || fail "the status log has no retirement note"
grep -F "via=retired-stale superseded-by-$newer" "$home/state/mate.status" >/dev/null ||
  fail "the escalation close did not record why"
case "$(status_open_decisions "$home/state/mate.status")" in
  *"pending-reply-$older"*) fail "retired blocker remains open" ;;
esac
case "$(status_open_decisions "$home/state/mate.status")" in
  *"pending-reply-$newer"*) ;;
  *) fail "the newest blocker was closed" ;;
esac
run_retire "$home" --apply >/dev/null || fail "a second apply must succeed"
[ "$(grep -c "pending-reply-retired-stale: task=mate pending-reply-id=$older" "$home/state/mate.status")" -eq 1 ] ||
  fail "a second apply wrote another retirement note"
pass "stale retirement resolves only the superseded record and keeps it"

# The sole unanswered record of a live secondmate is not retired, even when old.
# A done line on that secondmate does not count as the task closing.
home=$(fm_test_tmproot fm-retire-stale-live)
seed_task "$home" mate secondmate
printf 'done: mate reported something else\n' >> "$home/state/mate.status"
sole=$(open_reply "$home" mate 'only open ask' $((NOW - 90000)))
sole_rec=$(fm_pending_reply_path "$home/state" "$sole")
dry=$(run_retire "$home" --dry-run) || fail "dry-run failed for a live sole record"
[ -z "$dry" ] || fail "a live sole record was listed: $dry"
run_retire "$home" --apply >/dev/null || fail "apply failed for a live sole record"
[ "$(fm_pending_reply_get "$sole_rec" phase)" = awaiting_report ] || fail "a live sole record was retired"
pass "an unsuperseded unanswered record stays open"

home=$(fm_test_tmproot fm-retire-stale-boundary)
seed_task "$home" mate secondmate
young=$(open_reply "$home" mate 'exactly 24 hours old' $((NOW - 86400)))
fresh=$(open_reply "$home" mate 'asked seconds ago' $((NOW - 1)))
follow=$(open_reply "$home" mate 'asked again' "$NOW")
fm_pending_reply_mark_delivered "$home/state" "$follow" || fail "could not confirm the successor delivery"
young_rec=$(fm_pending_reply_path "$home/state" "$young")
dry=$(run_retire "$home" --dry-run) || fail "dry-run failed at the age boundary"
[ -z "$dry" ] || fail "a record at or below 24 hours was listed: $dry"
just=$(open_reply "$home" mate '24 hours and one second old' $((NOW - 86401)))
dry=$(run_retire "$home" --dry-run) || fail "dry-run failed just over 24 hours"
printf '%s\n' "$dry" | grep -F "corr=$just age=86401 reason=superseded-by-$follow" >/dev/null || fail "a record one second over 24 hours was not listed: $dry"
printf '%s\n' "$dry" | grep -F "corr=$young" >/dev/null && fail "the exact-age record was listed"
printf '%s\n' "$dry" | grep -F "corr=$fresh" >/dev/null && fail "a seconds-old record was listed"
printf '%s\n' "$dry" | grep -F "corr=$follow" >/dev/null && fail "the newest record was listed"
[ "$(fm_pending_reply_get "$young_rec" phase)" = awaiting_report ] || fail "dry-run changed the exact-age record"
run_retire "$home" --apply >/dev/null || fail "apply failed at the age boundary"
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$home/state" "$just")" phase)" = resolved ] || fail "apply did not retire the record over 24 hours old"
for kept in "$young" "$fresh" "$follow"; do
  [ "$(fm_pending_reply_get "$(fm_pending_reply_path "$home/state" "$kept")" phase)" = awaiting_report ] || fail "apply retired a record at or below 24 hours"
done
pass "dry-run and apply require records strictly older than 24 hours"

# A gone task retires every old open record, including the newest, and does
# not create a status file that was not already there.
home=$(fm_test_tmproot fm-retire-stale-gone)
mkdir -p "$home/state"
gone_old=$(open_reply "$home" vanished 'old ask' $((NOW - 90000)))
gone_new=$(open_reply "$home" vanished 'last ask' $((NOW - 89000)))
rm -f "$home/state/vanished.status"
gone_old_rec=$(fm_pending_reply_path "$home/state" "$gone_old")
gone_new_rec=$(fm_pending_reply_path "$home/state" "$gone_new")
dry=$(run_retire "$home" --dry-run) || fail "dry-run failed for a gone task"
printf '%s\n' "$dry" | grep -F "corr=$gone_old age=90000 reason=task-gone" >/dev/null ||
  fail "gone task did not list the older record: $dry"
printf '%s\n' "$dry" | grep -F "corr=$gone_new age=89000 reason=task-gone" >/dev/null ||
  fail "gone task did not list the newest record: $dry"
[ ! -e "$home/state/vanished.status" ] || fail "dry-run created a status file"
applied=$(run_retire "$home" --apply) || fail "apply failed for a gone task"
printf '%s\n' "$applied" | grep -F "reason=task-gone" >/dev/null || fail "apply did not report task-gone"
[ "$(fm_pending_reply_get "$gone_old_rec" resolved_via)" = retired-stale ] || fail "gone older record was not retired"
[ "$(fm_pending_reply_get "$gone_new_rec" resolved_via)" = retired-stale ] || fail "gone newest record was not retired"
[ "$(fm_pending_reply_get "$gone_old_rec" retired_reason)" = task-gone ] || fail "gone reason missing"
[ -f "$gone_old_rec" ] && [ -f "$gone_new_rec" ] || fail "gone-task records were deleted"
[ ! -e "$home/state/vanished.status" ] || fail "apply created a status file for a gone task"
pass "a gone task retires its old records and keeps the files"

for kind in ship scout secondmate; do
  for verb in 'done' 'failed'; do
    home=$(fm_test_tmproot "fm-retire-status-$kind-$verb")
    seed_task "$home" task "$kind"
    first=$(open_reply "$home" task 'older unanswered request' $((NOW - 90000)))
    last=$(open_reply "$home" task 'latest unanswered request' $((NOW - 89000)))
    printf '%s: unrelated task outcome\n' "$verb" > "$home/state/task.status"
    dry=$(run_retire "$home" --dry-run) || fail "dry-run failed for $kind $verb status"
    [ -z "$dry" ] || fail "$kind $verb status allowed retirement without a delivered successor"
    applied=$(run_retire "$home" --apply) || fail "apply failed for $kind $verb status"
    [ -z "$applied" ] || fail "$kind $verb status retired unanswered requests"
    for kept in "$first" "$last"; do
      kept_rec=$(fm_pending_reply_path "$home/state" "$kept")
      [ "$(fm_pending_reply_get "$kept_rec" phase)" = awaiting_report ] || fail "$kind $verb status resolved an unanswered request"
      [ -z "$(fm_pending_reply_get "$kept_rec" retired_reason)" ] || fail "$kind $verb status wrote a retirement reason"
    done
  done
done
pass "task status completion never supersedes an unanswered request"

# An already answered record is not rewritten onto the stale path.
home=$(fm_test_tmproot fm-retire-stale-answered)
seed_task "$home" mate secondmate
answered=$(open_reply "$home" mate 'already reported' $((NOW - 90000)))
later=$(open_reply "$home" mate 'follow up' "$NOW")
fm_pending_reply_mark_delivered "$home/state" "$later" || fail "could not confirm the successor delivery"
answered_rec=$(fm_pending_reply_path "$home/state" "$answered")
fm_pending_reply_set "$answered_rec" resolved_via status
fm_pending_reply_set "$answered_rec" phase resolved
dry=$(run_retire "$home" --dry-run) || fail "dry-run failed for an answered record"
[ -z "$dry" ] || fail "an answered record was listed: $dry"
run_retire "$home" --apply >/dev/null || fail "apply failed for an answered record"
[ "$(fm_pending_reply_get "$answered_rec" resolved_via)" = status ] ||
  fail "an answered record was rewritten to retired-stale"
[ -n "$later" ] || fail "follow up missing"
pass "an answered record stays on its own resolution path"

# A younger gone record stays open at the fixed 24-hour threshold.
home=$(fm_test_tmproot fm-retire-stale-default)
mkdir -p "$home/state"
recent=$(open_reply "$home" vanished 'recent gone ask' $((NOW - 100)))
old=$(open_reply "$home" vanished 'day-old gone ask' $((NOW - 86401)))
dry=$(FM_HOME="$home" FM_PENDING_REPLY_NOW=$NOW "$RETIRE" --dry-run) || fail "fixed-age dry-run failed"
printf '%s\n' "$dry" | grep -F "corr=$old age=86401 reason=task-gone" >/dev/null ||
  fail "the 24 hour threshold did not list a day-old gone record: $dry"
printf '%s\n' "$dry" | grep -F "corr=$recent" >/dev/null &&
  fail "the 24 hour threshold listed a record younger than a day"
pass "the fixed age is 24 hours"

if FM_HOME="$home" "$RETIRE" --dry-run --apply >/dev/null 2>&1; then
  fail "both modes were accepted"
fi
for mode in --dry-run --apply; do
  for supplied_home in unset empty; do
    rc=0
    if [ "$supplied_home" = unset ]; then
      env -u FM_HOME FM_ROOT_OVERRIDE="$home" "$RETIRE" "$mode" >/dev/null 2>&1 || rc=$?
    else
      FM_HOME='' FM_ROOT_OVERRIDE="$home" "$RETIRE" "$mode" >/dev/null 2>&1 || rc=$?
    fi
    [ "$rc" -eq 2 ] || fail "$mode accepted an $supplied_home home or failed for an unrelated reason"
    old_rec=$(fm_pending_reply_path "$home/state" "$old")
    [ "$(fm_pending_reply_get "$old_rec" phase)" = awaiting_report ] || fail "$mode mutated the fallback home"
  done
done
for mode in --dry-run --apply; do
  for age in -1 0 86400; do
    rc=0
    FM_HOME="$home" "$RETIRE" "$mode" --max-age "$age" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "$mode accepted the removed age option"
    [ "$(fm_pending_reply_get "$old_rec" phase)" = awaiting_report ] || fail "an invalid age option changed a record"
  done
done
if FM_HOME="$home" "$RETIRE" >/dev/null 2>&1; then
  fail "a run with no mode was accepted"
fi
help=$(env -u FM_HOME "$RETIRE" --help) || fail "help without a home failed"
printf '%s\n' "$help" | grep -F '86400' >/dev/null || fail "help did not show the 24 hour threshold"
pass "stale retirement refuses a bad invocation"

wait_for_file() {
  local path=$1 i
  for ((i=0; i<500; i++)); do
    [ ! -e "$path" ] || return 0
    command sleep 0.01
  done
  fail "timed out waiting for $path"
}

exercise_callback() {
  local action=$1 state=$2 corr=$3 mate_home=$4
  case "$action" in
    finish-confirmed) fm_pending_reply_finish_recovery "$state" "$corr" confirmed ;;
    finish-failed) fm_pending_reply_finish_recovery "$state" "$corr" failed ;;
    reconcile-*) fm_pending_reply_reconcile_recovery "$state" "$corr" ;;
    delivery-unknown) fm_pending_reply_mark_delivery_unknown "$state" "$corr" ;;
    delivered|delivered-unknown) fm_pending_reply_mark_delivered "$state" "$corr" ;;
    busy) fm_pending_reply_observe_busy "$state" "$corr" busy ;;
    idle) fm_pending_reply_observe_busy "$state" "$corr" idle ;;
    completed-request) fm_pending_reply_mark_turn_completed "$state" "$corr" request ;;
    completed-recovery) fm_pending_reply_mark_turn_completed "$state" "$corr" recovery ;;
    wrong-home) fm_pending_reply_detect_wrong_home "$state" "$corr" "$mate_home" ;;
  esac
}

for action in finish-confirmed finish-failed reconcile-confirmed reconcile-failed \
  reconcile-unknown reconcile-dead reconcile-awaiting-unknown reconcile-awaiting-dead \
  delivery-unknown delivered delivered-unknown busy idle completed-request completed-recovery wrong-home; do
  (
    for ordering in ordinary concurrent; do
      home=$(fm_test_tmproot "fm-retire-$ordering-$action")
      export FM_HOME=$home
      seed_task "$home" mate secondmate
      mate_home="$home/mate-home"
      mkdir -p "$mate_home/state"
      corr=$(open_reply "$home" mate 'superseded unanswered request' $((NOW - 90000)))
      rec=$(fm_pending_reply_path "$home/state" "$corr")
      later=$(open_reply "$home" mate 'newest unanswered request' "$NOW")
      fm_pending_reply_mark_delivered "$home/state" "$later" || fail "could not confirm the successor delivery"
      fm_pending_reply_set "$rec" delivered_epoch "$((NOW - 450))"
      expected=awaiting_report
      field=delivered_epoch
      value=$((NOW - 450))
      case "$action" in
        finish-*|reconcile-*)
          fm_pending_reply_set "$rec" phase recovery_sending
          fm_pending_reply_set "$rec" recovery_attempted_epoch "$((NOW - 300))"
          field=recovery_delivery_outcome
          case "$action" in
            *confirmed) value=confirmed; expected=recovery_sent ;;
            *failed) value=failed; expected=recovery_failed ;;
            *) value=unknown; expected=recovery_unknown ;;
          esac
          case "$action" in
            reconcile-awaiting-*) fm_pending_reply_set "$rec" phase awaiting_report ;;
          esac
          case "$action" in
            reconcile-dead|reconcile-awaiting-dead) ;;
            reconcile-*) fm_pending_reply_set "$rec" recovery_delivery_outcome "$value" ;;
          esac
          ;;
        delivery-unknown|delivered|delivered-unknown)
          fm_pending_reply_set "$rec" delivered_epoch ''
          case "$action" in
            delivery-unknown) expected=delivery_unknown; field=phase; value=delivery_unknown ;;
            delivered-unknown) fm_pending_reply_set "$rec" phase delivery_unknown ;;
          esac
          if [ "$action" != delivery-unknown ]; then value=$NOW; fi
          ;;
        busy) field=turn_seen_busy; value=1 ;;
        idle)
          fm_pending_reply_set "$rec" phase recovery_sent
          expected=recovery_sent; field=recovery_turn_completed_epoch; value=$NOW
          ;;
        completed-request) field=request_turn_completed_epoch; value=$NOW ;;
        completed-recovery)
          fm_pending_reply_set "$rec" phase recovery_sent
          expected=recovery_sent; field=recovery_turn_completed_epoch; value=$NOW
          ;;
        wrong-home)
          printf 'working: report corr=%s\n' "$corr" > "$mate_home/state/elsewhere.status"
          field=wrong_home_hits; value=1
          ;;
      esac
      if [ "$ordering" = ordinary ]; then
        exercise_callback "$action" "$home/state" "$corr" "$mate_home" || fail "$action failed on an active record"
        [ "$(fm_pending_reply_get "$rec" phase)" = "$expected" ] || fail "$action broke its ordinary phase transition"
        [ "$(fm_pending_reply_get "$rec" "$field")" = "$value" ] || fail "$action lost its ordinary $field update"
        continue
      fi
      entered="$home/callback-entered"
      release="$home/callback-release"
      export -f exercise_callback wait_for_file fail
      bash -u -c '
        . "$1"
        action=$2 state=$3 corr=$4 mate_home=$5 rec=$6 entered=$7 release=$8
        mv() {
          if [ "${!#}" = "$rec" ] && [ ! -e "$entered" ]; then
            : > "$entered"
            wait_for_file "$release"
          fi
          command mv "$@"
        }
        exercise_callback "$action" "$state" "$corr" "$mate_home"
      ' _ "$PENDING_REPLY_LIB" "$action" "$home/state" "$corr" "$mate_home" "$rec" "$entered" "$release" &
      callback_pid=$!
      wait_for_file "$entered"
      (
        sleep() {
          : > "$release"
          command sleep "$@"
        }
        fm_pending_reply_retire_stale_one "$home" "$home/state" "$corr" "$NOW" > "$home/retirement-output"
        result=$?
        : > "$release"
        exit "$result"
      ) &
      retire_pid=$!
      wait "$callback_pid" || fail "$action did not complete during retirement"
      wait "$retire_pid" || fail "retirement failed alongside $action"
      [ -f "$rec" ] || fail "$action removed the retired record"
      [ "$(fm_pending_reply_get "$rec" phase)" = resolved ] || fail "$action reopened a retired record"
      [ "$(fm_pending_reply_get "$rec" resolved_via)" = retired-stale ] || fail "$action lost the retirement provenance"
      [ "$(fm_pending_reply_get "$rec" retired_reason)" = "superseded-by-$later" ] || fail "$action lost the retirement reason"
      [ "$(fm_pending_reply_get "$rec" request_summary)" = 'superseded unanswered request' ] || fail "$action lost the unanswered request"
      exercise_callback "$action" "$home/state" "$corr" "$mate_home" >/dev/null 2>&1 || true
      [ "$(fm_pending_reply_get "$rec" phase)" = resolved ] || fail "late $action reopened a retired record"
      fm_pending_reply_discard_undelivered "$home/state" "$corr" >/dev/null 2>&1 || true
      [ -f "$rec" ] || fail "late transport cleanup deleted a retired record"
    done
  ) || fail "$action retirement invariant failed"
  pass "retirement remains terminal alongside $action"
done
