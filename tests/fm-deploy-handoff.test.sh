#!/usr/bin/env bash
# tests/fm-deploy-handoff.test.sh - the deploy handoff a confirmed merge makes.
#
# bin/fm-merge-outcome-lib.sh hands every first-observed merge to
# bin/fm-deploy-trigger.sh after recording the outcome. Proves:
#   (a) the handoff is completely inert for a task whose project has no deploy
#       policy: same wake, nothing else
#   (b) a deploy that cannot even be assessed never turns a recorded merge into
#       an unrecorded one. bin/fm-pr-merge.sh reads a non-zero return here as
#       "the merge landed and the record did not", so the deploy's own trouble
#       must not borrow that meaning
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-deploy-handoff-tests)

# make_case <name>: echoes a case dir holding home/ (with one project) and state/.
make_case() {
  local case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/home/projects/demo" "$case_dir/state"
  printf '%s\n' "$case_dir"
}

call_merge_outcome_report() {  # <home> <state> <id> <url> <origin>
  (
    FM_ROOT_OVERRIDE="$ROOT"
    . "$ROOT/bin/fm-merge-outcome-lib.sh"
    fm_merge_outcome_report "$1" "$2" "$3" "$4" "$5"
  )
}

test_the_deploy_handoff_is_inert_without_a_policy() {
  local case_dir home state url rc=0 rows
  case_dir=$(make_case deploy-handoff-inert)
  home="$case_dir/home"
  state="$case_dir/state"
  url=https://github.com/example/repo/pull/93
  fm_write_meta "$state/task-x1.meta" "project=$home/projects/demo"

  call_merge_outcome_report "$home" "$state" task-x1 "$url" self || rc=$?
  [ "$rc" -eq 0 ] || fail "deploy-handoff-inert: fm_merge_outcome_report failed: rc=$rc"

  assert_absent "$state/deploy-ledger" \
    "deploy-handoff-inert: a project with no deploy policy reached the deploy path"
  rows=$(wc -l < "$state/.wake-queue" | tr -d ' ')
  [ "$rows" -eq 1 ] \
    || fail "deploy-handoff-inert: expected only the merge wake, got $rows rows: $(cat "$state/.wake-queue")"
  assert_grep "merge landed: task-x1 $url" "$state/.wake-queue" \
    "deploy-handoff-inert: the merge outcome itself changed"
  pass "the deploy handoff is inert for a project with no deploy policy"
}

test_a_deploy_that_cannot_be_assessed_still_records_the_merge() {
  local case_dir home state url rc=0
  case_dir=$(make_case deploy-handoff-failure)
  home="$case_dir/home"
  state="$case_dir/state"
  url=https://github.com/example/repo/pull/94
  mkdir -p "$home/config/deploy-policy"
  # A policy with no matching deploy target: the deploy path is reachable and
  # cannot complete, which is exactly the shape that must not be mistaken for a
  # failure to record the merge.
  printf 'dashboard/**\n' > "$home/config/deploy-policy/demo"
  fm_write_meta "$state/task-x1.meta" "project=$home/projects/demo"

  FM_DEPLOY_SYNC_TIMEOUT=5 FM_DEPLOY_STATUS_TIMEOUT=5 \
    call_merge_outcome_report "$home" "$state" task-x1 "$url" self || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "deploy-handoff-failure: a deploy that could not be assessed was reported as a failure to record the merge (rc=$rc)"
  assert_grep "merge landed: task-x1 $url" "$state/.wake-queue" \
    "deploy-handoff-failure: the merge outcome was lost"
  # Proves the case is not vacuous: the deploy path really was entered and
  # really did fail, rather than being skipped before it could.
  assert_grep "could not check whether demo" "$state/.wake-queue" \
    "deploy-handoff-failure: the deploy path was never reached, so this case proves nothing"
  pass "a deploy that cannot be assessed never turns a recorded merge into an unrecorded one"
}

test_the_deploy_handoff_is_inert_without_a_policy
test_a_deploy_that_cannot_be_assessed_still_records_the_merge
