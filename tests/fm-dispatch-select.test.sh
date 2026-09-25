#!/usr/bin/env bash
# Public resolver contract: ordered routing, concrete skips, strict inputs, and
# explicit quota-balanced handoff. No live config or vendor tools are used.
set -eu
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-dispatch-select)
RESOLVER="$ROOT/bin/fm-dispatch-select.sh"
CONFIG="$LAB/config.json"
FACTS="$LAB/facts.json"

cat > "$CONFIG" <<'JSON'
{
  "rules": [
    {"when":"difficult judgment","use":[{"harness":"codex","model":"gpt-6-astra","effort":"xhigh"},{"harness":"claude","model":"claude-opus-5-5","effort":"xhigh"}]},
    {"when":"planning","select":"ordered","use":[{"harness":"grok","model":"grok-4.7","effort":"high"},{"harness":"claude","model":"claude-opus-5-5","effort":"high"}]},
    {"when":"independent review","use":[{"harness":"codex","model":"gpt-6-astra","effort":"high"},{"harness":"claude","model":"claude-fable-5-1","effort":"high"}]},
    {"when":"new feature","use":[{"harness":"claude","model":"claude-opus-5-5","effort":"high"},{"harness":"codex","model":"gpt-6-astra","effort":"xhigh"}]},
    {"when":"large implementation","use":[{"harness":"grok","model":"grok-4.7","effort":"high"},{"harness":"codex","model":"gpt-6-astra","effort":"xhigh"}]},
    {"when":"simple fix","use":[{"harness":"grok","model":"grok-4.6","effort":"medium"},{"harness":"codex","model":"gpt-5.6-luna","effort":"high"}]},
    {"when":"images","use":[{"harness":"codex","model":"gpt-5.6-sol","effort":"medium"},{"harness":"cursor","model":"gpt-5.6-sol-high"}]}
  ],
  "default":[{"harness":"claude","model":"claude-opus-5-5","effort":"high"},{"harness":"grok","model":"grok-4.7","effort":"high"}]
}
JSON

# Expected order is explicit, independently of the fixture's profile fields.
while read -r selector first second; do
  out=$("$RESOLVER" "$CONFIG" "$selector") || fail "$selector did not resolve: $out"
  assert_contains "$out" "selected[0]: {\"harness\":\"$first\"" "$selector first candidate"
  [ "$out" = "$("$RESOLVER" "$CONFIG" "$selector")" ] || fail "non-deterministic result"
  jq --arg s "$selector" 'if $s == "default" then .default[0].off = true else .rules[$s|tonumber].use[0].off = true end' "$CONFIG" > "$LAB/off.json"
  out=$("$RESOLVER" "$LAB/off.json" "$selector") || fail "$selector off fallback"
  assert_contains "$out" 'skipped[0]: off=true' "$selector off reason"
  assert_contains "$out" "selected[1]: {\"harness\":\"$second\"" "$selector second candidate"
  printf '%s\n' '[{"candidate":0,"kind":"launch_failed","detail":"launch refused"}]' > "$FACTS"
  out=$("$RESOLVER" "$CONFIG" "$selector" --facts "$FACTS") || fail "$selector launch fallback"
  assert_contains "$out" 'skipped[0]: launch_failed: launch refused' "$selector launch reason"
  assert_contains "$out" "selected[1]: {\"harness\":\"$second\"" "$selector fact fallback"
  printf '%s\n' '[{"candidate":0,"kind":"blocked","detail":"known block"},{"candidate":1,"kind":"launch_failed","detail":"launch refused"}]' > "$FACTS"
  if out=$("$RESOLVER" "$CONFIG" "$selector" --facts "$FACTS" 2>&1); then fail "$selector selected from unavailable candidates"; fi
  assert_contains "$out" 'skipped[0]: blocked: known block' "$selector first skip"
  assert_contains "$out" 'skipped[1]: launch_failed: launch refused' "$selector second skip"
  assert_contains "$out" 'all candidates unavailable' "$selector terminal failure"
  assert_not_contains "$out" 'selected[' "$selector must not fall through"
done <<'ROWS'
0 codex claude
1 grok claude
2 codex claude
3 claude codex
4 grok codex
5 grok codex
6 codex cursor
default claude grok
ROWS
pass 'each rule and default preserve order, explain skips, and stop when exhausted'

while read -r runway confidence chosen; do
  jq -n --arg r "$runway" --arg c "$confidence" '[{candidate:0,kind:"quota",provider:"codex",runway:$r,confidence:$c,effectivePercentRemaining:0,spendPriority:-100}]' > "$FACTS"
  out=$("$RESOLVER" "$CONFIG" 0 --facts "$FACTS") || fail 'quota fact resolution'
  assert_contains "$out" "selected[$chosen]:" 'only established exhaustion skips'
  if [ "$chosen" = 1 ]; then
    assert_contains "$out" 'skipped[0]: quota: codex exhausted_now (established)' 'exhaustion reason'
  else
    assert_not_contains "$out" 'skipped[' 'weak quota must not skip'
  fi
