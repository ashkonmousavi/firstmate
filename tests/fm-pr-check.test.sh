#!/usr/bin/env bash
# Regression tests for bin/fm-pr-check.sh's branch-identity check: a PR whose
# head branch is not this task's own branch (2026-09-05 shell/174 incident,
# see the script's own header) must be refused unless --prerequisite is
# passed, and a prerequisite PR must record under prerequisite_pr=, never
# pr=. It also owns the supported --absorbed-by binding's containment and
# metadata behavior. tests/fm-pr-check-security.test.sh owns the broader
# canonical-PR parsing, poll, and private-artifact regression surface.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

# A fake gh answering headRefName (this test file's own concern) and
# headRefOid (so the unrelated pr_head lookup does not fail the case), each
# overridable per invocation via FM_TEST_GH_BRANCH / FM_TEST_GH_HEAD.
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/wt" "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *headRefName*) printf '%s\n' "${FM_TEST_GH_BRANCH:-fm/task-a}" ; exit 0 ;;
      *headRefOid*) printf '%s\n' "${FM_TEST_GH_HEAD:-}" ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
  git -C "$dir/wt" init -q
  git -C "$dir/wt" checkout -q -b fm/task-a
  git -C "$dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m baseline
  git init -q --bare "$dir/origin.git"
  git -C "$dir/wt" remote add origin "$dir/origin.git"
  printf '%s\n' "$dir"
}

publish_pr_head_ref() {
  local dir=$1 number=$2 head=$3
  git -C "$dir/wt" push -q origin "$head:refs/pull/$number/head"
}

assert_no_leaked_absorbed_pr_head_ref() {
  local dir=$1 label=$2 leaked
  leaked=$(git -C "$dir/wt" for-each-ref --format='%(refname)' 'refs/fm-pr-check/**' 2>/dev/null)
  [ -z "$leaked" ] || fail "$label: fm-pr-check leaked a private pull-request head ref: $leaked"
}

write_task_meta() {
  local dir=$1 id=${2:-task-a}
  fm_write_meta "$dir/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
}

run_pr_check() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/state" \
  PATH="$dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

install_absorbed_gh() {
  local dir=$1 original_head=$2 combined_head=$3 original_state=${4:-CLOSED}
  local combined_state=${5:-MERGED} merge_commit=${6:-}
  cat > "$dir/fakebin/gh" <<SH
#!/usr/bin/env bash
url=\${3:-}
case "\$url| \$* " in
  "https://github.com/example/repo/pull/5|"*" --json state "*) printf '%s\n' '$original_state' ;;
  "https://github.com/example/repo/pull/5|"*" --json headRefName "*) printf '%s\n' 'fm/task-a' ;;
  "https://github.com/example/repo/pull/5|"*" --json headRefOid "*) printf '%s\n' '$original_head' ;;
  "https://github.com/example/repo/pull/9|"*"state,headRefOid,mergeCommit,url"*)
    printf '%s\t%s\t%s\t%s\n' '$combined_state' '$combined_head' '$merge_commit' 'https://github.com/example/repo/pull/9'
    ;;
  "https://github.com/example/repo/pull/9|"*" --json headRefName "*) printf '%s\n' 'fm/integration-batch' ;;
  "https://github.com/example/repo/pull/9|"*" --json headRefOid "*) printf '%s\n' '$combined_head' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
}

land_squash_on_main() {
  local dir=$1 source_head=$2 tree squash
  tree=$(git -C "$dir/wt" rev-parse "$source_head^{tree}") || return 1
  squash=$(printf '%s\n' 'squash landing' | git -C "$dir/wt" commit-tree "$tree") || return 1
  git -C "$dir/wt" push -q origin "$squash:refs/heads/main" || return 1
  printf '%s\n' "$squash"
}

