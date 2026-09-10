#!/usr/bin/env bash
# Tests for bin/fm-merge-outcome-lib.sh's ready-frontier attachment: a merging
# PR is how a `blocked-by` dependency clears, so fm_merge_outcome_report - the
# single convergence point for both a self-performed merge and a polled one -
# carries the actual ready frontier with the outcome, not just a landed-PR
# notice. tests/fm-pr-merge.test.sh already pins where the outcome record goes
# (parent status line vs. local wake) through the real merge entrypoint; this
# file unit-tests the frontier attachment directly against both legal `origin`
# values, since only bin/fm-watch.sh drives the `poll` origin end to end and
# standing up its full merge-poll fixture here would test machinery this
# change never touches.
#
# Matrix:
#   (a) origin=self on a main home: the local wake carries the ready item ids
#       and the standing no-cap sentence
#   (b) origin=poll on a main home: same attachment, so a merge the captain
#       performs directly on GitHub is covered identically to one firstmate
#       performs itself
#   (c) a ready-probe failure (manual backlog backend) degrades to the outcome
#       report's existing behavior with no ready-frontier addendum, and the
#       report still succeeds
#   (d) a secondmate's upward status line stays exact-line dedupable across an
#       at-least-once retry even though the ready frontier is time-varying: the
#       frontier attaches only to the local wake, never to the upward line
#   (e) the deploy handoff this function now makes is completely inert for a
#       task whose project has no deploy policy: same wake, nothing else
#   (f) a deploy that cannot even be assessed never turns a recorded merge into
#       an unrecorded one. bin/fm-pr-merge.sh reads a non-zero return here as
#       "the merge landed and the record did not", so the deploy's own trouble
#       must not borrow that meaning
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || fail "these tests need the real tasks-axi to seed a backlog"
TMP_ROOT=$(fm_test_tmproot fm-merge-outcome-lib-tests)

FM_READY_FRONTIER_SENTENCE_FOR_TEST='Live tasks are bounded by the concurrency cap and by serial integration onto an unstable seam; preparation is never seam-bounded, and every undispatched ready item carries a recorded rule, owner, and recheck event.'

# make_main_home_case <name>: a plain main home (no .fm-secondmate-home marker)
# with a real data/backlog.md carrying one already-ready, unblocked item.
# Echoes the case dir; the home is "$case_dir/home", the state dir
# "$case_dir/state".
make_main_home_case() {
  local name=$1 case_dir home state
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  state="$case_dir/state"
  mkdir -p "$home/data" "$state"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  tasks-axi add task-r1 "an independent ready item" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  printf '%s\n' "$case_dir"
}

call_merge_outcome_report() {  # <home> <state> <id> <url> <origin>
  (
    FM_ROOT_OVERRIDE="$ROOT"
    . "$ROOT/bin/fm-merge-outcome-lib.sh"
    fm_merge_outcome_report "$1" "$2" "$3" "$4" "$5"
  )
}

test_self_origin_attaches_the_ready_frontier() {
  local case_dir home state url rc=0
  case_dir=$(make_main_home_case self-origin-frontier)
  home="$case_dir/home"
  state="$case_dir/state"
  url=https://github.com/example/repo/pull/91

  call_merge_outcome_report "$home" "$state" task-x1 "$url" self || rc=$?
  [ "$rc" -eq 0 ] || fail "self-origin-frontier: fm_merge_outcome_report failed: rc=$rc"

  assert_present "$state/.wake-queue" \
    "self-origin-frontier: a main-home self-merge left no local wake"
  assert_grep 'task-r1' "$state/.wake-queue" \
    "self-origin-frontier: the merge outcome wake omitted the ready item it should have shown"
  assert_grep "$FM_READY_FRONTIER_SENTENCE_FOR_TEST" "$state/.wake-queue" \
    "self-origin-frontier: the merge outcome wake dropped the standing no-cap sentence"
  pass "a self-performed merge's outcome wake carries the ready frontier"
}

