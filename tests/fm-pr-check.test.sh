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
  printf '%s\n' "$dir"
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
  cat > "$dir/fakebin/gh" <<SH
#!/usr/bin/env bash
url=\${3:-}
case "\$url| \$* " in
  "https://github.com/example/repo/pull/5|"*" --json state "*) printf '%s\n' '$original_state' ;;
  "https://github.com/example/repo/pull/5|"*" --json headRefName "*) printf '%s\n' 'fm/task-a' ;;
  "https://github.com/example/repo/pull/5|"*" --json headRefOid "*) printf '%s\n' '$original_head' ;;
  "https://github.com/example/repo/pull/9|"*" --json headRefName "*) printf '%s\n' 'fm/integration-batch' ;;
  "https://github.com/example/repo/pull/9|"*" --json headRefOid "*) printf '%s\n' '$combined_head' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
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

test_absorbed_constituent_binding_records_combined_landing_without_marking_original_merged() {
  local dir rc constituent_head combined_head tree count
  dir=$(make_case absorbed)
  write_task_meta "$dir" task-a
  constituent_head=$(git -C "$dir/wt" rev-parse HEAD)
  tree=$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')
  combined_head=$(printf '%s\n' combined | git -C "$dir/wt" commit-tree "$tree" -p "$constituent_head")
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/5' \
    "pr_head=$constituent_head" >> "$dir/state/task-a.meta"
  install_absorbed_gh "$dir" "$constituent_head" "$combined_head"

  set +e
  run_pr_check "$dir" --absorbed-by task-a https://github.com/example/repo/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "absorbed: a closed superseded PR contained in the combined head should bind"
  assert_grep 'batch_role=constituent' "$dir/state/task-a.meta" \
    "absorbed: constituent role was not recorded"
  assert_grep 'batch_constituent_branch=fm/task-a' "$dir/state/task-a.meta" \
    "absorbed: original branch was not preserved"
  assert_grep "batch_constituent_head=$constituent_head" "$dir/state/task-a.meta" \
    "absorbed: exact constituent head was not preserved"
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
  pass "fm-pr-check binds a closed superseded constituent to the containing combined PR without recording the original as merged"
}

test_absorbed_constituent_binding_refuses_a_combined_head_without_the_constituent_commit() {
  local dir rc constituent_head unrelated_head tree
  dir=$(make_case absorbed-missing-head)
  write_task_meta "$dir" task-a
  constituent_head=$(git -C "$dir/wt" rev-parse HEAD)
  tree=$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')
  unrelated_head=$(printf '%s\n' unrelated | git -C "$dir/wt" commit-tree "$tree")
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/5' \
    "pr_head=$constituent_head" >> "$dir/state/task-a.meta"
  install_absorbed_gh "$dir" "$constituent_head" "$unrelated_head"

  set +e
  run_pr_check "$dir" --absorbed-by task-a https://github.com/example/repo/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "absorbed-missing-head: a combined head lacking the constituent commit must refuse"
  assert_grep 'does not contain constituent head' "$dir/stderr" \
    "absorbed-missing-head: refusal did not name the missing constituent head"
  assert_grep 'pr=https://github.com/example/repo/pull/5' "$dir/state/task-a.meta" \
    "absorbed-missing-head: refusal replaced the original PR record"
  assert_no_grep 'batch_role=' "$dir/state/task-a.meta" \
    "absorbed-missing-head: refusal wrote a partial batch binding"
  assert_absent "$dir/state/task-a.check.sh" \
    "absorbed-missing-head: refusal armed a combined PR poll"
  pass "fm-pr-check refuses an absorbed binding when the combined PR head lacks the constituent commit"
}

test_mismatched_branch_refused
test_retry_suffix_accepted
test_prerequisite_recorded_separately
test_absorbed_constituent_binding_records_combined_landing_without_marking_original_merged
test_absorbed_constituent_binding_refuses_a_combined_head_without_the_constituent_commit
