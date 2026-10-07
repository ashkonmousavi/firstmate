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
import { appendFileSync, copyFileSync, existsSync } from "node:fs";
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
  if (process.env.STUB_CHAT_FAIL === "1") process.exit(1);
  // Hold this chat open until the test creates the release file (bounded at 30s).
  for (let i = 0; process.env.STUB_CHAT_HOLD && !existsSync(process.env.STUB_CHAT_HOLD) && i < 600; i++)
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
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
[ "${TRANSPORT_STALL:-}" != "$1" ] || exec sleep 5
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

marker '{"walks":["QW-40"],"started":"2026-10-07T09:58:00Z","expires_at":"2026-10-07T10:30:00Z","owner":"firstmate-main","claims":{"QW-40":"2222222222222222"}}'
walk_run code out err "$BRIEF" --bot fm-researcher --timeout 300 --walk QW-41 --walk-owner firstmate-main
expect_code 0 "$code" "an overlapping walk of the same owner is sent"
assert_equals '["QW-40","QW-41"]' "$(field "$SNAP" .walks)" "an overlapping walk joins the active claim"
assert_equals '"2026-10-07T09:58:00Z"' "$(field "$SNAP" .started)" "the earlier start is kept"
assert_equals '"2026-10-07T10:30:00Z"' "$(field "$SNAP" .expires_at)" "the later expiry is kept"
assert_equals '["QW-40"]' "$(field "$MARKER" .walks)" "only the finished walk is removed; the overlapping claim survives"
assert_equals '"2026-10-07T10:30:00Z"' "$(field "$MARKER" .expires_at)" "the surviving claim keeps its expiry"
pass "overlapping walks release only their own claim"

active='{"walks":["QW-40","QW-41"],"started":"2026-10-07T09:58:00Z","expires_at":"2026-10-07T10:30:00Z","owner":"firstmate-main","claims":{"QW-40":"2222222222222222","QW-41":"1111111111111111"}}'
for owner in firstmate-main sol-operator; do
  marker "$active"
  walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner "$owner"
  expect_code 2 "$code" "a repeated active walk refuses for $owner"
  assert_no_grep '["chat"' "$LOG" "a repeated active walk never starts a second chat"
  assert_no_grep '["transport","release' "$LOG" "a refused duplicate never releases its predecessor"
  assert_equals "$active" "$(cat "$MARKER")" "a duplicate claim preserves the predecessor and its sibling"
done
pass "an active walk cannot be dispatched twice"

for seed in '' '{"walks":["QW-40"],"started":"2026-10-07T09:58:00Z","expires_at":"2026-10-07T10:30:00Z","owner":"firstmate-main","claims":{"QW-40":"2222222222222222"}}'; do
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
      [ "$op" != release ] || argument=1111111111111111
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
first_token=$(jq -r .token <<<"$first_claim")
second_claim=$(XDG_STATE_HOME="$STATE" FM_WALK_MARKER_NOW=2026-10-07T10:01:00Z \
  python3 "$ROOT/bin/fm-walk-marker.py" claim QW-42 firstmate-main 1200)
expect_code 0 "$?" "an overlapping claim extends the lease"
second_token=$(jq -r .token <<<"$second_claim")
assert_equals "$lease_start" "$(jq -r .started <<<"$second_claim")" "an extension preserves the lease identity"
marker_before=$(cat "$MARKER")
marker_result=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" release QW-41 firstmate-main)
expect_code 2 "$?" "a release without a lease identity refuses"
assert_equals "$marker_before" "$(cat "$MARKER")" "an unbound release leaves the lease untouched"
marker_result=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" release QW-41 firstmate-main "$first_token")
expect_code 0 "$?" "the first walk can release after a sibling extends the lease"
assert_equals '["QW-42"]' "$(field "$MARKER" .walks)" "the extension's walk survives the older walk's release"
assert_equals '"2026-10-07T10:21:00Z"' "$(field "$MARKER" .expires_at)" "the extended expiry survives"
marker_result=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" release QW-41 firstmate-main "$first_token")
expect_code 0 "$?" "a matching repeated release is idempotent"
assert_equals 'not-listed' "$(jq -r .result <<<"$marker_result")" "a repeated release reports the preserved lease"
reclaimed=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" claim QW-41 firstmate-main 300)
expect_code 0 "$?" "a finished walk can be reclaimed while its sibling survives"
new_token=$(jq -r .token <<<"$reclaimed")
assert_not_equals "$first_token" "$new_token" "redispatch has a fresh operation identity"
marker_before=$(cat "$MARKER")
marker_result=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" release QW-41 firstmate-main "$first_token")
expect_code 1 "$?" "replay of the old operation's terminal release refuses"
assert_equals "$marker_before" "$(cat "$MARKER")" "a stale token leaves both walks and tokens unchanged"
marker_result=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" release QW-42 firstmate-main "$second_token")
expect_code 0 "$?" "the sibling's matching release succeeds"
assert_equals '["QW-41"]' "$(field "$MARKER" .walks)" "the redispatched walk survives its sibling's report"
marker_result=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" release QW-41 firstmate-main "$new_token")
expect_code 0 "$?" "the redispatched walk's own token clears the marker"
assert_absent "$MARKER" "the final matching release removes the marker"
marker_result=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" release QW-42 firstmate-main "$second_token")
expect_code 0 "$?" "an absent matching claim stays idempotent"
assert_equals 'absent' "$(jq -r .result <<<"$marker_result")" "an absent release reports absence"
pass "per-operation tokens prevent replay during overlapping redispatch and permit expiry extensions"