test_poll_origin_attaches_the_ready_frontier() {
  local case_dir home state url rc=0
  case_dir=$(make_main_home_case poll-origin-frontier)
  home="$case_dir/home"
  state="$case_dir/state"
  url=https://github.com/example/repo/pull/92

  call_merge_outcome_report "$home" "$state" task-x1 "$url" poll || rc=$?
  [ "$rc" -eq 0 ] || fail "poll-origin-frontier: fm_merge_outcome_report failed: rc=$rc"

  assert_present "$state/.wake-queue" \
    "poll-origin-frontier: a merge detected by the watcher's poll left no local wake"
  assert_grep 'task-r1' "$state/.wake-queue" \
    "poll-origin-frontier: the merge outcome wake omitted the ready item it should have shown"
  assert_grep "$FM_READY_FRONTIER_SENTENCE_FOR_TEST" "$state/.wake-queue" \
    "poll-origin-frontier: the merge outcome wake dropped the standing no-cap sentence"
  pass "a merge the captain performs directly, detected by the poll, carries the ready frontier identically"
}

test_ready_probe_failure_still_reports_the_merge() {
  local case_dir home state url rc=0
  case_dir=$(make_main_home_case ready-probe-fails)
  home="$case_dir/home"
  state="$case_dir/state"
  url=https://github.com/example/repo/pull/93
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"

  call_merge_outcome_report "$home" "$state" task-x1 "$url" self || rc=$?
  [ "$rc" -eq 0 ] || fail "ready-probe-fails: fm_merge_outcome_report should still succeed when the ready probe is unavailable: rc=$rc"

  assert_present "$state/.wake-queue" \
    "ready-probe-fails: a landed merge produced no outcome wake at all"
  assert_grep "merge landed: task-x1 $url" "$state/.wake-queue" \
    "ready-probe-fails: the landed-merge notice itself was dropped"
  assert_no_grep "$FM_READY_FRONTIER_SENTENCE_FOR_TEST" "$state/.wake-queue" \
    "ready-probe-fails: a failed ready probe should never fabricate a frontier report"
  pass "a ready-probe failure degrades gracefully: the merge is still reported, with no frontier addendum"
}

test_upward_line_stays_dedupable_across_a_changing_frontier() {
  local case_dir home state url marker rc=0 lines
  case_dir="$TMP_ROOT/secondmate-frontier-retry"
  home="$case_dir/home"
  state="$case_dir/state"
  mkdir -p "$home/data" "$state"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  tasks-axi add task-r1 "first ready item" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  printf '%s\n' mate-x > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$home/.fm-secondmate-parent"
  url=https://github.com/example/repo/pull/94
  marker="$state/task-x1.pr-poll-merge-notified"

  call_merge_outcome_report "$home" "$state" task-x1 "$url" self || rc=$?
  [ "$rc" -eq 0 ] || fail "frontier-retry: first report failed: rc=$rc"
  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" \
    "$state/parent-replies.status" \
    "frontier-retry: the first report never reached the parent channel"

  # Simulate the header's documented at-least-once window: the outcome
  # published but the notified marker's commit never landed, so a retry
  # replays the whole publish path. Change the ready frontier in between, the
  # way real elapsed time between a publish and its retry would.
  rm -f "$marker"
  tasks-axi add task-r2 "second ready item, added between attempts" --kind ship \
    --file "$home/data/backlog.md" >/dev/null

  rc=0
  call_merge_outcome_report "$home" "$state" task-x1 "$url" self || rc=$?
  [ "$rc" -eq 0 ] || fail "frontier-retry: retried report failed: rc=$rc"

  lines=$(grep -c -F "merged task-x1 $url" "$state/parent-replies.status" 2>/dev/null || true)
  [ "$lines" -eq 1 ] \
    || fail "frontier-retry: a changing ready frontier broke the upward line's at-most-once dedup: got $lines line(s)"
  pass "the upward status line stays exact-line dedupable across a retry even while the ready frontier changes"
}

