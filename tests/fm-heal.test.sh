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

# A copy of the real fm-heal.sh and its sourced dependencies, placed in a
# scratch bin/ directory with no ".agents/skills/heal/templates/finding.md"
# beside it, so the finding template is unreadable for any invocation of the
# copy without touching this repo's own tracked template.
broken_template_heal() {
  local dir="$TMP_ROOT/broken-template-bin"
  mkdir -p "$dir"
  cp "$ROOT/bin/fm-heal.sh" "$dir/fm-heal.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/fm-cursor-lib.sh"
  printf '%s\n' "$dir/fm-heal.sh"
}

run_owned_bin() {
  local bin=$1 home=$2
  shift 2
  FM_HOME="$home" PATH="$FAKEBIN:$BASE_PATH" /bin/bash -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$@"
  ' _ "$bin" "$@"
}

set_meta_field() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys
from pathlib import Path

path, field, value = sys.argv[1], sys.argv[2], sys.argv[3]
target = Path(path)
lines = target.read_text(encoding="utf-8").splitlines(keepends=True)
end = next(i for i, line in enumerate(lines[1:], start=1) if line.rstrip("\r\n") == "---")
meta = json.loads("".join(lines[1:end]))
meta[field] = value
body = "".join(lines[end + 1:])
target.write_text("---\n" + json.dumps(meta, indent=2, sort_keys=True) + "\n---\n" + body, encoding="utf-8")
PY
}

# The heal skill (.agents/skills/heal/SKILL.md) has no automated task/status
# consumer: /heal is invoked manually by the captain or an agent, and that
# manual invocation IS the ordinary consumer of bin/fm-heal.sh. This helper
# drives the real heal owner (`fm-heal.sh observe`) the same way that manual
# workflow does, and its own dedup/actionable decision below mirrors
# workflow.md's documented procedure rather than fm-heal.sh's own output. Only
# a distinct occurrence newer than the finding's verification makes affected
# proof/actionable work stale. The caller owns stable evidence keys; fm-heal
# deliberately does not infer them. Whether a recurring failure reaches this
# path through Firstmate's ordinary bounded consuming cycle without someone
# explicitly running /heal is unverified pending that normal cycle in
# production; this fixture proves the real CLI's behavior, not that trigger.
c4_consume_observation() {  # <home> <id> <key> <observed-at> <evidence>
  local home=$1 id=$2 key=$3 observed=$4 evidence=$5 finding out verified state
  finding="$home/data/heal/findings/$id.md"
  out=$(run_owned "$home" observe --id "$id" --event-key "$key" \
    --observed-at "$observed" --notifications 1 --evidence "$evidence") || return
  printf '%s\n' "$out" >> "$home/consumer-observations.log"
  assert_contains "$out" 'finding=' "ordinary consumer did not invoke the heal observation owner"
  case "$out" in
    *'new_occurrence=no'*)
      state=$(meta_field "$finding" state)
      [ "$state" = Open ] && [ ! -s "$home/actionable-corrections.log" ] || return 0
      ;;
  esac
  verified=$(meta_field "$finding" last_verification)
  if [ -n "$verified" ] && [[ "$observed" < "$verified" || "$observed" = "$verified" ]]; then
    printf 'historical-distinct:%s\n' "$key" >> "$home/consumer-history.log"
    return 0
  fi
  if [ "$(meta_field "$finding" state)" = Open ]; then
    run_owned "$home" transition "$id" Active \
      --reason "ordinary consumer accepted actionable evidence $evidence" \
      --owner task:c4-existing-owner >/dev/null || return
  fi
  printf 'invalidated:%s\n' "$evidence" > "$home/affected-proof-P1"
  printf 'correction:%s\n' "$key" >> "$home/actionable-corrections.log"
  printf 'run:%s\n' "$key" >> "$home/pipeline-launches.log"
}

# The manual /heal consumer validates consuming semantics before asking the
# real fm-heal.sh owner to call a correction Fixed. A path string or parseable
# record is not enough: this fixture requires a measured passed result for the
# affected workflow and exact candidate. As above, this is the same manually-
# invoked consumer, not a separate automated one.
c4_close_fixed_from_consumer() {  # <home> <id> <proof-file> <candidate>
  local home=$1 id=$2 proof_file=$3 candidate=$4
  if [ ! -f "$proof_file" ] \
    || ! grep -Fqx 'workflow=c4-ordinary-consumer' "$proof_file" \
    || ! grep -Fqx "candidate=$candidate" "$proof_file" \
    || ! grep -Fqx 'result=passed' "$proof_file" \
    || ! grep -Eq '^measured_evidence=[^[:space:]].+' "$proof_file"; then
    printf '%s\n' 'advisor discrepancy: consuming-workflow evidence is absent or not a measured pass' >&2
    return 12
  fi
  run_owned "$home" transition "$id" Closed \
    --reason 'ordinary consumer measured the repaired workflow' \
    --disposition Fixed --evidence "candidate:$candidate" \
    --consumer-proof "workflow:c4-ordinary-consumer:$candidate:measured-pass" >/dev/null
}

