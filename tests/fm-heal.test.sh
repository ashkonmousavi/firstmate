#!/usr/bin/env bash
# Behavioral coverage for /heal ownership, classification, deduplication,
# delivery-proof state, and exclusion from automatic startup memory.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HEAL="$ROOT/bin/fm-heal.sh"
MEMORY="$ROOT/bin/fm-startup-memory-budget.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-heal)
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
    if [ -n "$owner" ] && [ "$pid" = "$owner" ]; then
      printf '%s\n' claude
      [ "${FM_TEST_DROP_LOCK_ON_ARGS:-0}" != 1 ] || rm -f "$FM_HOME/state/.lock"
      exit 0
    fi
    ;;
esac
exec /bin/ps "$@"
SH
chmod +x "$FAKEBIN/ps"

new_home() {
  local home="$TMP_ROOT/$1-home"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '%s\n' 100000 > "$home/config/startup-memory-budget"
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

run_advisor() {
  local home=$1
  shift
  FM_HOME="$home" PATH="$FAKEBIN:$BASE_PATH" "$HEAL" "$@"
}

meta_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
end = lines[1:].index("---") + 1
value = json.loads("\n".join(lines[1:end]))[sys.argv[2]]
if isinstance(value, (dict, list)):
    print(json.dumps(value, sort_keys=True))
else:
    print(value)
PY
}

new_finding() {
  local home=$1 id=$2 fingerprint=$3 classification=${4:-recurring-failure} owner=${5:-task:repair}
  run_owned "$home" new \
    --id "$id" --fingerprint "$fingerprint" --component "component-$id" \
    --title "Finding $id" --classification "$classification" --severity high \
    --observed-at 2026-09-09T12:00:00Z --event-key "event-$id-1" \
    --notifications 1 --evidence "evidence:$id:1" --owner "$owner" >/dev/null
}

