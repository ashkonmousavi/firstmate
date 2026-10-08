#!/usr/bin/env bash
# bin/fm-main-proof.sh through its command interface against a fake gh: a
# commit is proved only when every named required check succeeded on that
# exact commit, judged by each check's latest run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROOF="$ROOT/bin/fm-main-proof.sh"
TMP_ROOT=$(fm_test_tmproot fm-main-proof)
SHA=1111111111111111111111111111111111111111
NEWER=2222222222222222222222222222222222222222

mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
[ ! -e "$FM_TEST_RUNS.fail" ] || { echo 'error: API unreachable' >&2; exit 1; }
case "$*" in
  *"repos/example/q/commits/$FM_TEST_SHA/check-runs"*)
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --jq ]; then
        jq -r "$2" "$FM_TEST_RUNS.json"
        exit $?
      fi
      shift
    done
    exit 1
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/gh"

# One check run per line: id name head_sha status conclusion producer, converted
# into the API's JSON response for the fake gh to project.
write_runs() {
  : > "$TMP_ROOT/runs"
  rm -f "$TMP_ROOT/runs.fail"
  local row
  for row in "$@"; do
    printf '%s\n' "$row" >> "$TMP_ROOT/runs"
  done
  jq -Rn '{check_runs: [inputs | split(" ") | {
    id: (.[0] | tonumber), name: .[1], head_sha: .[2], status: .[3],
    conclusion: .[4], app: (if .[5] == "-" then null else {slug: (.[5] // "github-actions")} end)
  }]}' < "$TMP_ROOT/runs" > "$TMP_ROOT/runs.json"
}

run_proof() {
  : > "$TMP_ROOT/gh.log"
  PATH="$TMP_ROOT/fakebin:$PATH" FM_TEST_GH_LOG="$TMP_ROOT/gh.log" \
    FM_TEST_RUNS="$TMP_ROOT/runs" FM_TEST_SHA="$SHA" \
    "$PROOF" example/q "$SHA" "unit" "e2e" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
}

expect_verdict() {  # <case> <code> <stdout-substring>
  local rc=0
  run_proof || rc=$?
  [ "$rc" -eq "$2" ] || fail "$1: expected exit $2, got $rc: $(cat "$TMP_ROOT/out" "$TMP_ROOT/err")"
  grep -qF -- "$3" "$TMP_ROOT/out" || fail "$1: expected '$3', got: $(cat "$TMP_ROOT/out")"
}

test_complete_proof_on_the_named_commit() {
  write_runs "1 unit $SHA completed success" "2 e2e $SHA completed success"
  expect_verdict complete 0 "proved $SHA: 2 required checks succeeded on this commit"
  write_runs "1 unit $SHA completed failure" "2 e2e $SHA completed success" "3 unit $SHA completed success"
  expect_verdict rerun-success 0 "proved $SHA"
  pass "a commit whose every required check latest run succeeded is proved"
}

test_incomplete_proof_never_passes() {
  write_runs "1 unit $SHA completed success" "2 e2e $SHA completed cancelled"
  expect_verdict cancelled 1 "unproven $SHA: e2e=cancelled"
  write_runs "1 unit $SHA completed success" "2 e2e $SHA completed skipped"
  expect_verdict skipped 1 "unproven $SHA: e2e=skipped"
  write_runs "1 unit $SHA completed success"
  expect_verdict missing 1 "unproven $SHA: e2e=missing"
  write_runs "1 unit $SHA completed success" "2 e2e $SHA in_progress -"
  expect_verdict pending 1 "unproven $SHA: e2e=in_progress"
  write_runs "1 unit $SHA completed success" "2 e2e $SHA completed success" "3 e2e $SHA completed cancelled"
  expect_verdict later-cancel 1 "unproven $SHA: e2e=cancelled"
  pass "cancelled, skipped, missing, pending and superseded-by-cancellation checks leave the commit unproven"
}

test_legs_from_another_commit_do_not_count() {
  write_runs "1 unit $SHA completed success" "2 e2e $NEWER completed success"
  expect_verdict wrong-head 1 "unproven $SHA: e2e=missing"
  pass "a required check that succeeded on a newer commit does not prove the named commit"
}

test_checks_remain_bound_to_their_producer() {
  write_runs "1 unit $SHA completed success" "2 e2e $SHA completed success other-app"
  expect_verdict wrong-producer-only 1 "unproven $SHA: e2e=missing"
  write_runs "1 unit $SHA completed success" "2 e2e $SHA completed cancelled" "3 e2e $SHA completed success other-app"
  expect_verdict wrong-producer-success 1 "unproven $SHA: e2e=cancelled"
  write_runs "1 unit $SHA completed success" "2 e2e $SHA in_progress -" "3 e2e $SHA completed success other-app"
  expect_verdict wrong-producer-pending 1 "unproven $SHA: e2e=in_progress"
  write_runs "1 unit $SHA completed success" "2 e2e $SHA completed success" "3 e2e $SHA completed cancelled other-app"
  expect_verdict unrelated-producer-cancel 0 "proved $SHA"
  write_runs "1 unit $SHA completed success" "2 e2e $SHA completed cancelled" "3 e2e $SHA completed success other-app" "4 e2e $SHA completed success"
  expect_verdict bound-producer-rerun 0 "proved $SHA"
  write_runs "1 unit $SHA completed success" "2 e2e $SHA completed success -"
  expect_verdict missing-producer 1 "unproven $SHA: e2e=missing"
  pass "only the latest GitHub Actions check can prove or invalidate each required workflow leg"
}

test_unreadable_checks_are_unknown() {
  write_runs
  : > "$TMP_ROOT/runs.fail"
  expect_verdict unreadable 2 "unknown $SHA: check runs could not be read"
  pass "an unreadable check-run list is unknown, never proved or failed"
}

test_invalid_requests_refuse() {
  local rc=0
  PATH="$TMP_ROOT/fakebin:$PATH" "$PROOF" example/q not-a-sha unit > /dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "invalid commit: expected exit 2, got $rc"
  rc=0
  PATH="$TMP_ROOT/fakebin:$PATH" "$PROOF" example/q "$SHA" > /dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "no required checks: expected exit 2, got $rc"
  pass "a malformed commit or an empty required-check list refuses"
}

test_complete_proof_on_the_named_commit
test_incomplete_proof_never_passes
test_legs_from_another_commit_do_not_count
test_checks_remain_bound_to_their_producer
test_unreadable_checks_are_unknown
test_invalid_requests_refuse