test_mismatched_branch_refused() {
  local dir rc
  dir=$(make_case mismatch)
  write_task_meta "$dir" task-a

  set +e
  FM_TEST_GH_BRANCH=fm/other-task \
    run_pr_check "$dir" task-a https://github.com/example/repo/pull/5 \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mismatch: fm-pr-check should refuse a PR built on another task's branch"
  assert_grep 'fm/other-task' "$dir/stderr" \
    "mismatch: refusal did not name the PR's observed head branch"
  assert_grep 'fm/task-a' "$dir/stderr" \
    "mismatch: refusal did not name the task's expected branch"
  assert_grep '--prerequisite' "$dir/stderr" \
    "mismatch: refusal did not mention the --prerequisite escape hatch"
  assert_no_grep 'pr=https://github.com/example/repo/pull/5' "$dir/state/task-a.meta" \
    "mismatch: a mismatched PR was recorded as this task's own delivery"
  pass "fm-pr-check refuses a PR whose head branch is not this task's own"
}

test_retry_suffix_accepted() {
  local dir rc suffix
  for suffix in -fix1 -r2; do
    dir=$(make_case "suffix$suffix")
    write_task_meta "$dir" task-a

    set +e
    FM_TEST_GH_BRANCH="fm/task-a$suffix" \
      run_pr_check "$dir" task-a https://github.com/example/repo/pull/6 \
      > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e

    expect_code 0 "$rc" "suffix$suffix: fm-pr-check should accept a retry-suffixed branch"
    assert_grep 'pr=https://github.com/example/repo/pull/6' "$dir/state/task-a.meta" \
      "suffix$suffix: pr= was not recorded for a matching retry branch"
  done
  pass "fm-pr-check accepts an fm/<task-id> branch carrying a -fixN or -rN retry suffix"
}

test_prerequisite_recorded_separately() {
  local dir rc
  dir=$(make_case prerequisite)
  write_task_meta "$dir" task-a

  set +e
  FM_TEST_GH_BRANCH=fm/other-task \
    run_pr_check "$dir" --prerequisite task-a https://github.com/example/repo/pull/8 \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "prerequisite: --prerequisite should record a PR built for other work"
  assert_grep 'prerequisite_pr=https://github.com/example/repo/pull/8' "$dir/state/task-a.meta" \
    "prerequisite: prerequisite_pr= was not recorded"
  # A plain substring check for "pr=<url>" would also match inside
  # "prerequisite_pr=<url>" (it literally ends in "..._pr="), so the real
  # invariant - no exact pr= line - needs the anchored regex below instead.
  ! grep -qE '^pr=' "$dir/state/task-a.meta" \
    || fail "prerequisite: the prerequisite PR was recorded as pr= instead of prerequisite_pr="
  pass "fm-pr-check records a --prerequisite PR under prerequisite_pr=, never pr="
}

