#!/usr/bin/env bash
# Behavior tests for bin/fm-grok-bot-dispatch.sh.
#
# Drives the public argv interface against a stub bridge (FM_GROKBOT_BRIDGE)
# that records every call and answers like grokbot.mjs, so a routed task is
# proven to reach the bridge without touching Grok Bot or any credential.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-grok-bot-dispatch.sh"
TMP_ROOT=$(fm_test_tmproot fm-grok-bot-dispatch)
BRIDGE="$TMP_ROOT/grokbot.mjs"
LOG="$TMP_ROOT/calls.jsonl"
BRIEF="$TMP_ROOT/brief.md"
export FM_GROKBOT_BRIDGE="$BRIDGE" STUB_LOG="$LOG"

cat > "$BRIDGE" <<'JS'
import { appendFileSync } from "node:fs";
import { copyFileSync, existsSync } from "node:fs";
const [cmd, ...a] = process.argv.slice(2);
appendFileSync(process.env.STUB_LOG, JSON.stringify([cmd, ...a]) + "\n");
// What the walk marker held while the Bot was working, if the test asks.
if (cmd === "chat" && process.env.STUB_SNAP) {
  if (existsSync(process.env.STUB_MARKER)) copyFileSync(process.env.STUB_MARKER, process.env.STUB_SNAP);
  else appendFileSync(process.env.STUB_SNAP, "");
}
if (cmd === "chat" && process.env.STUB_CHAT_FAIL === "1") process.exit(1);
if (cmd === "chat" && process.env.STUB_CHAT_WAIT === "1") {
  await new Promise(resolve => setTimeout(resolve, 10000));
}
const out = (o) => console.log(JSON.stringify(o, null, 2));
if (cmd === "list") {
  out([{ id: "a1", name: "fm-researcher" }, { id: "b1", name: "twin" }, { id: "b2", name: "twin" }]);
} else if (cmd === "chat") {
  out({ sent: { ok: true } });
  out({ stillRunning: process.env.STUB_RUNNING === "1",
        newEntries: [{ id: 1, text: a[1] }, { id: 2, text: "Finding one. https://example.com/a" }] });
} else process.exit(1);
JS

cat > "$BRIEF" <<'MD'
# Task
## Captain's intent
"compare the three public trading-journal repos"

## Firstmate spec
- Read each public repository and report differences.

# Setup
SECRET-SETUP-TEXT that must stay on this machine.
MD

