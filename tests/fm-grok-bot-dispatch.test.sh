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
const [cmd, ...a] = process.argv.slice(2);
appendFileSync(process.env.STUB_LOG, JSON.stringify([cmd, ...a]) + "\n");
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

echo "# all fm-grok-bot-dispatch tests passed"
