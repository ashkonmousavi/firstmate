#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M63T5F6P41J1YAJ9818FNK97
LAB=$(mktemp -d "$ROOT/.test-retire-tmp/manual.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_PENDING_REPLY_DIR_OVERRIDE FM_PENDING_REPLY_SEND_HOOK
export FM_HOME=$LAB
. "$ROOT/bin/fm-pending-reply-lib.sh"
export FM_PENDING_REPLY_NOW=1800000000
NOW=$FM_PENDING_REPLY_NOW
mkdir -p "$LAB/state"
RETIRE=$ROOT/bin/fm-pending-reply-retire-stale.sh
seed() { printf 'kind=%s\n' "${2:-secondmate}" > "$LAB/state/$1.meta"; : > "$LAB/state/$1.status"; }
create() { FM_PENDING_REPLY_NOW=$((NOW - $2)) fm_pending_reply_create "$LAB" "$LAB/state" "$1" "$3"; }
rec() { fm_pending_reply_path "$LAB/state" "$1"; }
get() { fm_pending_reply_get "$(rec "$1")" "$2"; }
check() { if ! "$@"; then echo "ASSERTION FAILED: $*"; exit 1; fi; }
show() { echo "--- persisted record $1"; cat "$(rec "$1")"; }
run() { echo "+ FM_HOME=<disposable-home> bash bin/fm-pending-reply-retire-stale.sh $*"; bash "$RETIRE" "$@"; }
echo 'Oracle: owner intent and recorded decisions: retain unanswered records, retire only strictly older than 24h and superseded by retained confirmed delivery or task-gone; durable reason; only matching escalation closes.'
echo 'SCENARIO 1: preview, apply, preserve newest request, close only old escalation, idempotent retry'
seed mate
old=$(create mate 90000 'original unanswered request')
new=$(create mate 50 'later unanswered request')
fm_pending_reply_mark_delivery_unknown "$LAB/state" "$old"
fm_pending_reply_maybe_escalate "$LAB/state" "$old"
fm_pending_reply_mark_delivered "$LAB/state" "$new"
# A second escalation is an independently owned decision that must remain open.
printf 'blocked [key=independent-decision]: waiting for separate decision\n' >> "$LAB/state/mate.status"
cp "$(rec "$old")" "$LAB/before"
cp "$LAB/state/mate.status" "$LAB/status-before"
run --dry-run
check cmp "$LAB/before" "$(rec "$old")"
check cmp "$LAB/status-before" "$LAB/state/mate.status"
run --apply
check test "$(get "$old" phase)" = resolved
check test "$(get "$old" resolved_via)" = retired-stale
check test "$(get "$old" retired_reason)" = "superseded-by-$new"
check test "$(get "$old" request_summary)" = 'original unanswered request'
check test "$(get "$new" phase)" = awaiting_report
check test -f "$(rec "$old")"
show "$old"
echo '--- task status log'; cat "$LAB/state/mate.status"
echo '--- open decisions'; status_open_decisions "$LAB/state/mate.status" > "$LAB/decisions"; cat "$LAB/decisions"
check grep -F independent-decision "$LAB/decisions"
if grep -F "pending-reply-$old" "$LAB/decisions"; then exit 1; fi
cp "$LAB/state/mate.status" "$LAB/status-after"
run --apply
check cmp "$LAB/status-after" "$LAB/state/mate.status"
echo 'RESULT scenario 1: pass'

echo 'SCENARIO 2: reject transient replacements until delivery is durably reconciled'
seed transport
original=$(create transport 95000 'only real unanswered request')
fm_pending_reply_mark_delivered "$LAB/state" "$original"
replacement=$(create transport 20 'replacement in transport')
for stage in created attempted unknown discarded marker-only reconciled; do
  case "$stage" in
    attempted) fm_pending_reply_prepare_delivery "$LAB/state" "$replacement" ;;
    unknown) fm_pending_reply_mark_delivery_unknown "$LAB/state" "$replacement" ;;
    discarded) fm_pending_reply_discard_undelivered "$LAB/state" "$replacement"; check test ! -f "$(rec "$replacement")" ;;
    marker-only) replacement=$(create transport 10 'replacement with delivery marker'); fm_pending_reply_write_delivery_confirmation "$LAB/state" "$replacement" confirmed "$NOW" ;;
    reconciled) fm_pending_reply_reconcile_delivery "$LAB/state" "$replacement" ;;
  esac
  echo "--- replacement stage=$stage"
  run --dry-run
  run --apply
  if [ "$stage" = reconciled ]; then
    check test "$(get "$original" phase)" = resolved
    check test "$(get "$original" retired_reason)" = "superseded-by-$replacement"
  else
    check test "$(get "$original" phase)" = awaiting_report
  fi
  echo "original phase=$(get "$original" phase) reason=$(get "$original" retired_reason)"
done
if fm_pending_reply_discard_undelivered "$LAB/state" "$replacement"; then echo 'confirmed replacement incorrectly discarded'; exit 1; fi
show "$original"
echo 'RESULT scenario 2: pass'

