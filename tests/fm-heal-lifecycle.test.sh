#!/usr/bin/env bash
# Behavioral coverage for /heal lifecycle enforcement, checkpoint recovery,
# index recovery and overflow, archive recurrence, and empty scans.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HEAL="$ROOT/bin/fm-heal.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-heal-lifecycle)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
owner=$(cat "$FM_HOME/state/.lock" 2>/dev/null || true)
case "$*" in
  *"comm="*)
    [ -n "$owner" ] && [ "$pid" = "$owner" ] && { printf '%s\n' claude; exit 0; }
    ;;
  *"args="*)
    [ -n "$owner" ] && [ "$pid" = "$owner" ] && { printf '%s\n' claude; exit 0; }
    ;;
esac
exec /bin/ps "$@"
SH
chmod +x "$FAKEBIN/ps"

new_home() {
  local home="$TMP_ROOT/$1-home"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '%s\n' "$home"
}

run_owned() {
  local home=$1
  shift
  FM_HOME="$home" PATH="$FAKEBIN:$BASE_PATH" /bin/bash -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$@"
  ' _ "$HEAL" "$@"
}

meta_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
end = lines[1:].index("---") + 1
value = json.loads("\n".join(lines[1:end]))[sys.argv[2]]
print(json.dumps(value, sort_keys=True) if isinstance(value, (dict, list)) else value)
PY
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for key in sys.argv[2].split('.'):
    value = value[key]
print(json.dumps(value, sort_keys=True) if isinstance(value, (dict, list)) else str(value).lower() if isinstance(value, bool) else value)
PY
}

new_finding() {
  local home=$1 id=$2 classification=${3:-recurring-failure}
  run_owned "$home" new --id "$id" --fingerprint "fingerprint-$id" \
    --component "component-$id" --title "Finding $id" --classification "$classification" \
    --severity medium --observed-at 2026-09-09T12:00:00Z --event-key "event-$id" \
    --notifications 1 --evidence "evidence:$id" --owner task:owner >/dev/null
}

transition_args() {
  case "$1" in
    Open) printf '%s\n' '--reason' 'requeued with an explicit action' '--next-action' 'recheck current state' ;;
    Active) printf '%s\n' '--reason' 'work started' '--owner' 'task:owner' ;;
    Blocked) printf '%s\n' '--reason' 'proof cannot proceed' '--owner' 'task:owner' '--trigger' 'dependency lands' ;;
    Unverified) printf '%s\n' '--reason' 'correction awaits proof' '--evidence' 'branch:repair' '--proof-required' 'consumer journey' ;;
    Closed) printf '%s\n' '--reason' 'premise disproved' '--disposition' 'Disproved' '--evidence' 'evidence:disproof' ;;
  esac
}

make_source_state() {
  local home=$1 id=$2 state=$3 args=()
  new_finding "$home" "$id"
  case "$state" in
    Open) ;;
    Active|Blocked|Closed)
      mapfile -t args < <(transition_args "$state")
      run_owned "$home" transition "$id" "$state" "${args[@]}" >/dev/null
      ;;
    Unverified)
      run_owned "$home" transition "$id" Active --reason started --owner task:owner >/dev/null
      mapfile -t args < <(transition_args Unverified)
      run_owned "$home" transition "$id" Unverified "${args[@]}" >/dev/null
      ;;
  esac
}