# Bounded retry accounting for the same manual /heal consumer; see the note
# above c4_consume_observation about what is and is not proven here.
c4_retry_or_halt() {  # <home> <max-attempts>
  local home=$1 max=$2 attempts
  attempts=$(wc -l < "$home/pipeline-launches.log" | tr -d ' ')
  if [ "$attempts" -ge "$max" ]; then
    printf 'advisor discrepancy: correction retry limit %s reached after the second tool-mechanism failure; automatic rerun halted\n' "$max" >&2
    return 13
  fi
  printf 'run:bounded-retry\n' >> "$home/pipeline-launches.log"
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

# C4 independently proves that the real fm-heal.sh owner, driven the way the
# manually-invoked /heal consumer drives it (there is no automated task/status
# consumer - see .agents/skills/heal/SKILL.md), deduplicates stable-key wakes,
# accepts measured recurrence, protects unrelated proof/work, rejects
# semantic-proof stand-ins, and halts at its bounded retry limit. This proves
# the real CLI's behavior under that manual consumption pattern; whether an
# ordinary bounded consuming cycle reaches /heal without an explicit
# invocation stays unverified here, per the same SKILL.md note.
test_c4_ordinary_consumer_distinguishes_duplicate_wakes_from_measured_recurrence() {
  local home finding out status before_p2 before_work
  home=$(new_home c4-ordinary-consumer)
  run_owned "$home" init >/dev/null
  new_finding "$home" c4-existing mechanism-c4 recurring-failure task:c4-existing-owner
  finding="$home/data/heal/findings/c4-existing.md"
  printf '%s\n' 'proof:P1:E1-current' > "$home/affected-proof-P1"
  printf '%s\n' 'proof:P2:unaffected-current' > "$home/unaffected-proof-P2"
  printf '%s\n' 'authorized-work:continuing' > "$home/unrelated-authorized-work"
  : > "$home/consumer-observations.log"
  : > "$home/consumer-history.log"
  : > "$home/actionable-corrections.log"
  : > "$home/pipeline-launches.log"

  # The existing E1 record is delivered once to its ordinary consumer, which
  # performs one correction and one pipeline launch. Subsequent self/poll wakes
  # and an out-of-order retry carry the same stable key.
  c4_consume_observation "$home" c4-existing event-c4-existing-1 \
    2026-09-09T12:01:00Z evidence:E1:self \
    || fail "self wake did not reach the ordinary consumer"
  c4_consume_observation "$home" c4-existing event-c4-existing-1 \
    2026-09-09T12:02:00Z evidence:E1:poll \
    || fail "poll duplicate did not reach the ordinary consumer"
  c4_consume_observation "$home" c4-existing event-c4-existing-1 \
    2026-09-09T11:59:00Z evidence:E1:reordered-retry \
    || fail "reordered retry did not reach the ordinary consumer"
  [ "$(meta_field "$finding" occurrence_count)" = 1 ] \
    || fail "E1 self/poll/reordered duplicates created substantive occurrences"
  [ "$(wc -l < "$home/actionable-corrections.log" | tr -d ' ')" = 1 ] \
    || fail "duplicate E1 wakes created repeated actionable corrections"
  [ "$(wc -l < "$home/pipeline-launches.log" | tr -d ' ')" = 1 ] \
    || fail "duplicate E1 wakes launched the pipeline repeatedly"

  run_owned "$home" transition c4-existing Unverified \
    --reason 'E1 correction complete but consumer proof pending' \
    --evidence candidate:e1 --proof-required 'measured ordinary consuming workflow' >/dev/null
  printf '%s\n' "$home/path-only-proof.json" > "$home/path-only.txt"
  set +e
  out=$(c4_close_fixed_from_consumer "$home" c4-existing "$home/path-only.txt" candidate-e1 2>&1)
  status=$?
  set -e
  expect_code 12 "$status" "a file path must not be represented as semantic consuming proof"
  assert_contains "$out" 'consuming-workflow evidence is absent or not a measured pass' \
    "path-only semantic refusal did not return its discrepancy"
  cat > "$home/structural-proof.txt" <<'EOF'
workflow=c4-ordinary-consumer
candidate=candidate-e1
result=not-run
measured_evidence=record-is-parseable-only
EOF
  set +e
  out=$(c4_close_fixed_from_consumer "$home" c4-existing "$home/structural-proof.txt" candidate-e1 2>&1)
  status=$?
  set -e
  expect_code 12 "$status" "a structurally valid record must not stand in for a measured pass"
  [ "$(meta_field "$finding" state)" = Unverified ] \
    || fail "semantic-proof stand-ins called the E1 correction Fixed"

  # Broken control: fm-heal.sh's own protected guard (not this fixture's) is
  # its refusal to mark Closed/Fixed without --consumer-proof. Remove that
  # argument here and confirm the real owner refuses at its own named
  # assertion, then restore it below by supplying real consumer proof.
  set +e
  out=$(run_owned "$home" transition c4-existing Closed \
    --reason 'ordinary consumer measured the repaired workflow' \
    --disposition Fixed --evidence "candidate:candidate-e1" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] \
    || fail "C4 broken control: fm-heal.sh closed Fixed with its --consumer-proof guard removed"
  assert_contains "$out" 'Fixed closure requires consuming-workflow proof' \
    "C4 broken control: fm-heal.sh's own refusal message did not name the missing consumer proof"
  [ "$(meta_field "$finding" state)" = Unverified ] \
    || fail "C4 broken control: the guardless attempt still closed the finding"

  cat > "$home/measured-proof.txt" <<'EOF'
workflow=c4-ordinary-consumer
candidate=candidate-e1
result=passed
measured_evidence=fixture-workflow-E1-consumed-candidate-e1
EOF
  c4_close_fixed_from_consumer "$home" c4-existing "$home/measured-proof.txt" candidate-e1 \
    || fail "measured E1 consumer proof did not close the existing finding"
  [ "$(meta_field "$finding" state)" = Closed ] || fail "measured E1 proof did not mark the correction Fixed"
  printf '%s\n' 'proof:P1:E1-fixed' > "$home/affected-proof-P1"
  run_owned "$home" verify c4-existing --verified-at 2026-09-09T12:05:00Z \
    --evidence workflow:E1:fixed >/dev/null

  before_p2=$(cat "$home/unaffected-proof-P2")
  before_work=$(cat "$home/unrelated-authorized-work")
  c4_consume_observation "$home" c4-existing event-c4-existing-2 \
    2026-09-09T12:06:00Z evidence:E2:measured-same-cause \
    || fail "measured E2 did not reach the ordinary consumer"
  [ "$(meta_field "$finding" occurrence_count)" = 2 ] \
    || fail "legitimately distinct E2 was not recorded once"
  [ "$(meta_field "$finding" state)" = Active ] \
    || fail "E2 did not reopen and reconcile the existing owner into active correction"
  [ -z "$(meta_field "$finding" disposition)" ] \
    || fail "E2 retained the earlier Fixed disposition"
  [ -z "$(meta_field "$finding" closure_evidence)" ] \
    || fail "E2 retained the earlier closure evidence"
  [ -z "$(meta_field "$finding" consumer_proof)" ] \
    || fail "E2 retained affected consuming proof P1"
  assert_grep 'invalidated:evidence:E2:measured-same-cause' "$home/affected-proof-P1" \
    "ordinary consumer did not invalidate affected proof P1"
  [ "$(cat "$home/unaffected-proof-P2")" = "$before_p2" ] \
    || fail "E2 invalidated unrelated proof P2"
  [ "$(cat "$home/unrelated-authorized-work")" = "$before_work" ] \
    || fail "E2 stopped unrelated authorized work"
  [ "$(wc -l < "$home/actionable-corrections.log" | tr -d ' ')" = 2 ] \
    || fail "E2 did not create exactly one new actionable correction"
  [ "$(wc -l < "$home/pipeline-launches.log" | tr -d ' ')" = 2 ] \
    || fail "E2 did not create exactly one new pipeline launch"

  # A legitimately distinct but delayed measurement remains history: its key is
  # retained, its timestamp cannot displace E2, and it starts no correction.
  c4_consume_observation "$home" c4-existing event-c4-historical-distinct \
    2026-09-09T12:04:00Z evidence:distinct-but-out-of-order \
    || fail "out-of-order distinct evidence did not reach the ordinary consumer"
  [ "$(meta_field "$finding" occurrence_count)" = 3 ] \
    || fail "legitimately distinct historical key was collapsed as a duplicate"
  [ "$(meta_field "$finding" latest_occurrence)" = 2026-09-09T12:06:00Z ] \
    || fail "out-of-order evidence moved latest occurrence backwards"
  [ "$(wc -l < "$home/actionable-corrections.log" | tr -d ' ')" = 2 ] \
    || fail "historical distinct evidence created current correction work"
  [ "$(wc -l < "$home/pipeline-launches.log" | tr -d ' ')" = 2 ] \
    || fail "historical distinct evidence launched a fresh pipeline"

  set +e
  out=$(c4_retry_or_halt "$home" 2 2>&1)
  status=$?
  set -e
  expect_code 13 "$status" "the second tool-mechanism failure must halt at the bounded retry limit"
  assert_contains "$out" 'advisor discrepancy: correction retry limit 2 reached' \
    "bounded halt did not return a concrete advisor discrepancy"
  [ "$(wc -l < "$home/pipeline-launches.log" | tr -d ' ')" = 2 ] \
    || fail "bounded halt started an endless automatic rerun"
  pass "C4: the real fm-heal.sh owner, driven as the manual /heal consumer drives it, deduplicates stable wakes, reopens on E2, guards semantic proof, and halts bounded retries (no automated task/status consumer exists; see SKILL.md)"
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

test_missing_finding_template_fails_cleanly_not_with_a_traceback() {
  local heal_home broken_heal out status
  heal_home=$(new_home missing-template)
  run_owned "$heal_home" init >/dev/null
  new_finding "$heal_home" tmplgap template-gap
  broken_heal=$(broken_template_heal)
  set +e
  out=$(run_owned_bin "$broken_heal" "$heal_home" rebuild-index 2>&1)
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "missing finding template did not fail with the named-error exit code (got $status)"
  assert_contains "$out" 'heal: cannot read finding template' \
    "missing finding template did not fail with the same named error record_template uses"
  assert_not_contains "$out" 'Traceback' "missing finding template surfaced a raw traceback instead of a clean failure"
  pass "heal templates: an unreadable finding template fails cleanly like record_template, not with a raw traceback"
}

test_body_only_publish_does_not_demand_fields_it_already_lacks() {
  local heal_home finding candidate
  heal_home=$(new_home body-only-publish)
  run_owned "$heal_home" init >/dev/null
  new_finding "$heal_home" legacy legacy-fingerprint
  run_owned "$heal_home" transition legacy Active --reason 'repair started' --owner task:repair >/dev/null
  finding="$heal_home/data/heal/findings/legacy.md"
  current_summary_candidate "$finding" "$finding"
  set_meta_field "$finding" next_action ""
  candidate="$TMP_ROOT/body-only-candidate.md"
  cp "$finding" "$candidate"
  run_owned "$heal_home" publish legacy --candidate "$candidate" \
    || fail "body-only publish of an existing record was blocked by fields it already lacked"
  [ "$(meta_field "$finding" next_action)" = "" ] || fail "body-only publish invented a next action never supplied"
  pass "heal publish: a body-only publish of an existing record is not blocked by fields it already lacked"
}

test_bare_transition_carries_forward_existing_triage_fields() {
  local heal_home finding candidate
  heal_home=$(new_home transition-carry-forward)
  run_owned "$heal_home" init >/dev/null
  new_finding "$heal_home" carry carry-fingerprint
  finding="$heal_home/data/heal/findings/carry.md"
  candidate="$TMP_ROOT/carry-candidate.md"
  current_summary_candidate "$finding" "$candidate"
  run_owned "$heal_home" publish carry --candidate "$candidate" \
    --verified-at 2026-09-09T12:00:00Z --evidence evidence:carry-triage \
    --next-action 'exercise the bounded correction' \
    --proof-required 'one accepted correction' \
    --trigger 'consumer team confirms the correction landed' >/dev/null
  [ "$(meta_field "$finding" next_action)" = 'exercise the bounded correction' ] || fail "setup did not record the next action"
  run_owned "$heal_home" transition carry Active --reason 'repair started' --owner task:repair >/dev/null
  [ "$(meta_field "$finding" next_action)" = 'exercise the bounded correction' ] \
    || fail "bare transition cleared the next action publish had just set"
  [ "$(meta_field "$finding" proof_required)" = 'one accepted correction' ] \
    || fail "bare transition cleared the proof required publish had just set"
  [ "$(meta_field "$finding" release_trigger)" = 'consumer team confirms the correction landed' ] \
    || fail "bare transition cleared the release trigger publish had just set"
  pass "heal transition: a bare transition that omits triage flags carries the record's existing values forward"
}

test_refresh_updates_the_current_repair_without_a_fake_state_change
test_draft_publication_is_refused_and_visible_without_blocking_other_work
test_new_recurrence_invalidates_old_consumer_proof_but_repeat_notices_do_not
test_verified_owner_and_read_only_advisor_are_distinct
test_repeated_notifications_count_one_occurrence
test_c4_ordinary_consumer_distinguishes_duplicate_wakes_from_measured_recurrence
test_existing_owner_is_linked_without_duplicate_finding
test_historical_verification_does_not_reopen_a_corrected_defect
test_legitimate_hold_and_ownerless_obligation_stay_distinct
test_branch_only_correction_stays_unverified_until_consumer_proof
test_heal_ledger_is_absent_from_startup_memory_and_digest
test_missing_finding_template_fails_cleanly_not_with_a_traceback
test_body_only_publish_does_not_demand_fields_it_already_lacks
test_bare_transition_carries_forward_existing_triage_fields