test_absorbed_constituent_binding_accepts_an_original_head_behind_the_exact_absorbed_head() {
  local dir rc original_head absorbed_head combined_head tree count
  dir=$(make_case absorbed)
  write_task_meta "$dir" task-a
  original_head=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'fix ci after original PR closed'
  absorbed_head=$(git -C "$dir/wt" rev-parse HEAD)
  tree=$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')
  combined_head=$(printf '%s\n' combined | git -C "$dir/wt" commit-tree "$tree" -p "$absorbed_head")
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/5' \
    "pr_head=$original_head" >> "$dir/state/task-a.meta"
  publish_pr_head_ref "$dir" 5 "$original_head"
  publish_pr_head_ref "$dir" 9 "$combined_head"
  install_absorbed_gh "$dir" "$original_head" "$combined_head"

  set +e
  run_pr_check "$dir" --absorbed-by task-a https://github.com/example/repo/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "absorbed: an original PR head behind the exact absorbed head should bind"
  assert_grep 'batch_role=constituent' "$dir/state/task-a.meta" \
    "absorbed: constituent role was not recorded"
  assert_grep 'batch_constituent_branch=fm/task-a' "$dir/state/task-a.meta" \
    "absorbed: original branch was not preserved"
  assert_grep "batch_constituent_head=$original_head" "$dir/state/task-a.meta" \
    "absorbed: original PR head was not preserved"
  assert_grep "absorbed_head=$absorbed_head" "$dir/state/task-a.meta" \
    "absorbed: exact absorbed head was not preserved"
  assert_grep 'batch_superseded_pr=https://github.com/example/repo/pull/5' "$dir/state/task-a.meta" \
    "absorbed: original PR URL was not preserved"
  assert_grep 'batch_superseded_disposition=closed-as-superseded-not-merged' "$dir/state/task-a.meta" \
    "absorbed: original PR was not recorded as superseded and not merged"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$dir/state/task-a.meta" \
    "absorbed: combined PR did not become the task's watched landing"
  assert_grep "pr_head=$combined_head" "$dir/state/task-a.meta" \
    "absorbed: combined PR head was not recorded"
  assert_present "$dir/state/task-a.check.sh" \
    "absorbed: combined PR merge poll was not armed for the constituent task"
  # The point of the binding is which PR this task's poll now watches, so pin
  # the armed sidecar and its registration to the combined PR rather than only
  # to the poll's existence: both would survive a poll still aimed at pull/5.
  assert_grep 'https://github.com/example/repo/pull/9' "$dir/state/task-a.pr-poll" \
    "absorbed: the armed poll sidecar does not watch the combined PR"
  assert_grep 'https://github.com/example/repo/pull/9' "$dir/state/task-a.pr-poll-registration" \
    "absorbed: the poll registration does not bind the combined PR"
  assert_no_grep 'pull/5' "$dir/state/task-a.pr-poll" \
    "absorbed: the armed poll sidecar still watches the superseded PR"
  assert_no_grep 'pull/5' "$dir/state/task-a.pr-poll-registration" \
    "absorbed: the poll registration still binds the superseded PR"

  set +e
  run_pr_check "$dir" --absorbed-by task-a https://github.com/example/repo/pull/9 \
    > "$dir/retry-stdout" 2> "$dir/retry-stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "absorbed: repeating the exact binding should recover idempotently"
  count=$(grep -c '^batch_constituent_head=' "$dir/state/task-a.meta")
  [ "$count" -eq 1 ] || fail "absorbed: retry duplicated the constituent binding fields"
  count=$(grep -c '^absorbed_head=' "$dir/state/task-a.meta")
  [ "$count" -eq 1 ] || fail "absorbed: retry duplicated the exact absorbed head"

  set +e
  run_pr_check "$dir" task-a https://github.com/example/repo/pull/10 \
    > "$dir/overwrite-stdout" 2> "$dir/overwrite-stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "absorbed: ordinary registration must not erase constituent evidence"
  assert_grep 'batch_superseded_pr=https://github.com/example/repo/pull/5' "$dir/state/task-a.meta" \
    "absorbed: refused ordinary registration erased the superseded PR evidence"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$dir/state/task-a.meta" \
    "absorbed: refused ordinary registration replaced the combined landing"
  assert_no_leaked_absorbed_pr_head_ref "$dir" absorbed
  pass "fm-pr-check binds a closed original PR head behind the exact absorbed head without recording it as merged"
}