manual='{"walks":["QW-40"],"started":"2026-10-07T09:58:00Z","expires_at":"2026-10-07T10:30:00Z","owner":"firstmate-main"}'
marker "$manual"
walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner firstmate-main
expect_code 2 "$code" "joining an active hand-written marker refuses"
assert_no_grep '["chat"' "$LOG" "a producer cannot invent ownership tokens for a manual walk"
assert_equals "$manual" "$(cat "$MARKER")" "the hand-written claim remains byte-identical"
for claims in '{}' '{"QW-40":"bad"}' '{"QW-41":"1111111111111111","QW-42":"2222222222222222"}' 'null'; do
  marker "$(jq -c --argjson claims "$claims" '.claims = $claims' <<<"$manual")"
  before=$(cat "$MARKER")
  for op in claim release; do
    arg=300
    [ "$op" != release ] || arg=1111111111111111
    marker_result=$(XDG_STATE_HOME="$STATE" python3 "$ROOT/bin/fm-walk-marker.py" "$op" QW-41 firstmate-main "$arg")
    expect_code 1 "$?" "a malformed token map refuses $op"
    assert_equals "$before" "$(cat "$MARKER")" "invalid token metadata cannot be mutated"
  done
done
pass "manual claims remain readable and malformed token maps refuse before mutation"

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
    assert_contains "$err" 'token mismatch' "a stale release names the changed operation"
    assert_equals "$(jq -Sc 'del(.result, .token)' "$TMP_ROOT/recovered.json")" "$(jq -Sc . "$MARKER")" \
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

claimed='{"result":"claimed","token":"1111111111111111","claims":{"QW-41":"1111111111111111"},"walks":["QW-41"],"owner":"firstmate-main","started":"2026-10-07T10:00:00Z","expires_at":"2026-10-07T10:05:00Z"}'
for bad in '' '{}' '[]' '{"result":"refused","reason":"held"}' \
  "$(jq -c '.result = "released"' <<<"$claimed")" \
  "$(jq -c '.token = "3333333333333333"' <<<"$claimed")" \
  "$(jq -c 'del(.claims)' <<<"$claimed")" \
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

released='{"result":"released","claims":{"QW-40":"2222222222222222"},"walks":["QW-40"],"owner":"firstmate-main","started":"2026-10-07T10:00:00Z","expires_at":"2026-10-07T10:05:00Z"}'
for bad in '' '{}' '{"result":"refused"}' "$claimed" \
  "$(jq -c '.walks = ["QW-41"]' <<<"$released")" \
  "$(jq -c '.owner = "sol-operator"' <<<"$released")" \
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

rm -f "$MARKER"
TRANSPORT_STALL=claim FM_WALK_MARKER_TEST_BOUND=1 walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner firstmate-main
expect_code 2 "$code" "a stalled claim transport refuses the walk"
assert_contains "$err" 'claim transport timeout after 1s' "claim failure identifies the hard bound"
assert_no_grep '["chat"' "$LOG" "a transport timeout never launches a walk"
TRANSPORT_STALL=release FM_WALK_MARKER_TEST_BOUND=1 walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner firstmate-main
expect_code 4 "$code" "a stalled release remains an actionable failure"
assert_contains "$err" 'release transport timeout after 1s' "release failure identifies the hard bound"
assert_present "$MARKER" "a timed-out release retains its durable claim"
pass "both transport operations have a shared hard deadline"