test_the_deploy_handoff_is_inert_without_a_policy() {
  local case_dir home state url rc=0 rows
  case_dir=$(make_main_home_case deploy-handoff-inert)
  home="$case_dir/home"
  state="$case_dir/state"
  url=https://github.com/example/repo/pull/93
  mkdir -p "$home/projects/demo"
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
  case_dir=$(make_main_home_case deploy-handoff-failure)
  home="$case_dir/home"
  state="$case_dir/state"
  url=https://github.com/example/repo/pull/94
  mkdir -p "$home/projects/demo" "$home/config/deploy-policy"
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

# Controlled case C2, steps 1, 2, 4, and 6.
# Candidate: a finite official-main clause check followed by the existing
# fm_merge_outcome_report convergence point and tasks-axi ready frontier.
# Fixture boundary: two isolated homes, synthetic local git repositories, real
# tasks-axi against fixture backlogs, and no forge/backend/deployment access.
# Assertions: branch-only and green-only refusal, self/poll equivalence,
# preparation/integration separation, narrow dependencies, stage-gate
# preservation, and repeated-observation dedupe after the frontier changes.
test_c2_only_official_main_landing_releases_the_accepted_frontier() {
  local case_self case_poll home_self home_poll state_self state_poll repo_self repo_poll
  local url self_event poll_event before after rc=0
  case_self=$(make_main_home_case controlled-c2-self)
  case_poll=$(make_main_home_case controlled-c2-poll)
  home_self="$case_self/home"
  home_poll="$case_poll/home"
  state_self="$case_self/state"
  state_poll="$case_poll/state"
  repo_self="$case_self/project"
  repo_poll="$case_poll/project"
  url=https://github.com/example/repo/pull/202

  c2_seed_repo() {  # <repo>
    local c_repo=$1
    fm_git_init_commit "$c_repo"
    git -C "$c_repo" branch -M main
    git -C "$c_repo" checkout -q -b prerequisite-p
    mkdir -p "$c_repo/contracts"
    printf 'promoted-clause: integration-v2\n' > "$c_repo/contracts/named-clause.txt"
    git -C "$c_repo" add contracts/named-clause.txt
    git -C "$c_repo" commit -q -m 'add named prerequisite clause'
    git -C "$c_repo" checkout -q main
  }

  c2_seed_backlog() {  # <home>
    local c_home=$1 backlog="$1/data/backlog.md"
    tasks-axi add prerequisite-p "Land prerequisite P" --kind ship --file "$backlog" >/dev/null
    tasks-axi start prerequisite-p --file "$backlog" >/dev/null
    tasks-axi add work-w "Integrate W after named clause" --kind ship \
      --blocked-by prerequisite-p --file "$backlog" >/dev/null
    tasks-axi add stage-final "Final stage authority" --kind ship --file "$backlog" >/dev/null
    tasks-axi add work-z "Work requiring final stage" --kind ship \
      --blocked-by stage-final --file "$backlog" >/dev/null
    tasks-axi add change-unrelated "Unticked unrelated Change task" --kind ship --file "$backlog" >/dev/null
    printf 'prepared-before-integration\n' > "$c_home/work-w-preparation"
  }

  c2_landing_accepted() {  # <repo> <fake-pr-state>
    local c_repo=$1 c_pr_state=$2 clause
    [ "$c_pr_state" = merged ] || return 1
    clause=$(git -C "$c_repo" show refs/heads/main:contracts/named-clause.txt 2>/dev/null) || return 1
    [ "$clause" = 'promoted-clause: integration-v2' ]
  }

  c2_broken_green_or_branch_accepts() {  # <repo> <fake-pr-state>
    [ "$2" = green ] || git -C "$1" show refs/heads/prerequisite-p:contracts/named-clause.txt >/dev/null 2>&1
  }

  c2_seed_repo "$repo_self"
  c2_seed_repo "$repo_poll"
  c2_seed_backlog "$home_self"
  c2_seed_backlog "$home_poll"

  # Intentionally broken counterexample: a branch-presence/green predicate
  # accepts this fixture, while the controlled official-main predicate must
  # reject it and therefore publish no merge event or integration run.
  c2_broken_green_or_branch_accepts "$repo_self" green \
    || fail "C2 broken candidate did not accept the deliberately insufficient green-only evidence"
  if c2_landing_accepted "$repo_self" green; then
    fail "C2 accepted a green pull request with no official-main clause"
  fi
  if c2_landing_accepted "$repo_self" merged; then
    fail "C2 accepted a branch-only clause as official-main landing"
  fi
  assert_absent "$state_self/.wake-queue" "C2 refusal published a merge event"
  [ -s "$home_self/work-w-preparation" ] \
    || fail "C2 prevented independent W preparation while integration waited"
  tasks-axi show work-w --full --file "$home_self/data/backlog.md" | grep -F 'blocked: yes' >/dev/null \
    || fail "C2 green-only evidence released W integration"

  # Land a squash-shaped commit containing the named clause on each synthetic
  # official main, then publish through both legal observation origins.
  for repo in "$repo_self" "$repo_poll"; do
    git -C "$repo" merge --squash prerequisite-p >/dev/null
    git -C "$repo" commit -q -m 'land prerequisite P'
    c2_landing_accepted "$repo" merged \
      || fail "C2 official-main named-clause evidence was not accepted after landing"
  done
  printf 'validation official-main clause integration-v2\n' > "$home_self/validation-runs"
  printf 'validation official-main clause integration-v2\n' > "$home_poll/validation-runs"
  call_merge_outcome_report "$home_self" "$state_self" prerequisite-p "$url" self || rc=$?
  [ "$rc" -eq 0 ] || fail "C2 self merge publication failed: rc=$rc"
  rc=0
  call_merge_outcome_report "$home_poll" "$state_poll" prerequisite-p "$url" poll || rc=$?
  [ "$rc" -eq 0 ] || fail "C2 poll merge publication failed: rc=$rc"

  self_event=$(cut -f3- "$state_self/.wake-queue")
  poll_event=$(cut -f3- "$state_poll/.wake-queue")
  [ "$self_event" = "$poll_event" ] \
    || fail "C2 self and poll paths produced different durable events or ready frontiers"
  assert_contains "$self_event" "merge landed: prerequisite-p $url" \
    "C2 converged event omitted the confirmed merge identity"
  assert_contains "$self_event" "change-unrelated" \
    "C2 frontier omitted independently ready unrelated work"
  assert_not_contains "$self_event" "work-w" \
    "C2 merge observation released W before P's own row completed"

  # Guarded completion is represented here by the same tasks-axi transition
  # fm_backlog_close_transition owns; the destructive-cleanup interruption and
  # marker replay are exercised in fm-backlog-atomicity.test.sh below.
  tasks-axi "done" prerequisite-p --file "$home_self/data/backlog.md" >/dev/null
  tasks-axi "done" prerequisite-p --file "$home_poll/data/backlog.md" >/dev/null
  tasks-axi ready --file "$home_self/data/backlog.md" | grep -F 'work-w' >/dev/null \
    || fail "C2 did not release W after official-main evidence and P completion"
  tasks-axi show work-z --full --file "$home_self/data/backlog.md" | grep -F 'blocked: yes' >/dev/null \
    || fail "C2 released Z without its final-stage authority"
  tasks-axi ready --file "$home_self/data/backlog.md" | grep -F 'work-w' >/dev/null \
    || fail "C2 unrelated unticked Change work blocked W's narrower accepted dependency"

  before=$(wc -l < "$state_self/.wake-queue" | tr -d ' ')
  call_merge_outcome_report "$home_self" "$state_self" prerequisite-p "$url" self \
    || fail "C2 repeated merge observation failed"
  after=$(wc -l < "$state_self/.wake-queue" | tr -d ' ')
  [ "$before" -eq 1 ] && [ "$after" -eq 1 ] \
    || fail "C2 repeated observation created a second substantive merge event"
  [ "$(wc -l < "$home_self/validation-runs" | tr -d ' ')" -eq 1 ] \
    || fail "C2 repeated observation launched a duplicate validation run"

  pass "C2 requires official-main clause evidence, converges self and poll, preserves narrow gates, and deduplicates recurrence"
}

test_self_origin_attaches_the_ready_frontier
test_poll_origin_attaches_the_ready_frontier
test_ready_probe_failure_still_reports_the_merge
test_upward_line_stays_dedupable_across_a_changing_frontier
test_the_deploy_handoff_is_inert_without_a_policy
test_a_deploy_that_cannot_be_assessed_still_records_the_merge
test_c2_only_official_main_landing_releases_the_accepted_frontier