echo 'SCENARIO 3: preserve unsuperseded requests and exactly-24h records; retire at 24h+1s'
seed boundary
exact=$(create boundary 86400 'exactly twenty four hours old')
over=$(create boundary 86401 'one second beyond twenty four hours')
young=$(create boundary 1 'seconds old')
follow=$(create boundary 0 'latest delivered request')
fm_pending_reply_mark_delivered "$LAB/state" "$follow"
seed sole
sole=$(create sole 99000 'no successor exists')
printf 'done: unrelated completed work\n' > "$LAB/state/sole.status"
for kind in ship scout; do
  seed "$kind" "$kind"
  item=$(create "$kind" 99000 'unanswered despite completed task status')
  printf 'failed: unrelated task result\n' > "$LAB/state/$kind.status"
  printf '%s\n' "$item" >> "$LAB/kept"
done
run --dry-run
run --apply
check test "$(get "$over" phase)" = resolved
for item in "$exact" "$young" "$follow" "$sole" $(cat "$LAB/kept"); do
  check test "$(get "$item" phase)" = awaiting_report
  echo "kept corr=$item created=$(get "$item" created_epoch) phase=$(get "$item" phase) request=$(get "$item" request_summary)"
done
show "$over"
echo 'RESULT scenario 3: pass'

echo 'SCENARIO 4: gone task keeps every retired record and creates no phantom status log'
gone1=$(create vanished 97000 'first missing task request')
gone2=$(create vanished 96000 'newest missing task request')
run --dry-run
run --apply
for item in "$gone1" "$gone2"; do
  check test "$(get "$item" phase)" = resolved
  check test "$(get "$item" retired_reason)" = task-gone
  show "$item"
done
check test ! -e "$LAB/state/vanished.status"
echo 'No vanished.status created; both original record files retained.'
echo 'RESULT scenario 4: pass'

echo 'SCENARIO 5: require explicit home and mode; reject removed age override without mutation'
for mode in --dry-run --apply; do
  for supplied in unset empty; do
    rc=0
    if [ "$supplied" = unset ]; then
      env -u FM_HOME FM_ROOT_OVERRIDE="$LAB" bash "$RETIRE" "$mode" || rc=$?
    else
      FM_HOME='' FM_ROOT_OVERRIDE="$LAB" bash "$RETIRE" "$mode" || rc=$?
    fi
    echo "$mode FM_HOME=$supplied exit=$rc"
    check test "$rc" -eq 2
  done
  rc=0
  bash "$RETIRE" "$mode" --max-age 0 || rc=$?
  echo "$mode --max-age 0 exit=$rc"
  check test "$rc" -eq 2
done
for args in '' '--dry-run --apply'; do
  rc=0
  bash "$RETIRE" $args || rc=$?
  echo "args='$args' exit=$rc"
  check test "$rc" -eq 2
done
check test "$(get "$sole" phase)" = awaiting_report
check test "$(get "$exact" phase)" = awaiting_report
echo 'RESULT scenario 5: pass'

echo 'SCENARIO 6: concurrent and late callbacks cannot reopen retired records'
seed racing
race=$(create racing 98000 'request being recovered during retirement')
later=$(create racing 0 'new delivered request')
fm_pending_reply_mark_delivered "$LAB/state" "$later"
fm_pending_reply_set "$(rec "$race")" phase recovery_sending
fm_pending_reply_set "$(rec "$race")" recovery_attempted_epoch "$((NOW - 300))"
fm_pending_reply_set "$(rec "$race")" recovery_delivery_outcome confirmed
# Run actual callbacks and CLI in different processes; no patched functions or fake transport.
(bash "$RETIRE" --apply > "$LAB/race-cli" 2>&1) & retire_pid=$!
(fm_pending_reply_finish_recovery "$LAB/state" "$race" confirmed || test "$(get "$race" phase)" = resolved) & callback_pid=$!
wait "$retire_pid"
wait "$callback_pid"
cat "$LAB/race-cli"
check test "$(get "$race" phase)" = resolved
for callback in fm_pending_reply_reconcile_recovery fm_pending_reply_mark_delivery_unknown fm_pending_reply_mark_delivered; do
  rc=0
  "$callback" "$LAB/state" "$race" || rc=$?
  echo "late callback=$callback exit=$rc phase=$(get "$race" phase)"
  check test "$(get "$race" phase)" = resolved
done
for outcome in confirmed failed; do
  rc=0
  fm_pending_reply_finish_recovery "$LAB/state" "$race" "$outcome" || rc=$?
  echo "late recovery=$outcome exit=$rc phase=$(get "$race" phase)"
  check test "$(get "$race" phase)" = resolved
done
rc=0
fm_pending_reply_discard_undelivered "$LAB/state" "$race" || rc=$?
echo "late discard exit=$rc retained=$(test -f "$(rec "$race")" && echo yes)"
show "$race"
echo 'RESULT scenario 6: pass'
echo 'All CLI scenarios complete; disposable home removed by EXIT trap.'
