#!/usr/bin/env bash
# bin/fm-gh-rate-check.sh: the shared GitHub allowance warning.
# A fake gh answers `api rate_limit` from a fixture and logs each call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

CHECK="$ROOT/bin/fm-gh-rate-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-rate-check)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_git_identity fmtest fmtest@example.invalid

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/log"
[ "$*" = "api rate_limit" ] || { printf 'unexpected gh: %s\n' "$*" >&2; exit 91; }
[ ! -e "$FAKE/down" ] || { printf 'gh: HTTP 502\n' >&2; exit 1; }
cat "$FAKE/rate.json"
SH
chmod +x "$FAKEBIN/gh"

NOW=1800000000
set_rate() {  # <fake> <core-remaining> <core-reset> <graphql-remaining> <graphql-reset>
  jq -n --argjson cr "$2" --argjson crs "$3" --argjson gr "$4" --argjson grs "$5" \
    '{resources:{core:{limit:5000,remaining:$cr,used:(5000-$cr),reset:$crs},
      graphql:{limit:5000,remaining:$gr,used:(5000-$gr),reset:$grs},
      search:{limit:30,remaining:30,reset:1}},rate:{limit:5000}}' > "$1/rate.json"
}

new_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/fake"
  : > "$home/fake/log"
  printf '%s\n' "$home"
}

run_check() {  # <home> <now> [args...]
  local home=$1 now=$2
  shift 2
  env PATH="$FAKEBIN:$PATH" FM_HOME="$home" FAKE="$home/fake" FM_GH_RATE_NOW="$now" "$CHECK" "${@:-check}" 2>"$home/err"
}

reads() { grep -c '^api rate_limit$' "$1/fake/log" || true; }

test_report_prints_both_resources() {
  local home out
  home=$(new_home report)
  set_rate "$home/fake" 4883 1800003600 4811 1800000600
  out=$(run_check "$home" "$NOW" report) || fail "report failed"
  assert_contains "$out" 'github-core: remaining=4883 limit=5000 percent=97 reset=' "report names core"
  assert_contains "$out" 'github-graphql: remaining=4811 limit=5000 percent=96 reset=' "report names GraphQL"
  [ ! -e "$home/state/.gh-rate-check" ] || fail "report must not consume the check's interval"
  touch "$home/fake/down"
  out=$(run_check "$home" "$NOW" report) && fail "report should fail when gh does"
  assert_contains "$out" 'github-rate: unavailable' "report says why it is unavailable"
  pass "report prints core and GraphQL remaining, never touches the record, and fails visibly"
}

test_one_wake_per_episode() {
  local home out
  home=$(new_home episode)
  set_rate "$home/fake" 4000 1800003600 4000 1800003600
  out=$(run_check "$home" "$NOW") || fail "healthy check failed"
  assert_equals '' "$out" "a healthy allowance is silent"
  set_rate "$home/fake" 1200 1800003600 4000 1800003600
  out=$(run_check "$home" $((NOW + 400))) || fail "low check failed"
  assert_contains "$out" 'GitHub core allowance low: 1200 of 5000 left (24%)' "core under 25 percent wakes"
  assert_not_contains "$out" graphql "GraphQL is a separate episode and is healthy"
  set_rate "$home/fake" 300 1800003600 4000 1800003600
  out=$(run_check "$home" $((NOW + 800))) || fail "second low check failed"
  assert_equals '' "$out" "a lower reading in the same window does not wake again"
  set_rate "$home/fake" 1249 1800003600 1000 1800003600
  out=$(run_check "$home" $((NOW + 1200))) || fail "graphql low check failed"
  assert_contains "$out" 'GitHub graphql allowance low: 1000 of 5000 left (20%)' "GraphQL has its own episode"
  assert_not_contains "$out" 'core allowance' "core stays silent inside its window"
  set_rate "$home/fake" 4990 1800007200 4990 1800007200
  out=$(run_check "$home" $((NOW + 1600))) || fail "recovery check failed"
  assert_equals '' "$out" "recovery in a main home is silent"
  set_rate "$home/fake" 100 1800010800 4990 1800007200
  out=$(run_check "$home" $((NOW + 2000))) || fail "new window check failed"
  assert_contains "$out" 'GitHub core allowance low: 100 of 5000 left (2%)' "the next window's shortage wakes again"
  pass "wakes once per resource per window, separately for core and GraphQL, and again after a refill"
}