# --once-key: a key the bridge accepted is never sent again.
export FM_HOME="$TMP_ROOT/home"
chats() { grep -c '^\["chat"' "$LOG" || true; }
: > "$LOG"
run code out err "$BRIEF" --bot fm-researcher
assert_absent "$FM_HOME" "a dispatch without --once-key leaves no marker state"
: > "$LOG"
run code out err "$BRIEF" --bot fm-researcher --once-key 'QW-16@abc1234'
expect_code 0 "$code" "a new once-key sends"
assert_equals 1 "$(chats)" "a new once-key reaches the bridge once"
assert_contains "$out" 'grok-bot: unverified reply' "a new once-key returns the reply"
run code out err "$BRIEF" --bot fm-researcher --once-key 'QW-16@abc1234'
expect_code 0 "$code" "a repeated once-key exits 0"
assert_equals 1 "$(chats)" "a repeated once-key never reaches the bridge chat"
assert_contains "$out" 'grok-bot: once-key QW-16@abc1234 already sent' "the repeat says the key was already sent"
assert_not_contains "$out" 'unverified reply' "the repeat claims no new reply"
run code out err "$BRIEF" --bot fm-researcher --once-key 'QW-16@def5678'
expect_code 0 "$code" "a different once-key sends"
assert_equals 2 "$(chats)" "a different once-key reaches the bridge"
pass "a once-key sends once and a repeat converges without sending"

: > "$LOG"
STUB_RUNNING=1 run code out err "$BRIEF" --bot fm-researcher --once-key 'QW-15@abc1234'
expect_code 3 "$code" "a still-working first send exits 3"
run code out err "$BRIEF" --bot fm-researcher --once-key 'QW-15@abc1234'
expect_code 0 "$code" "a repeat after a still-working send exits 0"
assert_equals 1 "$(chats)" "a send the bridge accepted is not repeated after exit 3"
pass "a still-working send still records its once-key"

: > "$LOG"
STUB_CHAT_FAIL=1 run code out err "$BRIEF" --bot fm-researcher --once-key 'QW-14@abc1234'
expect_code 2 "$code" "a failed bridge chat exits 2"
assert_not_contains "$out" 'already sent' "a failed send claims nothing"
run code out err "$BRIEF" --bot fm-researcher --once-key 'QW-14@abc1234'
expect_code 0 "$code" "a retry after a failed send succeeds"
assert_equals 2 "$(chats)" "a retry after a failed send reaches the bridge again"
pass "a failed send records nothing, so a retry sends"

: > "$LOG"
# The first dispatch's chat is held at a release barrier until the second returns.
RELEASE="$TMP_ROOT/release-chat"
first=''
release_first() {
  : > "$RELEASE"
  [ -z "$first" ] || { kill "$first" 2>/dev/null; wait "$first" 2>/dev/null; }
}
trap 'release_first; fm_test_cleanup' EXIT
STUB_CHAT_HOLD="$RELEASE" "$TOOL" "$BRIEF" --bot fm-researcher --once-key 'QW-13@abc1234' > "$TMP_ROOT/first.out" 2>&1 &
first=$!
for _ in $(seq 300); do grep -q '^\["chat"' "$LOG" && break; sleep 0.1; done
assert_grep '["chat"' "$LOG" "the first dispatch reached its held chat"
run code out err "$BRIEF" --bot fm-researcher --once-key 'QW-13@abc1234'
: > "$RELEASE"
expect_code 2 "$code" "a concurrent dispatch of an in-flight once-key refuses"
assert_contains "$err" 'in flight or interrupted' "the concurrent refusal names the held key"
assert_not_contains "$out" 'already sent' "the concurrent refusal claims no success"
wait "$first"
expect_code 0 "$?" "the first of two concurrent dispatches sends"
first=''
assert_equals 1 "$(chats)" "concurrent dispatches of one once-key send once"
pass "a concurrent dispatch of one once-key sends once and claims no success"

run code out err "$BRIEF" --bot fm-researcher --once-key '../escape'
expect_code 2 "$code" "a once-key with a path separator refuses"
run code out err "$BRIEF" --bot fm-researcher --once-key ''
expect_code 2 "$code" "an empty once-key refuses"
pass "an unsafe once-key refuses before sending"

: > "$LOG"
rm -f "$MARKER"
TRANSPORT_FAIL=claim walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner firstmate-main --once-key 'QW-41@abc1234'
expect_code 2 "$code" "a refused walk claim refuses the once-key dispatch"
assert_no_grep '["chat"' "$LOG" "a refused walk claim sends nothing"
walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner firstmate-main --once-key 'QW-41@abc1234'
expect_code 0 "$code" "a retry after a refused walk claim sends"
assert_equals 1 "$(chats)" "the retry reaches the bridge once"
: > "$LOG"
walk_run code out err "$BRIEF" --bot fm-researcher --walk QW-41 --walk-owner firstmate-main --once-key 'QW-41@abc1234'
expect_code 0 "$code" "a repeated walk once-key exits 0"
assert_contains "$out" 'already sent' "a repeated walk once-key says it was already sent"
assert_no_grep '["transport"' "$LOG" "a repeated walk once-key claims no walk marker"
pass "a refused walk claim gives the once-key back and a sent walk is not claimed again"

echo "# all fm-grok-bot-dispatch tests passed"