test_absorbed_constituent_binding_refuses_when_the_combined_head_lacks_the_exact_absorbed_head() {
  local dir rc original_head absorbed_head unrelated_head tree
  dir=$(make_case absorbed-missing-head)
  write_task_meta "$dir" task-a
  original_head=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'advance after original PR closed'
  absorbed_head=$(git -C "$dir/wt" rev-parse HEAD)
  tree=$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')
  unrelated_head=$(printf '%s\n' unrelated | git -C "$dir/wt" commit-tree "$tree" -p "$original_head")
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/5' \
    "pr_head=$original_head" >> "$dir/state/task-a.meta"
  publish_pr_head_ref "$dir" 5 "$original_head"
  publish_pr_head_ref "$dir" 9 "$unrelated_head"
  install_absorbed_gh "$dir" "$original_head" "$unrelated_head"

  set +e
  run_pr_check "$dir" --absorbed-by task-a https://github.com/example/repo/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "absorbed-missing-head: a combined head lacking the exact absorbed head must refuse"
  assert_grep "does not contain task task-a's exact current head" "$dir/stderr" \
    "absorbed-missing-head: refusal did not name the missing exact absorbed head"
  assert_grep 'pr=https://github.com/example/repo/pull/5' "$dir/state/task-a.meta" \
    "absorbed-missing-head: refusal replaced the original PR record"
  assert_no_grep 'batch_role=' "$dir/state/task-a.meta" \
    "absorbed-missing-head: refusal wrote a partial batch binding"
  assert_absent "$dir/state/task-a.check.sh" \
    "absorbed-missing-head: refusal armed a combined PR poll"
  assert_no_leaked_absorbed_pr_head_ref "$dir" absorbed-missing-head
  pass "fm-pr-check refuses an absorbed binding when the combined PR head lacks the exact absorbed head"
}

test_absorbed_constituent_binding_refuses_when_original_pr_head_is_not_an_ancestor() {
  local dir rc current_head original_head combined_head tree
  dir=$(make_case absorbed-original-not-ancestor)
  write_task_meta "$dir" task-a
  current_head=$(git -C "$dir/wt" rev-parse HEAD)
  tree=$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')
  original_head=$(printf '%s\n' unrelated | git -C "$dir/wt" commit-tree "$tree")
  combined_head=$(printf '%s\n' combined | git -C "$dir/wt" commit-tree "$tree" -p "$current_head")
  printf '%s\n' 'pr=https://github.com/example/repo/pull/5' "pr_head=$original_head" >> "$dir/state/task-a.meta"
  publish_pr_head_ref "$dir" 5 "$original_head"
  publish_pr_head_ref "$dir" 9 "$combined_head"
  install_absorbed_gh "$dir" "$original_head" "$combined_head"

  set +e
  run_pr_check "$dir" --absorbed-by task-a https://github.com/example/repo/pull/9 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "absorbed-original-not-ancestor: an unrelated original PR head must refuse"
  assert_grep 'is not an ancestor of task task-a' "$dir/stderr" "absorbed-original-not-ancestor: refusal did not name the failed ancestry fact"
  assert_no_grep 'batch_role=' "$dir/state/task-a.meta" "absorbed-original-not-ancestor: refusal wrote a partial binding"
  assert_no_leaked_absorbed_pr_head_ref "$dir" absorbed-original-not-ancestor
  pass "fm-pr-check refuses an absorbed binding when the original PR head is not an ancestor of current work"
}

test_absorbed_constituent_binding_refuses_a_merged_original_pr() {
  local dir rc current_head combined_head tree
  dir=$(make_case absorbed-original-merged)
  write_task_meta "$dir" task-a
  current_head=$(git -C "$dir/wt" rev-parse HEAD)
  tree=$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')
  combined_head=$(printf '%s\n' combined | git -C "$dir/wt" commit-tree "$tree" -p "$current_head")
  printf '%s\n' 'pr=https://github.com/example/repo/pull/5' "pr_head=$current_head" >> "$dir/state/task-a.meta"
  publish_pr_head_ref "$dir" 5 "$current_head"
  publish_pr_head_ref "$dir" 9 "$combined_head"
  install_absorbed_gh "$dir" "$current_head" "$combined_head" MERGED

  set +e
  run_pr_check "$dir" --absorbed-by task-a https://github.com/example/repo/pull/9 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "absorbed-original-merged: a merged original PR must refuse"
  assert_grep 'is merged, not superseded' "$dir/stderr" "absorbed-original-merged: refusal did not name the closed-unmerged requirement"
  assert_no_grep 'batch_role=' "$dir/state/task-a.meta" "absorbed-original-merged: refusal wrote a partial binding"
  pass "fm-pr-check refuses an absorbed binding when the original PR was merged rather than closed"
}