run() {  # <code-var> <out-var> <err-var> args...
  local _c=$1 _o=$2 _e=$3 _out _code
  shift 3
  _out=$("$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$_c" '%s' "$_code"
  printf -v "$_o" '%s' "$_out"
  printf -v "$_e" '%s' "$(cat "$TMP_ROOT/stderr")"
}

code='' out='' err=''
run code out err "$BRIEF" --bot fm-researcher --timeout 30
expect_code 0 "$code" "a routed task reaches the bridge"
assert_contains "$out" 'Finding one. https://example.com/a' "the Bot reply is returned"
assert_contains "$out" 'grok-bot: unverified reply from fm-researcher' "the reply is marked unverified"
assert_not_contains "$out" 'compare the three' "the echoed prompt is not part of the reply"
chat=$(grep '^\["chat"' "$LOG")
assert_contains "$chat" '"a1"' "the Bot name resolves to its id"
assert_contains "$chat" 'compare the three public trading-journal repos' "the captain's intent is sent"
assert_contains "$chat" 'Read each public repository' "the Firstmate spec is sent"
assert_not_contains "$chat" 'SECRET-SETUP-TEXT' "the rest of the brief stays local"
assert_contains "$chat" '"30"' "the timeout is passed through"
pass "a routed task reaches the named Bot with only its task sections"

STUB_RUNNING=1 run code out err "$BRIEF" --bot fm-researcher
expect_code 3 "$code" "a Bot still working at the timeout exits 3"
assert_contains "$err" 'still working' "the timeout is explained"
pass "a still-working Bot exits 3"

: > "$LOG"
run code out err "$BRIEF" --bot nobody
expect_code 2 "$code" "an unknown Bot refuses"
assert_contains "$err" 'exactly one Grok Bot named nobody' "the unknown Bot is named"
run code out err "$BRIEF" --bot twin
expect_code 2 "$code" "an ambiguous Bot name refuses"
assert_no_grep '["chat"' "$LOG" "nothing is sent to an unresolved Bot"
FM_GROKBOT_BRIDGE="$TMP_ROOT/missing.mjs" run code out err "$BRIEF" --bot fm-researcher
expect_code 2 "$code" "a missing bridge refuses"
assert_contains "$err" 'Grok Bot bridge not found' "the missing bridge is named"
assert_contains "$err" 'run only in the home that holds the bridge (the primary)' "the missing bridge names the primary-only rule"
assert_contains "$err" "treat this candidate as unavailable" "the missing bridge says how to route on"
run code out err "$BRIEF"
expect_code 2 "$code" "a missing --bot refuses"
pass "unknown, ambiguous, and missing inputs refuse before sending"

# --- Walk marker (--walk): claimed before the Bot is sent, released on its reply or timeout ---
# The fake transport runs the shipped marker program locally against a scratch
# state home, exactly as a private transport would run it on the marker's host.
STATE="$TMP_ROOT/state"
MARKER="$STATE/q-walk/in-progress.json"
SNAP="$TMP_ROOT/marker-during-chat.json"
TRANSPORT="$TMP_ROOT/walk-transport"
cat > "$TRANSPORT" <<'SH'
#!/usr/bin/env bash
printf '["transport","%s"]\n' "$*" >> "$STUB_LOG"
[ "${TRANSPORT_FAIL:-}" != "$1" ] || exit 1
if [ "${TRANSPORT_RECEIPT_OP:-}" = "$1" ]; then
  printf '%s' "${TRANSPORT_RECEIPT:-}"
  exit 0
fi
program=$(cat)
if [ "$1" = release ] && [ -n "${TRANSPORT_RECOVERY:-}" ]; then
  XDG_STATE_HOME="$TRANSPORT_STATE" FM_WALK_MARKER_NOW=2026-10-07T10:05:00Z \
    python3 - claim "$2" "$3" 300 <<<"$program" > "$TRANSPORT_RECOVERY_RECEIPT" || exit 1
  if [ "$TRANSPORT_RECOVERY" = overlap ]; then
    XDG_STATE_HOME="$TRANSPORT_STATE" FM_WALK_MARKER_NOW=2026-10-07T10:05:01Z \
      python3 - claim QW-42 "$3" 600 <<<"$program" > "$TRANSPORT_RECOVERY_RECEIPT" || exit 1
  fi
fi
receipt=$(XDG_STATE_HOME="$TRANSPORT_STATE" python3 - "$@" <<<"$program") || { printf '%s\n' "$receipt"; exit 1; }
if [ "$1" = claim ] && [ -n "${TRANSPORT_DELAY:-}" ]; then
  sleep "$TRANSPORT_DELAY"
fi
printf '%s\n' "$receipt"
SH
chmod +x "$TRANSPORT"
export FM_WALK_MARKER_TRANSPORT="$TRANSPORT" TRANSPORT_STATE="$STATE" STUB_MARKER="$MARKER"
export FM_WALK_MARKER_NOW=2026-10-07T10:00:00Z

marker() {  # <json>: seed the marker file
  mkdir -p "$STATE/q-walk"
  printf '%s\n' "$1" > "$MARKER"
}
field() {  # <file> <jq expr>
  jq -c "$2" "$1"
}
walk_run() {  # like run, with the stub snapshot reset
  : > "$LOG"
  rm -f "$SNAP"
  STUB_SNAP="$SNAP" run "$@"
}

rm -rf "$STATE"
walk_run code out err "$BRIEF" --bot fm-researcher --timeout 30
expect_code 0 "$code" "a dispatch without --walk is unchanged"
assert_no_grep '["transport"' "$LOG" "a dispatch without --walk never touches the marker"
assert_absent "$MARKER" "a dispatch without --walk writes no marker"
pass "non-walk dispatch is unchanged"

walk_run code out err "$BRIEF" --bot fm-researcher --timeout 300 --walk QW-41 --walk-owner firstmate-main
expect_code 0 "$code" "a walk dispatch succeeds"
assert_contains "$out" 'Finding one.' "the walk reply is returned"
order=$(jq -r '.[0] + (if .[0] == "transport" then ":" + (.[1] | split(" ")[0]) else "" end)' "$LOG" | tr '\n' ' ')
assert_equals "list transport:claim chat transport:release " "$order" "the walk is claimed after the Bot resolves, before it is sent, and released after its reply"
assert_equals '["QW-41"]' "$(field "$SNAP" .walks)" "the marker names the walk while it runs"
assert_equals '"firstmate-main"' "$(field "$SNAP" .owner)" "the marker names its owner"
assert_equals '"2026-10-07T10:00:00Z"' "$(field "$SNAP" .started)" "the marker starts at the marker host's clock"
assert_equals '"2026-10-07T10:05:00Z"' "$(field "$SNAP" .expires_at)" "the marker expires when the walk's timeout ends"
assert_absent "$MARKER" "the walk's own marker is cleared when its report lands"
pass "a walk is claimed before dispatch and cleared on its report"

STUB_RUNNING=1 walk_run code out err "$BRIEF" --bot fm-researcher --timeout 300 --walk QW-41 --walk-owner firstmate-main
expect_code 3 "$code" "a walk still running at the timeout exits 3"
assert_absent "$MARKER" "the walk's marker is cleared at its timeout"
pass "a walk's marker ends at its timeout"

marker '{"walks":["QW-40"],"started":"2026-10-07T09:58:00Z","expires_at":"2026-10-07T10:30:00Z","owner":"firstmate-main"}'
walk_run code out err "$BRIEF" --bot fm-researcher --timeout 300 --walk QW-41 --walk-owner firstmate-main
expect_code 0 "$code" "an overlapping walk of the same owner is sent"
assert_equals '["QW-40","QW-41"]' "$(field "$SNAP" .walks)" "an overlapping walk joins the active claim"
assert_equals '"2026-10-07T09:58:00Z"' "$(field "$SNAP" .started)" "the earlier start is kept"
assert_equals '"2026-10-07T10:30:00Z"' "$(field "$SNAP" .expires_at)" "the later expiry is kept"
assert_equals '["QW-40"]' "$(field "$MARKER" .walks)" "only the finished walk is removed; the overlapping claim survives"
assert_equals '"2026-10-07T10:30:00Z"' "$(field "$MARKER" .expires_at)" "the surviving claim keeps its expiry"
pass "overlapping walks release only their own claim"

active='{"walks":["QW-40","QW-41"],"started":"2026-10-07T09:58:00Z","expires_at":"2026-10-07T10:30:00Z","owner":"firstmate-main"}'
for owner in firstmate-main sol-operator; do
  marker "$active"
  walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner "$owner"
  expect_code 2 "$code" "a repeated active walk refuses for $owner"
  assert_no_grep '["chat"' "$LOG" "a repeated active walk never starts a second chat"
  assert_no_grep '["transport","release' "$LOG" "a refused duplicate never releases its predecessor"
  assert_equals "$active" "$(cat "$MARKER")" "a duplicate claim preserves the predecessor and its sibling"
done
pass "an active walk cannot be dispatched twice"

for seed in '' '{"walks":["QW-40"],"started":"2026-10-07T09:58:00Z","expires_at":"2026-10-07T10:30:00Z","owner":"firstmate-main"}'; do
  rm -f "$MARKER"
  [ -z "$seed" ] || marker "$seed"
  TRANSPORT_DELAY=2 walk_run code out err "$BRIEF" --bot fm-researcher --timeout 30 --walk QW-41 --walk-owner firstmate-main
  expect_code 0 "$code" "a delayed claim retains time for a successful chat"
  budget=$(jq -r 'select(.[0] == "chat") | .[3] | tonumber' "$LOG")
  [ "$budget" -gt 0 ] && [ "$budget" -le 28 ] || fail "publication time is deducted from the chat budget ($budget)"
  if [ -n "$seed" ]; then
    assert_equals '["QW-40"]' "$(field "$MARKER" .walks)" "a delayed overlapping report preserves its sibling"
  else
    assert_absent "$MARKER" "a delayed report clears its own claim"
  fi
done
TRANSPORT_DELAY=2 walk_run code out err "$BRIEF" --bot fm-researcher --timeout 1 --walk QW-41 --walk-owner firstmate-main
expect_code 3 "$code" "publication exhausting the budget times out"
assert_no_grep '["chat"' "$LOG" "an exhausted publication budget never sends a chat"
assert_equals '["QW-40"]' "$(field "$MARKER" .walks)" "an exhausted dispatch releases only its own walk"
STUB_CHAT_WAIT=1 walk_run code out err "$BRIEF" --bot fm-researcher --timeout 1 --walk QW-41 --walk-owner firstmate-main
expect_code 3 "$code" "an unresponsive bridge is terminated at the dispatch deadline"
assert_contains "$err" 'dispatch deadline' "the enforced timeout is explained"
assert_equals '["QW-40"]' "$(field "$MARKER" .walks)" "an enforced timeout preserves the overlapping claim"
pass "publication and chat share one bounded budget, including overlaps"

other='{"walks":["QW-9"],"started":"2026-10-07T09:55:00Z","expires_at":"2026-10-07T10:05:00Z","owner":"sol-operator"}'
marker "$other"
FM_WALK_MARKER_NOW=2026-10-07T10:04:00Z walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner firstmate-main
expect_code 2 "$code" "another owner's active claim refuses the walk"
assert_contains "$err" 'sol-operator' "the refusal names the other owner"
assert_no_grep '["chat"' "$LOG" "nothing is sent while another owner holds the marker"
assert_equals "$other" "$(cat "$MARKER")" "another owner's claim is left untouched"
pass "another owner's active claim is preserved and refuses the walk"

marker "$other"
FM_WALK_MARKER_NOW=2026-10-07T10:05:00Z walk_run code out err "$BRIEF" --bot fm-researcher --timeout 300 --walk QW-41 --walk-owner firstmate-main
expect_code 0 "$code" "an expired claim does not block a walk"
assert_equals '["QW-41"]' "$(field "$SNAP" .walks)" "an expired claim is replaced"
assert_absent "$MARKER" "the replacing walk clears its own marker"
pass "an expired claim releases at its expiry"

for bad in 'not json' '{"walks":[],"started":"2026-10-07T09:55:00Z","expires_at":"2026-10-07T10:30:00Z","owner":"x"}' \
  '{"walks":["QW-9"],"started":"2026-10-07T09:55:00Z","expires_at":"2026-10-07 10:30","owner":"x"}'; do
  marker "$bad"
  walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner firstmate-main
  expect_code 2 "$code" "a malformed marker refuses the walk ($bad)"
  assert_no_grep '["chat"' "$LOG" "nothing is sent past a malformed marker"
  assert_equals "$bad" "$(cat "$MARKER")" "a malformed marker is left for its owner"
done
pass "a malformed marker refuses safely"

for clock in 2026-10-07T10:00:00Z 2026-10-07T11:00:00Z; do
  for bad in \
    '{"walks":["QW-41"],"started":"2026-10-7T09:55:00Z","expires_at":"2026-10-07T10:30:00Z","owner":"firstmate-main"}' \
    '{"walks":["QW-41"],"started":"2026-10-07T09:55:00Z","expires_at":"2026-10-7T10:30:00Z","owner":"firstmate-main"}' \
    '{"walks":["QW-41","QW-41"],"started":"2026-10-07T09:55:00Z","expires_at":"2026-10-07T10:30:00Z","owner":"firstmate-main"}'; do
    for op in claim release; do
      marker "$bad"
      argument=300
      [ "$op" != release ] || argument=2026-10-07T09:55:00Z
      marker_result=$(XDG_STATE_HOME="$STATE" FM_WALK_MARKER_NOW="$clock" \
        python3 "$ROOT/bin/fm-walk-marker.py" "$op" QW-41 firstmate-main "$argument")
      expect_code 1 "$?" "an active or expired malformed marker refuses $op"
      assert_contains "$marker_result" 'malformed' "the producer reports malformed persisted input"
      assert_equals "$bad" "$(cat "$MARKER")" "validation precedes every marker mutation"
    done
    FM_WALK_MARKER_NOW="$clock" walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner firstmate-main
    expect_code 2 "$code" "an active or expired malformed marker refuses dispatch"
    assert_no_grep '["chat"' "$LOG" "a malformed persisted claim never starts a chat"
    assert_equals "$bad" "$(cat "$MARKER")" "dispatch leaves malformed persisted input untouched"
  done
done
pass "claim and release refuse noncanonical timestamps and duplicate walks before mutation"

rm -f "$MARKER"
first_claim=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" claim QW-41 firstmate-main 300)
expect_code 0 "$?" "the public producer creates a lease"
lease_start=$(jq -r .started <<<"$first_claim")
second_claim=$(XDG_STATE_HOME="$STATE" FM_WALK_MARKER_NOW=2026-10-07T10:01:00Z \
  python3 "$ROOT/bin/fm-walk-marker.py" claim QW-42 firstmate-main 1200)
expect_code 0 "$?" "an overlapping claim extends the lease"
assert_equals "$lease_start" "$(jq -r .started <<<"$second_claim")" "an extension preserves the lease identity"
marker_before=$(cat "$MARKER")
marker_result=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" release QW-41 firstmate-main)
expect_code 2 "$?" "a release without a lease identity refuses"
assert_equals "$marker_before" "$(cat "$MARKER")" "an unbound release leaves the lease untouched"
marker_result=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" release QW-41 firstmate-main "$lease_start")
expect_code 0 "$?" "the first walk can release after a sibling extends the lease"
assert_equals '["QW-42"]' "$(field "$MARKER" .walks)" "the extension's walk survives the older walk's release"
assert_equals '"2026-10-07T10:21:00Z"' "$(field "$MARKER" .expires_at)" "the extended expiry survives"
marker_result=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" release QW-41 firstmate-main "$lease_start")
expect_code 0 "$?" "a matching repeated release is idempotent"
assert_equals 'not-listed' "$(jq -r .result <<<"$marker_result")" "a repeated release reports the preserved lease"
marker_result=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" release QW-42 firstmate-main "$lease_start")
expect_code 0 "$?" "the final matching walk clears the extended lease"
assert_absent "$MARKER" "the final matching release removes the marker"
marker_result=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" release QW-42 firstmate-main "$lease_start")
expect_code 0 "$?" "an absent matching claim stays idempotent"
assert_equals 'absent' "$(jq -r .result <<<"$marker_result")" "an absent release reports absence"
pass "release binds to the stable lease start while sibling expiry extensions remain valid"

for recovery in single overlap; do
  for terminal in report timeout failed-send; do
    rm -f "$MARKER"
    running=0 chat_fail=0 expected=4
    case "$terminal" in
      timeout) running=1 ;;
      failed-send) chat_fail=1 expected=2 ;;
    esac
    TRANSPORT_RECOVERY="$recovery" TRANSPORT_RECOVERY_RECEIPT="$TMP_ROOT/recovered.json" \
      STUB_RUNNING="$running" STUB_CHAT_FAIL="$chat_fail" \
      walk_run code out err "$BRIEF" --bot fm-researcher --timeout 300 --walk QW-41 --walk-owner firstmate-main
    expect_code "$expected" "$code" "a delayed $terminal release refuses a replacement lease ($recovery)"
    assert_contains "$err" 'release failed' "a stale release remains actionable"
    assert_contains "$err" 'lease changed' "a stale release names the changed lease"
    assert_equals "$(jq -Sc 'del(.result)' "$TMP_ROOT/recovered.json")" "$(jq -Sc . "$MARKER")" \
      "a stale release preserves the complete replacement and its sibling claims"
    assert_equals '"2026-10-07T10:05:00Z"' "$(field "$MARKER" .started)" "recovery creates a distinct lease identity"
  done