done <<'ROWS'
exhausted_now established 1
exhausted_now early 0
projected_exhaustion established 0
through_reset established 0
unknown unknown 0
ROWS
pass 'headroom, spendPriority, projection, and early confidence do not reorder'

jq '.rules[0].select = "quota-balanced"' "$CONFIG" > "$LAB/quota.json"
out=$("$RESOLVER" "$LAB/quota.json" 0) || fail 'quota handoff'
assert_contains "$out" 'selection: quota-balanced; use quota-array-dispatch' 'quota handoff'
assert_not_contains "$out" 'selected[' 'quota must not resolve by order'
out=$("$RESOLVER" "$LAB/quota.json" default)
assert_contains "$out" 'selected[0]: {"harness":"claude"' 'default resolves in list order'
pass 'explicit quota-balanced rule is a handoff; default stays ordered'

printf '%s\n' '{"default":{"harness":"codex","off":false}}' > "$LAB/single.json"
out=$("$RESOLVER" "$LAB/single.json" default)
assert_contains "$out" 'selected[0]: {"harness":"codex","off":false}' 'single profile'
printf '%s\n' '{"default":{"harness":"codex","off":true}}' > "$LAB/off.json"
if out=$("$RESOLVER" "$LAB/off.json" default 2>&1); then fail 'off singleton selected'; fi
assert_contains "$out" 'all candidates unavailable' 'off singleton failure'
pass 'single profiles obey availability'

printf '%s\n' '{"rules":[{"when":"web research","use":[{"grok_bot":"fm-researcher"},{"harness":"claude"}]}]}' > "$LAB/bot.json"
out=$("$RESOLVER" "$LAB/bot.json" 0) || fail 'grok bot target'
assert_contains "$out" 'selected[0]: {"grok_bot":"fm-researcher"}' 'grok bot target is selectable'
printf '%s\n' '[{"candidate":0,"kind":"blocked","detail":"Grok Bot weekly usage spent"}]' > "$LAB/bot-facts.json"
out=$("$RESOLVER" "$LAB/bot.json" 0 --facts "$LAB/bot-facts.json") || fail 'grok bot fallback'
assert_contains "$out" 'skipped[0]: blocked: Grok Bot weekly usage spent' 'grok bot block reason'
assert_contains "$out" 'selected[1]: {"harness":"claude"}' 'grok bot falls back in order'
pass 'grok bot targets select in order and obey facts'

while IFS='^' read -r body reason; do
  printf '%s\n' "$body" > "$LAB/invalid.json"
  if out=$("$RESOLVER" "$LAB/invalid.json" default 2>&1); then fail "accepted $body"; fi
  assert_contains "$out" "$reason" 'schema refusal'
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "multi-line refusal: $out"
done <<'ROWS'
{^malformed JSON
{} {}^exactly one JSON object
^exactly one JSON object
[]^top-level value must be an object
{"rules":null}^rules must be an array
{"default":{"harness":"codex","off":"yes"}}^off must be a boolean
{"default":{"harness":"codex","off":null}}^off must be a boolean
{"default":{"harness":"spaceship"}}^unverified harness
{"default":{"grok_bot":"fm-researcher","harness":"claude"}}^grok_bot default profile needs a non-empty Bot name
{"rules":[{"when":"work","use":{"grok_bot":""}}]}^grok_bot use profile needs a non-empty Bot name
{"default":{"harness":"codex","effort":"max"}}^invalid effort
{"rules":[{"when":"work","select":false,"use":{"harness":"codex"}}],"default":{"harness":"claude"}}^select must be a non-empty string
{"rules":[{"when":"work","select":"fastest","use":{"harness":"codex"}}],"default":{"harness":"claude"}}^unknown select
ROWS
for selector in 99 -1 1.5 00 planning; do
  if out=$("$RESOLVER" "$CONFIG" "$selector" 2>&1); then fail "accepted selector $selector"; fi
  assert_contains "$out" 'selector' 'invalid selector reason'
done
if out=$("$RESOLVER" "$LAB/single.json" 0 2>&1); then fail 'accepted missing rule'; fi
assert_contains "$out" 'selector' 'missing rule reason'
printf '%s\n' '{}' > "$LAB/empty.json"
if out=$("$RESOLVER" "$LAB/empty.json" default 2>&1); then fail 'accepted missing default'; fi
assert_contains "$out" 'selector' 'missing default reason'
pass 'schema and selector refusals are actionable'

for body in '{' '{}' '[{"candidate":99,"kind":"blocked","detail":"x"}]' '[{"candidate":0,"kind":"headroom","detail":"low"}]' '[{"candidate":0,"kind":"blocked"}]' '[{"candidate":0,"kind":"quota","provider":"codex","runway":"typo","confidence":"established"}]'; do
  printf '%s\n' "$body" > "$FACTS"
  if out=$("$RESOLVER" "$CONFIG" 0 --facts "$FACTS" 2>&1); then fail "accepted facts $body"; fi
  assert_contains "$out" 'facts' 'invalid facts reason'
done
pass 'invalid availability facts fail closed'