test_prless_absorbed_constituent_binding_accepts_only_the_exact_head_in_a_merged_combined_pr() {
  local dir rc absorbed_head combined_head squash_head tree
  dir=$(make_case absorbed-prless)
  write_task_meta "$dir" task-a
  git -C "$dir/wt" branch -m fm/task-a-cancel
  absorbed_head=$(git -C "$dir/wt" rev-parse HEAD)
  tree=$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')
  combined_head=$(printf '%s\n' combined | git -C "$dir/wt" commit-tree "$tree" -p "$absorbed_head")
  publish_pr_head_ref "$dir" 9 "$combined_head"
  squash_head=$(land_squash_on_main "$dir" "$combined_head")
  install_absorbed_gh "$dir" '' "$combined_head" CLOSED MERGED "$squash_head"

  set +e
  run_pr_check "$dir" --absorbed-by task-a https://github.com/example/repo/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "absorbed-prless: an exact task head in a squash-landed combined PR should bind: $(cat "$dir/stderr")"
  assert_grep 'batch_role=constituent' "$dir/state/task-a.meta" \
    "absorbed-prless: constituent role was not recorded"
  assert_grep 'batch_constituent_branch=fm/task-a-cancel' "$dir/state/task-a.meta" \
    "absorbed-prless: exact constituent branch was not recorded"
  assert_grep 'absorbed_by=https://github.com/example/repo/pull/9' "$dir/state/task-a.meta" \
    "absorbed-prless: combined PR identity was not recorded explicitly"
  assert_grep "absorbed_head=$absorbed_head" "$dir/state/task-a.meta" \
    "absorbed-prless: exact task head was not recorded"
  assert_grep 'absorbed_original_pr=none' "$dir/state/task-a.meta" \
    "absorbed-prless: explicit no-original-PR marker was not recorded"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$dir/state/task-a.meta" \
    "absorbed-prless: combined PR did not become the canonical landing"
  assert_grep "pr_head=$combined_head" "$dir/state/task-a.meta" \
    "absorbed-prless: exact combined PR head was not recorded"
  assert_no_grep '^batch_superseded_pr=' "$dir/state/task-a.meta" \
    "absorbed-prless: binding invented a superseded original PR"
  assert_no_leaked_absorbed_pr_head_ref "$dir" absorbed-prless
  pass "fm-pr-check binds a PR-less constituent only through its exact head in a merged combined PR"
}

test_prless_absorbed_constituent_binding_refuses_when_combined_head_does_not_contain_task_head() {
  local dir rc absorbed_head combined_head squash_head tree
  dir=$(make_case absorbed-prless-uncontained)
  write_task_meta "$dir" task-a
  absorbed_head=$(git -C "$dir/wt" rev-parse HEAD)
  tree=$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')
  combined_head=$(printf '%s\n' unrelated | git -C "$dir/wt" commit-tree "$tree")
  publish_pr_head_ref "$dir" 9 "$combined_head"
  squash_head=$(land_squash_on_main "$dir" "$combined_head")
  install_absorbed_gh "$dir" '' "$combined_head" CLOSED MERGED "$squash_head"

  set +e
  run_pr_check "$dir" --absorbed-by task-a https://github.com/example/repo/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "absorbed-prless-uncontained: a combined head lacking the exact task head must refuse"
  assert_grep "does not contain task task-a's exact current head $absorbed_head" "$dir/stderr" \
    "absorbed-prless-uncontained: refusal did not name the missing exact head"
  assert_no_grep '^absorbed_original_pr=' "$dir/state/task-a.meta" \
    "absorbed-prless-uncontained: refusal wrote a partial binding"
  assert_no_leaked_absorbed_pr_head_ref "$dir" absorbed-prless-uncontained
  pass "fm-pr-check refuses a PR-less constituent absent from the combined PR head"
}

