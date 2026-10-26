#!/usr/bin/env bash
# Actual lifecycle commands and task backend; fake terminal/forge, no FM agents.
set -eu
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case "${1:-}" in
  control)
    FM_TEST_FIXTURE_IMPORT=control-relaunch
    # shellcheck source=tests/fm-control-relaunch.test.sh
    . "$TEST_DIR/fm-control-relaunch.test.sh"
    dir=$(new_case pending-proof proof-parent)
    add_ship_task "$dir" proof-parent claude
    seed_backlog "$dir" proof-parent in_flight
    printf 'backend = "markdown"\n' > "$dir/home/.tasks.toml"
    printf 'spawn_gen=proof-before-release\npr=https://github.com/example/repo/pull/7\n' >> "$dir/home/state/proof-parent.meta"
    printf 'Owner: this Firstmate home\nAcceptance: deployment target matches merged HEAD and journey proof passes.\nStatus: pending; branch is task-proof-parent.\n' > "$dir/home/data/proof-parent/proof.md"
    printf 'registered merge watch\n' > "$dir/home/state/proof-parent.pr-poll-registration"
    printf 'uncommitted preserved work\n' > "$dir/wt/pending.txt"
    tasks-axi add proof-child 'Consumes accepted parent' --file "$dir/home/data/backlog.md" >/dev/null
    tasks-axi block proof-child --by proof-parent --file "$dir/home/data/backlog.md" >/dev/null
    FM_HOME="$dir/home" "$ROOT/bin/fm-tasks-axi.sh" hold proof-parent --kind external --reason 'awaiting deployment and journey proof; owner is this home' >/dev/null
    cp "$dir/home/state/proof-parent.meta" "$dir/before.meta"
    cp "$dir/home/data/backlog.md" "$dir/before.backlog"
    cp "$dir/home/data/proof-parent/proof.md" "$dir/before.proof"
    before_head=$(git -C "$dir/wt" rev-parse HEAD)
    out=$(run_control "$dir" proof-parent exit)
    assert_contains "$out" 'stopped proof-parent' 'native exit should confirm stopped agent'
    cmp "$dir/before.meta" "$dir/home/state/proof-parent.meta"
    cmp "$dir/before.backlog" "$dir/home/data/backlog.md"
    cmp "$dir/before.proof" "$dir/home/data/proof-parent/proof.md"
    assert_present "$dir/wt/pending.txt" 'exit lost work'
    assert_present "$dir/home/state/proof-parent.pr-poll-registration" 'exit lost merge watch'
    [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$before_head" ] || fail 'exit changed worktree commit'
    [ "$(git -C "$dir/wt" branch --show-current)" = task-proof-parent ] || fail 'exit changed branch'
    pass 'pending proof native exit preserves task, owner home, work, branch, proof and child edges'
    out=$(run_control "$dir" proof-parent exit)
    assert_contains "$out" 'already-stopped' 'second exit should be idempotent'
    cmp "$dir/before.meta" "$dir/home/state/proof-parent.meta"
    report=$(FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-capacity.sh" --json)
    jq -e '.lanes==0' <<< "$report" >/dev/null || fail 'retained endpoint/meta consumed released seat'
    (
      cd "$dir/wt"
      exec sleep 60
    ) &
    # shellcheck disable=SC2031 # The PID is captured immediately in this shell.
    proof_work_pid=$!
    trap 'kill "$proof_work_pid" 2>/dev/null || true; wait "$proof_work_pid" 2>/dev/null || true; relaunch_cleanup' EXIT
    report=$(FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-capacity.sh" --json)
    jq -e '.lanes==1' <<< "$report" >/dev/null || fail 'live worktree process lost its seat'
    kill "$proof_work_pid"; wait "$proof_work_pid" 2>/dev/null || true
    trap relaunch_cleanup EXIT
    pass 'released seat follows real non-shell process occupancy, not retained metadata or endpoint'
    FM_HOME="$dir/home" "$ROOT/bin/fm-tasks-axi.sh" unhold proof-parent >/dev/null
    out=$(run_control "$dir" proof-parent relaunch --note 'Deployment completed; resume the pending journey proof from data/proof-parent/proof.md. Task remains unaccepted.')
    assert_contains "$out" 'relaunched proof-parent' 'native relaunch should resume preserved work'
    [ "$(meta_field "$dir" proof-parent worktree)" = "$dir/wt" ] || fail 'resume allocated another worktree'
    [ "$(meta_field "$dir" proof-parent spawn_gen)" != proof-before-release ] || fail 'resume reused old incarnation'
    [ "$(backlog_state "$dir" proof-parent)" = in_flight ] || fail 'resume prematurely accepted task'
    cmp "$dir/before.proof" "$dir/home/data/proof-parent/proof.md"
    assert_present "$dir/wt/pending.txt" 'resume lost preserved work'
    tasks-axi show proof-child --file "$dir/home/data/backlog.md" | grep -q 'blocked_by: proof-parent' || fail 'resume released child before proof'
    pass 'native relaunch resumes same task/worktree with new generation while proof and dependents remain pending'
    (
      FM_HOME="$dir/home"
      # shellcheck source=bin/fm-tasks-axi-lib.sh
      . "$ROOT/bin/fm-tasks-axi-lib.sh"
      # shellcheck source=bin/fm-backlog-transition-lib.sh
      . "$ROOT/bin/fm-backlog-transition-lib.sh"
      printf 'id=proof-parent\ndata=%s\nspawn_gen=proof-before-release\narg=--note\narg=local%%20main\n' "$dir/home/data" > "$dir/home/state/proof-parent.backlog-close"
      cp "$dir/home/state/proof-parent.meta" "$dir/resumed.meta"
      fm_backlog_close_marker_replay "$dir/home/state" "$dir/home/state/proof-parent.backlog-close" "$dir/home/data"
      [ "$FM_BACKLOG_CLOSE_REPLAY_RESULT" = stale ] || fail 'old close was not classified stale'
      cmp "$dir/resumed.meta" "$dir/home/state/proof-parent.meta"
      assert_absent "$dir/home/state/proof-parent.backlog-close" 'stale marker survived to target a later generation'
      [ "$(backlog_state "$dir" proof-parent)" = in_flight ] || fail 'old cleanup accepted resumed task'
    )
    pass 'late cleanup replay cannot erase the resumed task generation'

    ;;
  cleanup)
    FM_TEST_FIXTURE_IMPORT=teardown
    # shellcheck source=tests/fm-teardown.test.sh
    . "$TEST_DIR/fm-teardown.test.sh"
    for proof_wait in pending expired; do
      case_dir=$(prepare_recorded_github_pr "proof-$proof_wait")
      install_github_pr_class "$case_dir" merged
      arm_registered_merge_watch "$case_dir"
      if [ "$proof_wait" = expired ]; then
        tasks-axi hold task-x1 --kind external --reason 'awaiting deployment proof' --until 2000-01-01 --file "$case_dir/data/backlog.md" >/dev/null
      fi
      cp "$case_dir/state/task-x1.meta" "$case_dir/before.meta"
      cp "$case_dir/data/backlog.md" "$case_dir/before.backlog"
      teardown_capture "$case_dir"
      expect_code 1 "$TEARDOWN_CAPTURE_RC" "$proof_wait proof must refuse ordinary cleanup"
      assert_grep 'has not been explicitly accepted' "$case_dir/stderr" 'cleanup must require explicit acceptance'
      cmp "$case_dir/before.meta" "$case_dir/state/task-x1.meta"
      cmp "$case_dir/before.backlog" "$case_dir/data/backlog.md"
      assert_present "$case_dir/state/task-x1.pr-poll-registration" 'proof refusal retired merge watch'
      assert_present "$case_dir/wt/.git" 'proof refusal removed the resumable copy'
    done
    pass 'unheld and expired external proof waits preserve task, copy and merge watch before acceptance'
    case_dir=$(prepare_recorded_github_pr proof-keep-open)
    install_github_pr_class "$case_dir" merged
    teardown_capture "$case_dir" --keep-open
    expect_code 0 "$TEARDOWN_CAPTURE_RC" 'explicit keep-open must retain an unaccepted task'
    [ "$(backlog_row_state "$case_dir")" != 'done' ] || fail 'keep-open accepted pending work'
    assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" 'retention lost delivery reference'
    pass 'explicit keep-open releases cleanup resources while preserving the open task and delivery reference'
    case_dir=$(prepare_recorded_github_pr accepted-keep-open)
    install_github_pr_class "$case_dir" merged
    tasks-axi 'done' task-x1 --file "$case_dir/data/backlog.md" >/dev/null
    teardown_capture "$case_dir" --keep-open
    expect_code 0 "$TEARDOWN_CAPTURE_RC" 'keep-open must preserve an already accepted task'
    [ "$(backlog_row_state "$case_dir")" = 'done' ] || fail 'keep-open reopened accepted work'
    assert_absent "$case_dir/state/task-x1.meta" 'accepted keep-open cleanup retained task metadata'
    pass 'keep-open preserves existing acceptance while cleaning the finished worker record'
    case_dir=$(prepare_recorded_github_pr proof-held)
    install_github_pr_class "$case_dir" merged
    arm_registered_merge_watch "$case_dir"
    tasks-axi hold task-x1 --kind external --reason 'awaiting deployment proof' --file "$case_dir/data/backlog.md" >/dev/null
    cp "$case_dir/state/task-x1.meta" "$case_dir/before.meta"
    cp "$case_dir/data/backlog.md" "$case_dir/before.backlog"
    teardown_capture "$case_dir"
    expect_code 1 "$TEARDOWN_CAPTURE_RC" 'merged but externally held proof must refuse ordinary cleanup'
    assert_grep 'externally held' "$case_dir/stderr" 'refusal should name preserved wait'
    cmp "$case_dir/before.meta" "$case_dir/state/task-x1.meta"
    cmp "$case_dir/before.backlog" "$case_dir/data/backlog.md"
    assert_present "$case_dir/state/task-x1.pr-poll-registration" 'proof refusal retired merge watch'
    teardown_capture "$case_dir" --keep-open
    expect_code 1 "$TEARDOWN_CAPTURE_RC" 'keep-open must not discard externally held resume artifacts'
    cmp "$case_dir/before.meta" "$case_dir/state/task-x1.meta"
    pass 'merged pending-proof task refuses destructive cleanup and keeps its merge watch'
    add_blocked_by_child "$case_dir" proof-child 'Depends on accepted delivery'
    printf 'accepted: required target revision and journey verified\n' > "$case_dir/data/accepted-proof.md"
    tasks-axi unhold task-x1 --file "$case_dir/data/backlog.md" >/dev/null
    tasks-axi 'done' task-x1 --note 'accepted proof: data/accepted-proof.md' --file "$case_dir/data/backlog.md" >/dev/null
    tasks-axi show proof-child --file "$case_dir/data/backlog.md" | grep -q 'blocked: no' || fail 'accepted parent did not unblock child'
    assert_grep 'blocked-by: task-x1' "$case_dir/data/backlog.md" 'acceptance erased raw dependency edge'
    teardown_capture "$case_dir"
    expect_code 0 "$TEARDOWN_CAPTURE_RC" 'accepted parent with dependent should clean without deadlock'
    assert_absent "$case_dir/state/task-x1.meta" 'accepted cleanup retained endpoint record'
    assert_present "$case_dir/data/accepted-proof.md" 'accepted cleanup removed proof'
    tasks-axi 'done' task-x1 --note 'accepted proof: data/accepted-proof.md' --file "$case_dir/data/backlog.md" >/dev/null
    cp "$case_dir/data/backlog.md" "$case_dir/accepted.backlog"
    teardown_capture "$case_dir"
    cmp "$case_dir/accepted.backlog" "$case_dir/data/backlog.md"
    pass 'accepted completion precedes cleanup, preserves child edge, unblocks child and safely repeats'
    case_dir=$(prepare_recorded_github_pr accepted-archived)
    install_github_pr_class "$case_dir" merged
    printf '%s\n' 'backend = "markdown"' '[markdown]' 'path = "data/backlog.md"' \
      'archive = "data/done-archive.md"' 'done_keep = 0' > "$case_dir/.tasks.toml"
    (cd "$case_dir" && tasks-axi 'done' task-x1 --pr https://github.com/example/repo/pull/7 >/dev/null)
    assert_present "$case_dir/data/done-archive.md" 'explicit acceptance did not archive the task'
    cp "$case_dir/data/done-archive.md" "$case_dir/before.archive"
    teardown_capture "$case_dir"
    expect_code 0 "$TEARDOWN_CAPTURE_RC" 'already archived accepted task must still clean'
    assert_absent "$case_dir/state/task-x1.meta" 'archived accepted cleanup retained task metadata'
    assert_absent "$case_dir/state/task-x1.backlog-close" 'archived accepted cleanup retained recovery marker'
    cmp "$case_dir/before.archive" "$case_dir/data/done-archive.md"
    pass 'zero-retention acceptance archives before cleanup without a second completion write'
    for proof_wait in pending external expired; do
      for record in present removed; do
        (
          case_dir=$(prepare_recorded_github_pr "interrupted-$proof_wait-$record")
          FM_HOME="$case_dir"
          # shellcheck source=bin/fm-tasks-axi-lib.sh
          . "$ROOT/bin/fm-tasks-axi-lib.sh"
          # shellcheck source=bin/fm-backlog-transition-lib.sh
          . "$ROOT/bin/fm-backlog-transition-lib.sh"
          case "$proof_wait" in
            external) tasks-axi hold task-x1 --kind external --reason 'awaiting deployment proof' --file "$case_dir/data/backlog.md" >/dev/null ;;
            expired) tasks-axi hold task-x1 --kind external --reason 'awaiting deployment proof' --until 2000-01-01 --file "$case_dir/data/backlog.md" >/dev/null ;;
          esac
          replay_gen=$(sed -n 's/^spawn_gen=//p' "$case_dir/state/task-x1.meta")
          marker="$case_dir/state/task-x1.backlog-close"
          printf 'id=task-x1\ndata=%s\nspawn_gen=%s\narg=--note\narg=local%%20main\n' "$case_dir/data" "$replay_gen" > "$marker"
          cp "$marker" "$case_dir/before.marker"
          cp "$case_dir/data/backlog.md" "$case_dir/before.backlog"
          if [ "$record" = present ]; then
            cp "$case_dir/state/task-x1.meta" "$case_dir/before.meta"
          else
            rm "$case_dir/state/task-x1.meta"
          fi
          for replay in 1 2; do
            rc=0
            fm_backlog_close_marker_replay "$case_dir/state" "$marker" "$case_dir/data" || rc=$?
            expect_code 1 "$rc" "$proof_wait proof with $record metadata must refuse replay $replay"
            if [ "$record" = present ]; then cmp "$case_dir/before.meta" "$case_dir/state/task-x1.meta"; fi
            cmp "$case_dir/before.marker" "$marker"
            cmp "$case_dir/before.backlog" "$case_dir/data/backlog.md"
          done
          tasks-axi unhold task-x1 --file "$case_dir/data/backlog.md" >/dev/null
          tasks-axi 'done' task-x1 --note 'accepted fixture deployment proof' --file "$case_dir/data/backlog.md" >/dev/null
          fm_backlog_close_marker_replay "$case_dir/state" "$marker" "$case_dir/data" || fail "accepted replay failed: $FM_BACKLOG_TRANSITION_ERROR"
          assert_absent "$case_dir/state/task-x1.meta" 'accepted close replay retained old record'
          assert_absent "$marker" 'accepted close replay left marker'
          fm_backlog_close_marker_replay "$case_dir/state" "$marker" "$case_dir/data" || fail "accepted replay failed: $FM_BACKLOG_TRANSITION_ERROR"
          [ "$FM_BACKLOG_CLOSE_REPLAY_RESULT" = noop ] || fail 'accepted replay was not idempotent'
        )
      done
    done
    pass 'both interrupted-close states preserve pending and expired proof waits until explicit acceptance'
    (
      case_dir=$(prepare_recorded_github_pr replay-captain-retains)
      FM_HOME="$case_dir"
      # shellcheck source=bin/fm-tasks-axi-lib.sh
      . "$ROOT/bin/fm-tasks-axi-lib.sh"
      # shellcheck source=bin/fm-backlog-transition-lib.sh
      . "$ROOT/bin/fm-backlog-transition-lib.sh"
      tasks-axi hold task-x1 --kind captain --reason 'choose delivery' --file "$case_dir/data/backlog.md" >/dev/null
      replay_gen=$(sed -n 's/^spawn_gen=//p' "$case_dir/state/task-x1.meta")
      marker="$case_dir/state/task-x1.backlog-close"
      printf 'id=task-x1\ndata=%s\nspawn_gen=%s\narg=--note\narg=local%%20main\n' "$case_dir/data" "$replay_gen" > "$marker"
      fm_backlog_close_marker_replay "$case_dir/state" "$marker" "$case_dir/data" || fail "captain retention failed: $FM_BACKLOG_TRANSITION_ERROR"
      [ "$FM_BACKLOG_CLOSE_REPLAY_RESULT" = retained_incomplete ] || fail 'captain hold was not retained'
      [ "$(backlog_row_state "$case_dir")" = queued ] || fail 'captain retention accepted pending work'
      tasks-axi show task-x1 --file "$case_dir/data/backlog.md" | grep -q 'hold_kind: captain' || fail 'retention lost captain decision'
    )
    pass 'close replay retains a captain-held task without accepting it'

    ;;
  '')
    bash "$0" control
    bash "$0" cleanup
    ;;
  *) exit 2 ;;
esac