done
pass "delayed terminal releases cannot clear or rewrite recovered leases"

rm -rf "$STATE"
TRANSPORT_FAIL=claim walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner firstmate-main
expect_code 2 "$code" "a failed claim refuses the walk"
assert_contains "$err" 'walk marker' "the failed claim is explained"
assert_no_grep '["chat"' "$LOG" "nothing is sent when the claim fails"
FM_WALK_MARKER_TRANSPORT="$TMP_ROOT/missing-transport" walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner firstmate-main
expect_code 2 "$code" "a missing transport refuses the walk"
assert_contains "$err" 'walk marker transport not found' "the missing transport is named"
assert_no_grep '["chat"' "$LOG" "nothing is sent without a transport"
walk_run code out err "$BRIEF" --bot nobody --walk QW-41 --walk-owner firstmate-main
expect_code 2 "$code" "an unknown Bot refuses a walk"
assert_no_grep '["transport"' "$LOG" "no claim is made for an unresolved Bot"
walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41
expect_code 2 "$code" "a walk without an owner refuses"
walk_run code out err "$BRIEF" --bot fm-researcher --walk 'QW 41;rm' --walk-owner firstmate-main
expect_code 2 "$code" "an unsafe walk id refuses"
assert_no_grep '["transport"' "$LOG" "invalid walk options touch nothing"
pass "claim, transport and option failures refuse before sending"