test_prless_absorbed_constituent_binding_refuses_an_unmerged_combined_pr() {
  local dir rc absorbed_head combined_head tree
  dir=$(make_case absorbed-prless-open)
  write_task_meta "$dir" task-a
  absorbed_head=$(git -C "$dir/wt" rev-parse HEAD)
  tree=$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')
  combined_head=$(printf '%s\n' combined | git -C "$dir/wt" commit-tree "$tree" -p "$absorbed_head")
  publish_pr_head_ref "$dir" 9 "$combined_head"
  install_absorbed_gh "$dir" '' "$combined_head" CLOSED OPEN ''

  set +e
  run_pr_check "$dir" --absorbed-by task-a https://github.com/example/repo/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "absorbed-prless-open: an open combined PR must refuse"
  assert_grep 'combined PR https://github.com/example/repo/pull/9 must be merged before binding a PR-less constituent' "$dir/stderr" \
    "absorbed-prless-open: refusal did not name the merged requirement"
  assert_no_grep '^absorbed_original_pr=' "$dir/state/task-a.meta" \
    "absorbed-prless-open: refusal wrote a partial binding"
  assert_no_leaked_absorbed_pr_head_ref "$dir" absorbed-prless-open
  pass "fm-pr-check refuses a PR-less constituent while the combined PR is open"
}

test_prless_absorbed_constituent_binding_refuses_a_merge_commit_absent_from_current_main() {
  local dir rc absorbed_head combined_head phantom_merge tree
  dir=$(make_case absorbed-prless-merge-absent)
  write_task_meta "$dir" task-a
  absorbed_head=$(git -C "$dir/wt" rev-parse HEAD)
  tree=$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')
  combined_head=$(printf '%s\n' combined | git -C "$dir/wt" commit-tree "$tree" -p "$absorbed_head")
  publish_pr_head_ref "$dir" 9 "$combined_head"
  land_squash_on_main "$dir" "$combined_head" >/dev/null
  phantom_merge=$(printf '%s\n' 'phantom squash landing' | git -C "$dir/wt" commit-tree "$tree")
  install_absorbed_gh "$dir" '' "$combined_head" CLOSED MERGED "$phantom_merge"

  set +e
  run_pr_check "$dir" --absorbed-by task-a https://github.com/example/repo/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "absorbed-prless-merge-absent: a forge-reported merge commit absent from main must refuse"
  assert_grep "merge commit $phantom_merge is not on current main" "$dir/stderr" \
    "absorbed-prless-merge-absent: refusal did not name the unlanded merge commit"
  assert_no_grep '^absorbed_original_pr=' "$dir/state/task-a.meta" \
    "absorbed-prless-merge-absent: refusal wrote a partial binding"
  assert_no_leaked_absorbed_pr_head_ref "$dir" absorbed-prless-merge-absent
  pass "fm-pr-check refuses a PR-less constituent whose combined merge commit is absent from current main"
}

test_mismatched_branch_refused
test_retry_suffix_accepted
test_prerequisite_recorded_separately
test_absorbed_constituent_binding_accepts_an_original_head_behind_the_exact_absorbed_head
test_absorbed_constituent_binding_refuses_when_the_combined_head_lacks_the_exact_absorbed_head
test_absorbed_constituent_binding_refuses_when_original_pr_head_is_not_an_ancestor
test_absorbed_constituent_binding_refuses_a_merged_original_pr
test_prless_absorbed_constituent_binding_accepts_only_the_exact_head_in_a_merged_combined_pr
test_prless_absorbed_constituent_binding_refuses_when_combined_head_does_not_contain_task_head
test_prless_absorbed_constituent_binding_refuses_an_unmerged_combined_pr
test_prless_absorbed_constituent_binding_refuses_a_merge_commit_absent_from_current_main