expect_failure() {
  local expected=$1
  shift
  local out status
  set +e
  out=$("$@" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "expected refusal containing '$expected'"
  assert_contains "$out" "$expected" "refusal did not explain '$expected'"
}

current_summary_candidate() {
  python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path

source, target = map(Path, sys.argv[1:])
text = source.read_text(encoding="utf-8")
metadata, body = text.split("\n---\n", 1)
history = body.split("## Material history\n", 1)[1]
target.write_text(metadata + "\n---\n" + """# Installed repair is disabled in its consumer

## Current account

The installed tool can repair documents, but the consuming project disables that step.
The same consumer failed again; the installed version alone did not settle the finding.

## Cause and ownership

task:consumer-config owns checking the consumer configuration against the accepted repair.
The remaining question is whether the enabled path preserves the project's bounded correction policy.

## Correction and proof

Next: enable and exercise the bounded path in the consumer's existing validation.
Proof: one accepted correction committed inside that run, with its application work continuing.

## Representative evidence

- evidence:consumer-config-disabled

## Material history
""" + history, encoding="utf-8")
PY
}

test_refresh_updates_the_current_repair_without_a_fake_state_change() {
  local heal_home finding candidate before
  heal_home=$(new_home current-repair)
  run_owned "$heal_home" init >/dev/null
  new_finding "$heal_home" consumer consumer-disabled
  run_owned "$heal_home" transition consumer Active --reason 'tool repair started' --owner task:tool >/dev/null
  run_owned "$heal_home" transition consumer Unverified --reason 'tool installed' \
    --evidence tool:installed --proof-required 'exercise the real consumer' >/dev/null
  finding="$heal_home/data/heal/findings/consumer.md"
  candidate="$TMP_ROOT/current-repair-candidate.md"
  before=$(meta_field "$finding" occurrence_keys)
  current_summary_candidate "$finding" "$candidate"
  expect_failure 'verified session lock ownership required' run_advisor "$heal_home" publish consumer --candidate "$candidate"
  expect_failure 'requires --verified-at and --evidence' run_owned "$heal_home" publish consumer \
    --candidate "$candidate" --owner task:consumer-config
  run_owned "$heal_home" publish consumer --candidate "$candidate" \
    --verified-at 2026-09-09T12:10:00Z --evidence evidence:consumer-config-disabled \
    --title 'Installed repair is disabled in its consumer' --owner task:consumer-config \
    --next-action 'exercise the bounded correction in the consumer' \
    --proof-required 'one accepted correction committed inside the same run' >/dev/null \
    || fail "current repair could not be refreshed without cycling the lifecycle"
  [ "$(meta_field "$finding" state)" = Unverified ] || fail "refresh changed the lifecycle"
  [ "$(meta_field "$finding" owner)" = task:consumer-config ] || fail "refresh retained the obsolete repair owner"
  [ "$(meta_field "$finding" occurrence_keys)" = "$before" ] || fail "refresh fabricated an occurrence"
  [ "$(meta_field "$finding" last_verification)" = 2026-09-09T12:10:00Z ] || fail "refresh did not bind the observation time"
  assert_grep 'task:consumer-config' "$heal_home/data/heal/INDEX.md" "index hid the current repair owner"
  assert_grep 'exercise the bounded correction in the consumer' "$heal_home/data/heal/INDEX.md" "index hid the current next action"
  assert_not_contains "$(cat "$finding")" 'State the verified symptom' "refresh retained the template as current facts"

  # A candidate made before a later observation cannot overwrite that observation.
  run_owned "$heal_home" observe --id consumer --event-key consumer-later \
    --observed-at 2026-09-09T12:11:00Z --notifications 1 --evidence evidence:later >/dev/null
  before=$(cat "$finding")
  expect_failure 'changed protected metadata' run_owned "$heal_home" publish consumer --candidate "$candidate" \
    --verified-at 2026-09-09T12:12:00Z --evidence evidence:stale-candidate
  [ "$(cat "$finding")" = "$before" ] || fail "stale refresh lost a later observation"
  pass "heal refresh: current owner, action and narrative update together without inventing a lifecycle transition"
}

test_draft_publication_is_refused_and_visible_without_blocking_other_work() {
  local heal_home finding candidate before
  heal_home=$(new_home draft-summary)
  run_owned "$heal_home" init >/dev/null
  new_finding "$heal_home" draft draft-summary
  finding="$heal_home/data/heal/findings/draft.md"
  candidate="$TMP_ROOT/draft-summary-candidate.md"
  cp "$finding" "$candidate"
  before=$(cat "$finding")
  assert_grep 'needs refresh' "$heal_home/data/heal/INDEX.md" "unfinished summary looked current in the index"
  expect_failure 'unfilled finding template' run_owned "$heal_home" publish draft --candidate "$candidate"
  [ "$(cat "$finding")" = "$before" ] || fail "refused publication changed the finding"
  new_finding "$heal_home" independent independent-work
  assert_present "$heal_home/data/heal/findings/independent.md" "one draft blocked unrelated evidence capture"
  pass "heal summaries: unfinished templates remain visible but cannot be republished as a current account"
}

test_new_recurrence_invalidates_old_consumer_proof_but_repeat_notices_do_not() {
  local heal_home finding candidate next_action
  heal_home=$(new_home consumer-recurrence)
  run_owned "$heal_home" init >/dev/null
  new_finding "$heal_home" recurring-consumer consumer-recurrence
  run_owned "$heal_home" transition recurring-consumer Active --reason 'repair started' --owner task:tool >/dev/null
  run_owned "$heal_home" transition recurring-consumer Unverified --reason 'partial consuming proof exists' \
    --evidence tool:installed --proof-required 'remaining affected consumer' \
    --consumer-proof consumer:first-passed >/dev/null
  run_owned "$heal_home" verify recurring-consumer --verified-at 2026-09-09T12:05:00Z \
    --evidence evidence:first-consumer >/dev/null
  finding="$heal_home/data/heal/findings/recurring-consumer.md"
  run_owned "$heal_home" observe --id recurring-consumer --event-key new-consumer-failure \
    --observed-at 2026-09-09T12:06:00Z --notifications 1 --evidence evidence:consumer-failed >/dev/null
  [ -z "$(meta_field "$finding" consumer_proof)" ] || fail "new failure retained old consuming proof as current"
  assert_grep 'needs refresh' "$heal_home/data/heal/INDEX.md" "new recurrence was hidden behind prior verification"
  assert_contains "$(meta_field "$finding" next_action)" 'reconcile' "recurrence kept the obsolete next action"

  candidate="$TMP_ROOT/recurring-consumer-candidate.md"
  current_summary_candidate "$finding" "$candidate"
  next_action='inspect the remaining consumer through task:consumer-config'
  run_owned "$heal_home" publish recurring-consumer --candidate "$candidate" \
    --verified-at 2026-09-09T12:07:00Z --evidence evidence:triaged \
    --owner task:consumer-config --next-action "$next_action" >/dev/null
  run_owned "$heal_home" observe --id recurring-consumer --event-key new-consumer-failure \
    --observed-at 2026-09-09T12:08:00Z --notifications 1 --evidence evidence:repeat >/dev/null
  [ "$(meta_field "$finding" next_action)" = "$next_action" ] || fail "repeat notification undid the current triage"
  [ "$(meta_field "$finding" occurrence_count)" = 2 ] || fail "repeat notification created extra repair work"
  run_owned "$heal_home" observe --id recurring-consumer --event-key earlier-delayed-event \
    --observed-at 2026-09-09T12:03:00Z --notifications 1 --evidence evidence:delayed-history >/dev/null
  [ "$(meta_field "$finding" latest_occurrence)" = 2026-09-09T12:06:00Z ] || fail "late historical evidence moved the latest occurrence backwards"
  [ "$(meta_field "$finding" next_action)" = "$next_action" ] || fail "late historical evidence undid newer triage"
  pass "heal recurrence: fresh failures invalidate old consuming proof while duplicate notices preserve current triage"
}

test_verified_owner_and_read_only_advisor_are_distinct() {
  local home before after loss_home symlink_home outside out status
  home=$(new_home authority)
  [ "$(run_advisor "$home" owner-status)" = advisor ] || fail "unowned invocation did not report advisor mode"
  before=$(find "$home" -mindepth 1 -print | sort)
  expect_failure 'verified session lock ownership required' run_advisor "$home" init
  after=$(find "$home" -mindepth 1 -print | sort)
  [ "$before" = "$after" ] || fail "advisor refusal changed the temporary home"

  [ "$(run_owned "$home" owner-status)" = owner ] || fail "owned invocation did not report owner mode"
  run_owned "$home" init >/dev/null || fail "verified owner could not initialize the ledger"
  assert_present "$home/data/heal/README.md" "owned initialization did not create the navigation pointer"
  assert_present "$home/data/heal/INDEX.md" "owned initialization did not create the rebuildable index"
  assert_present "$home/data/heal/checkpoint.json" "owned initialization did not create an incomplete checkpoint"

  loss_home=$(new_home ownership-loss)
  set +e
  out=$(FM_TEST_DROP_LOCK_ON_ARGS=1 run_owned "$loss_home" init 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "ledger initialized after lock ownership disappeared between checks"
  assert_contains "$out" 'verified session lock ownership required' "mid-command ownership loss was not explained"
  assert_absent "$loss_home/data/heal" "mid-command ownership loss wrote private ledger state"

  symlink_home=$(new_home symlinked-data)
  outside="$TMP_ROOT/symlinked-data-outside"
  mkdir -p "$outside"
  rm -rf "$symlink_home/data"
  ln -s "$outside" "$symlink_home/data"
  set +e
  out=$(run_owned "$symlink_home" init 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "ledger initialization followed a symlinked data directory"
  assert_contains "$out" 'unsafe symlinked directory' "symlink refusal did not identify the unsafe directory"
  assert_absent "$outside/heal" "symlinked data directory redirected private ledger publication"
  pass "heal authority: verified owners may write while advisors remain genuinely read-only"
}

test_repeated_notifications_count_one_occurrence() {
  local home finding
  home=$(new_home notifications)
  run_owned "$home" init >/dev/null
  new_finding "$home" recurring shared-cause
  finding="$home/data/heal/findings/recurring.md"
  run_owned "$home" observe --id recurring --event-key event-recurring-1 \
    --observed-at 2026-09-09T12:01:00Z --notifications 3 --evidence evidence:repeat >/dev/null
  [ "$(meta_field "$finding" occurrence_count)" = 1 ] || fail "repeat notification became a second occurrence"
  [ "$(meta_field "$finding" notification_count)" = 4 ] || fail "repeat notification count was not retained"
  run_owned "$home" observe --id recurring --event-key event-recurring-2 \
    --observed-at 2026-09-09T12:02:00Z --notifications 2 --evidence evidence:new >/dev/null
  [ "$(meta_field "$finding" occurrence_count)" = 2 ] || fail "independent occurrence was not counted"
  [ "$(meta_field "$finding" notification_count)" = 6 ] || fail "notification total diverged from occurrences"
  pass "heal observations: notifications and independent occurrences remain separate"
}

test_existing_owner_is_linked_without_duplicate_finding() {
  local home out status count
  home=$(new_home existing-owner)
  run_owned "$home" init >/dev/null
  new_finding "$home" original same-mechanism recurring-failure task:existing-owner
  set +e
  out=$(run_owned "$home" new \
    --id duplicate --fingerprint same-mechanism --component component-duplicate \
    --title 'Duplicate symptom' --classification recurring-failure --severity high \
    --observed-at 2026-09-09T12:03:00Z --event-key event-duplicate \
    --notifications 1 --evidence evidence:duplicate --owner task:new-owner 2>&1)
  status=$?
  set -e
  [ "$status" -eq 3 ] || fail "duplicate fingerprint was not returned as an existing-owner result: $out"
  assert_contains "$out" 'existing=original owner=task:existing-owner' "duplicate result did not preserve the existing owner link"
  count=$(find "$home/data/heal/findings" -type f -name '*.md' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "duplicate symptom created another authoritative finding"
  pass "heal ownership: a recurring failure links to its existing owner instead of duplicating work"
}

test_historical_verification_does_not_reopen_a_corrected_defect() {
  local home archive
  home=$(new_home historical)
  run_owned "$home" init >/dev/null
  new_finding "$home" historical historical-defect historical-report task:historical
  run_owned "$home" transition historical Closed --reason 'premise disproved by current state' \
    --disposition Disproved --evidence evidence:current-state >/dev/null
  run_owned "$home" archive historical --month 2026-09 >/dev/null
  archive="$home/data/heal/archive/2026-09/historical.md"
  run_owned "$home" verify historical --verified-at 2026-09-09T12:10:00Z \
    --evidence evidence:still-correct >/dev/null
  assert_present "$archive" "verification moved the historical record out of archive"
  assert_absent "$home/data/heal/findings/historical.md" "verification reopened a corrected historical defect"
  [ "$(meta_field "$archive" state)" = Closed ] || fail "verification changed a closed historical state"
  pass "heal refresh: current verification does not reopen an already corrected historical defect"
}

test_legitimate_hold_and_ownerless_obligation_stay_distinct() {
  local home hold obligation
  home=$(new_home classifications)
  run_owned "$home" init >/dev/null
  new_finding "$home" held hold-fingerprint legitimate-hold task:held
  new_finding "$home" ownerless obligation-fingerprint ownerless-obligation none
  hold="$home/data/heal/findings/held.md"
  obligation="$home/data/heal/findings/ownerless.md"
  [ "$(meta_field "$hold" classification)" = legitimate-hold ] || fail "legitimate hold lost its classification"
  [ "$(meta_field "$obligation" classification)" = ownerless-obligation ] || fail "ownerless obligation was collapsed into a hold"
  pass "heal triage: legitimate holds and ownerless accepted obligations are different findings"
}

test_branch_only_correction_stays_unverified_until_consumer_proof() {
  local home finding
  home=$(new_home consuming-proof)
  run_owned "$home" init >/dev/null
  new_finding "$home" branchfix branch-only
  run_owned "$home" transition branchfix Active --reason 'repair started' --owner task:repair >/dev/null
  run_owned "$home" transition branchfix Unverified --reason 'correction exists only on branch' \
    --evidence branch:abc123 --proof-required 'matching consuming runtime' >/dev/null
  finding="$home/data/heal/findings/branchfix.md"
  [ "$(meta_field "$finding" state)" = Unverified ] || fail "branch-only correction did not remain Unverified"
  expect_failure 'Fixed closure requires consuming-workflow proof' run_owned "$home" transition branchfix Closed \
    --reason 'attempted early closure' --disposition Fixed --evidence branch:abc123
  run_owned "$home" transition branchfix Closed --reason 'consumer now uses repair' --disposition Fixed \
    --evidence runtime:abc123 --consumer-proof journey:passed >/dev/null
  [ "$(meta_field "$finding" state)" = Closed ] || fail "consumer-proven repair did not close"
  pass "heal proof: branch-only or inactive corrections remain Unverified until the consumer is proven"
}

test_heal_ledger_is_absent_from_startup_memory_and_digest() {
  local home before after out fake
  home=$(new_home startup-exclusion)
  printf '%s\n' 'captain-memory' > "$home/data/captain.md"
  before=$(FM_HOME="$home" "$MEMORY" report)
  run_owned "$home" init >/dev/null
  mkdir -p "$home/data/heal/findings"
  printf '%s\n' 'HEAL-PRIVATE-SENTINEL-7C2Q' > "$home/data/heal/findings/sentinel.md"
  after=$(FM_HOME="$home" "$MEMORY" report)
  [ "$before" = "$after" ] || fail "data/heal changed automatic startup-memory accounting"

  fake="$TMP_ROOT/startup-fakebin"
  mkdir -p "$fake"
  cp "$FAKEBIN/ps" "$fake/ps"
  fm_fake_exit0 "$fake" tmux node chrome-devtools-axi gh
  fm_fake_version_tool "$fake" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  fm_fake_version_tool "$fake" quota-axi FM_FAKE_QUOTA_AXI_VERSION 0.1.29
  fm_fake_version_tool "$fake" no-mistakes FM_FAKE_NO_MISTAKES_VERSION v1.46.0
  fm_fake_version_tool "$fake" tasks-axi FM_FAKE_TASKS_AXI_VERSION 0.2.4
  fm_fake_version_tool "$fake" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
  cat > "$fake/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = get ] && [ "${2:-}" = --help ] && printf '%s\n' 'Usage: treehouse get [--lease]'
exit 0
SH
  chmod +x "$fake"/*
  printf '%s\n' manual > "$home/config/backlog-backend"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fake:$BASE_PATH" "$SESSION_START")
  assert_not_contains "$out" 'HEAL-PRIVATE-SENTINEL-7C2Q' "session-start digest printed private heal detail"
  pass "heal privacy: the detailed ledger is excluded from startup memory and the startup digest"
}

test_refresh_updates_the_current_repair_without_a_fake_state_change
test_draft_publication_is_refused_and_visible_without_blocking_other_work
test_new_recurrence_invalidates_old_consumer_proof_but_repeat_notices_do_not
test_verified_owner_and_read_only_advisor_are_distinct
test_repeated_notifications_count_one_occurrence
test_existing_owner_is_linked_without_duplicate_finding
test_historical_verification_does_not_reopen_a_corrected_defect
test_legitimate_hold_and_ownerless_obligation_stay_distinct
test_branch_only_correction_stays_unverified_until_consumer_proof
test_heal_ledger_is_absent_from_startup_memory_and_digest