test_interval_and_failures() {
  local home out
  home=$(new_home interval)
  set_rate "$home/fake" 4000 1800003600 4000 1800003600
  run_check "$home" "$NOW" >/dev/null || fail "first check failed"
  run_check "$home" $((NOW + 100)) >/dev/null || fail "second check failed"
  assert_equals 1 "$(reads "$home")" "a check inside the interval makes no request"
  run_check "$home" $((NOW + 300)) >/dev/null || fail "third check failed"
  assert_equals 2 "$(reads "$home")" "a check after the interval reads again"
  touch "$home/fake/down"
  out=$(run_check "$home" $((NOW + 900))) || fail "a failed read must not fail the check"
  assert_equals '' "$out" "a failed read is silent"
  printf 'not json\n' > "$home/fake/rate.json"
  rm -f "$home/fake/down"
  out=$(run_check "$home" $((NOW + 1200))) || fail "a bad body must not fail the check"
  assert_equals '' "$out" "an unexpected body is silent"
  pass "the interval gates requests, and a failed or malformed read is silent and retried"
}

test_secondmate_publishes_on_the_parent_channel() {
  local parent mate out status
  parent=$TMP_ROOT/parent
  mate=$(new_home mate)
  mkdir -p "$parent/state"
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$mate/.fm-secondmate-parent"
  printf 'kind=secondmate\nhome=%s\n' "$mate" > "$parent/state/mate.meta"
  status=$parent/state/mate.status
  set_rate "$mate/fake" 900 1800003600 4000 1800003600
  out=$(run_check "$mate" "$NOW") || fail "secondmate check failed"
  assert_equals '' "$out" "a secondmate prints nothing; its idle model is not woken"
  grep -Eq '^blocked \[key=gh-rate-core-1800003600\] \[at=[0-9]+\]: GitHub core allowance low: 900 of 5000' "$status" \
    || fail "the parent channel did not get the keyed line: $(cat "$status" 2>/dev/null)"
  out=$(run_check "$mate" $((NOW + 400)))
  [ "$(grep -c '^blocked' "$status")" -eq 1 ] || fail "the episode was published twice"
  set_rate "$mate/fake" 4900 1800007200 4000 1800003600
  run_check "$mate" $((NOW + 800)) >/dev/null || fail "recovery check failed"
  grep -Eq '^resolved \[key=gh-rate-core-1800003600\] \[at=[0-9]+\]: GitHub core allowance recovered' "$status" \
    || fail "the episode was not closed with the same key: $(cat "$status")"
  pass "a secondmate publishes the episode on its parent channel with a key and closes it on recovery"
}

test_arm_and_disarm() {
  local home
  home=$(new_home arm)
  env PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$CHECK" arm >/dev/null 2>"$home/err" || fail "arm failed: $(cat "$home/err")"
  [ -x "$home/state/gh-rate.check.sh" ] || fail "no executable shim"
  [ -f "$home/state/gh-rate.check-trust" ] || fail "the shim was not registered"
  grep -q "fm-gh-rate-check.sh') check\|fm-gh-rate-check.sh check" "$home/state/gh-rate.check.sh" || fail "the shim does not run check"
  set_rate "$home/fake" 100 1800003600 4000 1800003600
  out=$(env PATH="$FAKEBIN:$PATH" FAKE="$home/fake" bash "$home/state/gh-rate.check.sh") || fail "the shim failed"
  assert_contains "$out" 'GitHub core allowance low' "the armed shim reports a shortage"
  env PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$CHECK" disarm >/dev/null || fail "disarm failed"
  [ ! -e "$home/state/gh-rate.check.sh" ] && [ ! -e "$home/state/gh-rate.check-trust" ] || fail "disarm left the shim behind"
  pass "arm writes and registers the shim, the shim runs the check, disarm removes it"
}

failures=0
for test_name in test_report_prints_both_resources test_one_wake_per_episode test_interval_and_failures \
  test_secondmate_publishes_on_the_parent_channel test_arm_and_disarm; do
  ( "$test_name" ) || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || fail "$failures gh-rate-check regressions"