expect_transition_refused() {
  local home=$1 id=$2 destination=$3 out status args=()
  mapfile -t args < <(transition_args "$destination")
  [ "$destination" != Open ] || args+=(--new-evidence evidence:recurrence)
  set +e
  out=$(run_owned "$home" transition "$id" "$destination" "${args[@]}" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "invalid transition to $destination was accepted for $id"
  assert_contains "$out" 'transition not permitted' "invalid transition refusal did not name the lifecycle rule"
}

test_every_lifecycle_edge_is_accepted_and_every_other_edge_refused() {
  local home source destination id args=() i=0
  local -a allowed=(
    'Open Active' 'Open Blocked' 'Open Closed'
    'Active Open' 'Active Blocked' 'Active Unverified' 'Active Closed'
    'Blocked Open' 'Blocked Active' 'Blocked Unverified' 'Blocked Closed'
    'Unverified Active' 'Unverified Blocked' 'Unverified Closed'
    'Closed Open'
  )
  local -a refused=(
    'Open Open' 'Open Unverified' 'Active Active' 'Blocked Blocked'
    'Unverified Open' 'Unverified Unverified' 'Closed Active' 'Closed Blocked'
    'Closed Unverified' 'Closed Closed'
  )
  home=$(new_home transition-table)
  run_owned "$home" init >/dev/null
  for edge in "${allowed[@]}"; do
    read -r source destination <<< "$edge"
    i=$((i + 1))
    id="allowed-$i"
    make_source_state "$home" "$id" "$source"
    mapfile -t args < <(transition_args "$destination")
    [ "$source:$destination" != 'Closed:Open' ] || args+=(--new-evidence evidence:recurrence)
    run_owned "$home" transition "$id" "$destination" "${args[@]}" >/dev/null \
      || fail "allowed transition $source -> $destination was refused"
    [ "$(meta_field "$home/data/heal/findings/$id.md" state)" = "$destination" ] \
      || fail "allowed transition $source -> $destination did not persist"
  done
  for edge in "${refused[@]}"; do
    read -r source destination <<< "$edge"
    i=$((i + 1))
    id="refused-$i"
    make_source_state "$home" "$id" "$source"
    expect_transition_refused "$home" "$id" "$destination"
  done
  pass "heal lifecycle: exactly the documented five-state transition table is executable"
}

test_reasoned_dismissal_and_closed_reopening_require_evidence() {
  local home finding
  home=$(new_home dismissal-reopen)
  run_owned "$home" init >/dev/null
  new_finding "$home" report historical-report
  run_owned "$home" transition report Closed --reason 'reported premise is false' \
    --disposition Disproved --evidence evidence:counterexample >/dev/null
  finding="$home/data/heal/findings/report.md"
  [ "$(meta_field "$finding" disposition)" = Disproved ] || fail "reasoned dismissal lost its disposition"
  set +e
  out=$(run_owned "$home" transition report Open --reason recurrence --next-action investigate 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "Closed -> Open succeeded without new evidence"
  assert_contains "$out" 'Closed to Open requires new evidence' "reopen refusal did not name its evidence requirement"
  run_owned "$home" transition report Open --reason 'new recurrence' --next-action investigate \
    --new-evidence evidence:new-occurrence >/dev/null
  [ "$(meta_field "$finding" state)" = Open ] || fail "new evidence did not reopen the closed finding"
  pass "heal lifecycle: Disproved is reasoned closure and recurrence reopens only on new evidence"
}

test_interruption_and_repeat_invocation_preserve_findings_and_source_progress() {
  local home checkpoint finding out status incomplete_count archived_checkpoint
  home=$(new_home interruption)
  run_owned "$home" init >/dev/null
  run_owned "$home" checkpoint-begin --scan-id scan-a --window 4h \
    --started-at 2026-09-09T12:00:00Z >/dev/null
  new_finding "$home" interrupted
  run_owned "$home" checkpoint-source --scan-id scan-a --source-id status-log \
    --identity sha256:aaa --cursor 17 --read-at 2026-09-09T12:01:00Z >/dev/null
  checkpoint="$home/data/heal/checkpoint.json"
  [ "$(json_field "$checkpoint" complete)" = false ] || fail "interrupted scan claimed completion"
  set +e
  out=$(run_owned "$home" checkpoint-source --scan-id scan-a --source-id status-log \
    --identity sha256:rotated --cursor 1 --read-at 2026-09-09T12:01:30Z 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "source rotation replaced the identity inside an active scan"
  assert_contains "$out" 'source identity changed during the scan' "source rotation refusal was not explicit"
  [ "$(json_field "$checkpoint" sources.status-log.identity)" = sha256:aaa ] || fail "source rotation destroyed the preserved identity"
  run_owned "$home" checkpoint-begin --scan-id scan-a --window 4h \
    --started-at 2026-09-09T12:00:00Z >/dev/null
  run_owned "$home" observe --id interrupted --event-key event-interrupted \
    --observed-at 2026-09-09T12:02:00Z --notifications 1 --evidence evidence:repeat >/dev/null
  finding="$home/data/heal/findings/interrupted.md"
  [ "$(meta_field "$finding" occurrence_count)" = 1 ] || fail "repeat invocation duplicated the preserved finding"
  [ "$(json_field "$checkpoint" sources.status-log.cursor)" = 17 ] || fail "repeat invocation skipped or reset source progress"
  run_owned "$home" checkpoint-complete --scan-id scan-a \
    --completed-at 2026-09-09T12:03:00Z --expect status-log=sha256:aaa >/dev/null
  [ "$(json_field "$checkpoint" complete)" = true ] || fail "complete source-bound scan did not persist completion"
  run_owned "$home" checkpoint-begin --scan-id scan-partial --window 4h \
    --started-at 2026-09-09T12:04:00Z >/dev/null
  run_owned "$home" checkpoint-source --scan-id scan-partial --source-id status-log \
    --identity sha256:partial --cursor 23 --read-at 2026-09-09T12:05:00Z >/dev/null
  run_owned "$home" checkpoint-begin --scan-id scan-refreshed --window 4h \
    --started-at 2026-09-09T12:06:00Z >/dev/null
  incomplete_count=$(find "$home/data/heal" -maxdepth 1 -name 'checkpoint.incomplete.*.json' | wc -l)
  [ "$incomplete_count" -eq 1 ] || fail "starting a refreshed scan did not preserve the prior incomplete checkpoint"
  archived_checkpoint=$(find "$home/data/heal" -maxdepth 1 -name 'checkpoint.incomplete.*.json')
  [ "$(json_field "$archived_checkpoint" sources.status-log.cursor)" = 23 ] || fail "preserved incomplete checkpoint lost source progress"
  [ "$(json_field "$checkpoint" scan_id)" = scan-refreshed ] || fail "refreshed scan did not become current"
  [ "$(json_field "$checkpoint" complete)" = false ] || fail "refreshed scan began as complete"
  pass "heal recovery: interruption and repeated invocation preserve findings and source-bound progress"
}

test_missing_or_corrupt_index_rebuilds_and_incomplete_checkpoint_stays_incomplete() {
  local home checkpoint status corrupt_count
  home=$(new_home rebuild)
  run_owned "$home" init >/dev/null
  new_finding "$home" rebuild-one
  rm -f "$home/data/heal/INDEX.md"
  run_owned "$home" rebuild-index --limit 10 >/dev/null
  assert_grep 'rebuild-one' "$home/data/heal/INDEX.md" "missing index did not rebuild from findings"
  printf '%s\n' corrupt > "$home/data/heal/INDEX.md"
  run_owned "$home" rebuild-index --limit 10 >/dev/null
  assert_grep 'rebuild-one' "$home/data/heal/INDEX.md" "corrupt index did not rebuild from findings"

  checkpoint="$home/data/heal/checkpoint.json"
  printf '%s\n' '{broken' > "$checkpoint"
  set +e
  status=$(FM_HOME="$home" PATH="$FAKEBIN:$BASE_PATH" "$HEAL" checkpoint-status 2>&1)
  set -e
  assert_contains "$status" corrupt "corrupt checkpoint was not reported"
  run_owned "$home" checkpoint-begin --scan-id recovery --window 4h \
    --started-at 2026-09-09T12:10:00Z >/dev/null
  [ "$(json_field "$checkpoint" complete)" = false ] || fail "recovered checkpoint claimed a completed scan"
  corrupt_count=$(find "$home/data/heal" -maxdepth 1 -type f -name 'checkpoint.corrupt.*.json' | wc -l | tr -d ' ')
  [ "$corrupt_count" -eq 1 ] || fail "corrupt checkpoint was not preserved exactly once"
  pass "heal recovery: indexes rebuild from findings and damaged checkpoints recover without false completion"
}

test_index_overflow_reports_all_unresolved_findings_through_compact_links() {
  local home index complete id
  home=$(new_home overflow)
  run_owned "$home" init >/dev/null
  for id in overflow-a overflow-b overflow-c overflow-d; do
    new_finding "$home" "$id"
  done
  run_owned "$home" rebuild-index --limit 2 >/dev/null
  index="$home/data/heal/INDEX.md"
  assert_grep 'Unresolved: 4' "$index" "overflow index omitted the explicit unresolved count"
  assert_grep 'Showing highest-priority 2 of 4 unresolved findings.' "$index" "overflow index did not disclose its priority bound"
  assert_grep 'indexes/unresolved-001.md' "$index" "overflow index did not link the complete compact view"
  complete="$home/data/heal/indexes/unresolved-001.md"
  for id in overflow-a overflow-b overflow-c overflow-d; do
    assert_grep "$id" "$complete" "complete overflow index omitted $id"
  done
  pass "heal index: overflow remains a bounded priority view with explicit counts and complete links"
}

test_archive_lookup_and_later_recurrence_reopen_the_archived_id() {
  local home out active
  home=$(new_home archive-recurrence)
  run_owned "$home" init >/dev/null
  new_finding "$home" recurring-archive
  run_owned "$home" transition recurring-archive Closed --reason 'premise disproved then' \
    --disposition Disproved --evidence evidence:then >/dev/null
  run_owned "$home" archive recurring-archive --month 2026-09 >/dev/null
  out=$(FM_HOME="$home" PATH="$FAKEBIN:$BASE_PATH" "$HEAL" lookup recurring-archive)
  assert_contains "$out" 'archive/2026-09/recurring-archive.md' "targeted archive lookup did not find the prior identity"
  run_owned "$home" observe --id recurring-archive --event-key event-recurring-archive \
    --observed-at 2026-09-09T12:30:00Z --notifications 2 --evidence evidence:repeat-notice >/dev/null
  assert_present "$home/data/heal/archive/2026-09/recurring-archive.md" "repeat notice moved a closed record out of archive"
  assert_absent "$home/data/heal/findings/recurring-archive.md" "repeat notice restored a closed record without a recurrence"
  run_owned "$home" observe --id recurring-archive --event-key event-recurrence \
    --observed-at 2026-09-09T13:00:00Z --notifications 1 --evidence evidence:recurrence >/dev/null
  active="$home/data/heal/findings/recurring-archive.md"
  assert_present "$active" "later recurrence did not restore the archived stable id"
  assert_absent "$home/data/heal/archive/2026-09/recurring-archive.md" "reopened finding remained duplicated in archive"
  [ "$(meta_field "$active" state)" = Open ] || fail "archived recurrence did not reopen as Open"
  [ "$(meta_field "$active" occurrence_count)" = 2 ] || fail "archived recurrence lost the original occurrence count"
  pass "heal archive: targeted lookup and later recurrence reopen the same stable identity"
}

test_no_actionable_finding_still_completes_an_evidenced_scan() {
  local home index checkpoint
  home=$(new_home no-action)
  run_owned "$home" init >/dev/null
  run_owned "$home" checkpoint-begin --scan-id empty-scan --window 4h \
    --started-at 2026-09-09T14:00:00Z >/dev/null
  run_owned "$home" checkpoint-source --scan-id empty-scan --source-id current-obligations \
    --identity sha256:none --cursor complete --read-at 2026-09-09T14:01:00Z >/dev/null
  run_owned "$home" checkpoint-complete --scan-id empty-scan \
    --completed-at 2026-09-09T14:02:00Z --expect current-obligations=sha256:none >/dev/null
  run_owned "$home" rebuild-index --limit 3 >/dev/null
  index="$home/data/heal/INDEX.md"
  checkpoint="$home/data/heal/checkpoint.json"
  assert_grep 'Unresolved: 0' "$index" "empty scan did not report zero unresolved findings"
  assert_grep 'No actionable findings.' "$index" "empty scan manufactured work instead of reporting none"
  [ "$(json_field "$checkpoint" complete)" = true ] || fail "evidenced empty scan did not complete"
  pass "heal scan: no actionable finding is a valid evidenced outcome"
}

test_every_lifecycle_edge_is_accepted_and_every_other_edge_refused
test_reasoned_dismissal_and_closed_reopening_require_evidence
test_interruption_and_repeat_invocation_preserve_findings_and_source_progress
test_missing_or_corrupt_index_rebuilds_and_incomplete_checkpoint_stays_incomplete
test_index_overflow_reports_all_unresolved_findings_through_compact_links
test_archive_lookup_and_later_recurrence_reopen_the_archived_id
test_no_actionable_finding_still_completes_an_evidenced_scan
