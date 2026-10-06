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
import { appendFileSync, existsSync } from "node:fs";
const [cmd, ...a] = process.argv.slice(2);
appendFileSync(process.env.STUB_LOG, JSON.stringify([cmd, ...a]) + "\n");
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

echo "# all fm-grok-bot-dispatch tests passed"