claimed='{"result":"claimed","walks":["QW-41"],"owner":"firstmate-main","started":"2026-10-07T10:00:00Z","expires_at":"2026-10-07T10:05:00Z"}'
for bad in '' '{}' '[]' '{"result":"refused","reason":"held"}' \
  "$(jq -c '.result = "released"' <<<"$claimed")" \
  "$(jq -c '.walks = ["QW-40"]' <<<"$claimed")" \
  "$(jq -c '.walks = []' <<<"$claimed")" \
  "$(jq -c '.walks = [null]' <<<"$claimed")" \
  "$(jq -c '.owner = "sol-operator"' <<<"$claimed")" \
  "$(jq -c 'del(.started)' <<<"$claimed")" \
  "$(jq -c '.started = "2026-10-07T10:05:00Z"' <<<"$claimed")" \
  "$(jq -c '.expires_at = "2026-02-30T10:05:00Z"' <<<"$claimed")" \
  "$claimed"$'\n'"$claimed"; do
  TRANSPORT_RECEIPT_OP=claim TRANSPORT_RECEIPT="$bad" walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner firstmate-main
  expect_code 2 "$code" "a malformed or refused success-status claim refuses ($bad)"
  assert_no_grep '["chat"' "$LOG" "an invalid claim receipt never sends a chat"
done
pass "claim receipts must prove the requested walk and a canonical lease"

STUB_CHAT_FAIL=1 walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner firstmate-main
expect_code 2 "$code" "a failed chat still fails"
assert_grep '["transport","release' "$LOG" "a failed chat releases its claim"
assert_absent "$MARKER" "a failed chat leaves no claim behind"
pass "a failed send releases its own claim"

TRANSPORT_FAIL=release walk_run code out err "$BRIEF" --bot fm-researcher --timeout 300 --walk QW-41 --walk-owner firstmate-main
expect_code 4 "$code" "a failed release exits 4"
assert_contains "$out" 'Finding one.' "the reply is still returned when the release fails"
assert_contains "$err" 'release failed' "the failed release is reported"
assert_contains "$err" '2026-10-07T10:05:00Z' "the failed release names when the claim expires on its own"
assert_equals '["QW-41"]' "$(field "$MARKER" .walks)" "a failed release never claims a clear"
pass "a failed release stays an actionable failure"

released='{"result":"released","walks":["QW-40"],"owner":"firstmate-main","started":"2026-10-07T10:00:00Z","expires_at":"2026-10-07T10:05:00Z"}'
for bad in '' '{}' '{"result":"refused"}' "$claimed" \
  "$(jq -c '.walks = ["QW-41"]' <<<"$released")" \
  "$(jq -c '.owner = "sol-operator"' <<<"$released")" \
  "$(jq -c '.started = "2026-10-07T10:01:00Z"' <<<"$released")" \
  "$(jq -c 'del(.expires_at)' <<<"$released")" \
  "$(jq -c '.started = .expires_at' <<<"$released")" \
  "$(jq -c '.result = "not-listed" | .walks = ["QW-41"]' <<<"$released")"; do
  for running in 0 1; do
    rm -f "$MARKER"
    TRANSPORT_RECEIPT_OP=release TRANSPORT_RECEIPT="$bad" STUB_RUNNING="$running" walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner firstmate-main
    expect_code 4 "$code" "an invalid release after a report or timeout remains actionable ($bad)"
    assert_contains "$err" 'release failed' "an invalid release is reported"
    assert_equals '["QW-41"]' "$(field "$MARKER" .walks)" "a refused release never manufactures a clear"
  done
done
pass "release receipts must prove removal and validate every remaining claim"

echo "# all fm-grok-bot-dispatch tests passed"
