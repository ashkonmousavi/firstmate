#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    case "${FM_FAKE_PANE_MODE:-}" in
      late-first)
        [ "$n" -eq 60 ] && printf '%s\n' "${FM_FAKE_PANE_PATH:-}" \
          || printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
        ;;
      disappear)
        [ "$n" -eq 1 ] && printf '%s\n' "${FM_FAKE_PANE_PATH:-}" || printf '\n'
        ;;
      *)
        if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
          printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
        else
          printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
        fi
        ;;
    esac
    exit 0
    ;;
esac
case "${1:-}" in
  capture-pane)
    [ -z "${FM_FAKE_PANE_CAPTURE:-}" ] || cat "$FM_FAKE_PANE_CAPTURE"
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
case "${1:-}" in
  get)
    if [ -n "${FM_FAKE_TREEHOUSE_REFUSAL_FILE:-}" ]; then
      cat "$FM_FAKE_TREEHOUSE_REFUSAL_FILE" >&2
      exit 1
    fi
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    ;;
  status)
    printf '1     leased       %s holder=%s\n' "${FM_FAKE_PANE_PATH:-}" "${FM_FAKE_LEASE_HOLDER:-}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" sleep
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.

Prep: Tier 0 - test fixture, not a real change
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_PANE_MODE="${PANE_MODE:-}" \
    FM_FAKE_TREEHOUSE_LOG="$(dirname "$HOME_DIR")/treehouse.log" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A matching read establishes only a candidate. If it arrives on the final
# iteration, there is no second read to confirm it and spawn must refuse.
test_final_iteration_first_match_is_not_settled() {
  local rec id out status PANE_MODE=late-first
  id=settle-late-first-z6
  rec=$(make_settle_case settle-late-first "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 1 "$status" "one final-iteration match must not prove settling"
  assert_contains "$out" "endpoint did not enter durable worktree" \
    "the unconfirmed final match did not produce the settle refusal"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "an unconfirmed final match published task metadata"
  pass "a first match on the final settle iteration remains unconfirmed and refuses"
}

# A match followed by unreadable/empty cwd samples must clear the candidate;
# it cannot survive until the loop ends and masquerade as two matching reads.
test_matching_read_that_disappears_is_not_settled() {
  local rec id out status PANE_MODE=disappear
  id=settle-disappears-z7
  rec=$(make_settle_case settle-disappears "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 1 "$status" "a matching read followed by empty reads must not prove settling"
  assert_contains "$out" "endpoint did not enter durable worktree" \
    "the disappearing match did not produce the settle refusal"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a disappearing match published task metadata"
  pass "a matching cwd that disappears is cleared and never treated as settled"
}

run_refused_pool_spawn() {
  local id=$1 capture=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$PROJ_DIR" FM_FAKE_PANE_STALE="$PROJ_DIR" \
    FM_FAKE_PANE_STALE_READS=60 FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_PANE_CAPTURE="$capture" \
    FM_FAKE_TREEHOUSE_REFUSAL_FILE="$capture" \
    FM_FAKE_TREEHOUSE_LOG="$(dirname "$HOME_DIR")/treehouse.log" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

test_fresh_spawn_uses_a_durable_task_lease_and_records_its_holder() {
  local rec id out status log
  id=settle-durable-lease-z5
  rec=$(make_settle_case settle-durable-lease "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "durable lease spawn should succeed: $out"
  log="$(dirname "$HOME_DIR")/treehouse.log"
  assert_grep "get --lease --lease-holder $id" "$log" \
    "fresh spawn did not acquire a durable task-labelled Treehouse lease"
  assert_grep "treehouse_lease_holder=$id" "$HOME_DIR/state/$id.meta" \
    "task metadata did not preserve the durable lease holder"
  pass "fresh spawn acquires a durable task lease and records its holder"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# The pool hands out a slot another task's record still names, and the spawn
# refuses it.
#
# Current treehouse durable leases survive the acquiring process and keep a
# stopped lane's slot reserved. Firstmate still cross-checks task records so a
# legacy or corrupt pool state cannot hand out a path another task owns; the
# refusal remains the fail-closed defense for that mismatch.
#
# The second half matters as much as the first: the settle loop hands back a
# path this task legitimately owns on almost every spawn, so a guard that
# refused on any recorded match would refuse every relaunch and every ordinary
# reuse. Only ANOTHER task's record is a collision.
#
# Red before assert_worktree_unclaimed existed: the spawn accepted the slot,
# exited 0, and wrote a second meta naming the same worktree.
test_a_worktree_another_task_records_is_refused() {
  local rec id other out status
  id=settle-collision-z4
  other=settle-collision-incumbent
  rec=$(make_settle_case settle-collision "$id" 0)
  read_settle_record "$rec"

  # The incumbent is parked: its agent is stopped, which is exactly the state
  # that makes its slot look free to the pool.
  printf 'worktree=%s\nwindow=fm-sess:incumbent\nparked=%s\n' \
    "$WT_DIR" "$(( $(date +%s) - 900 ))" > "$HOME_DIR/state/$other.meta"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 1 "$status" "spawn must refuse a worktree another task's record names"
  assert_contains "$out" "task $other's record already names that worktree" \
    "the refusal did not name the colliding task id"
  [ ! -f "$HOME_DIR/state/$id.meta" ] \
    || fail "spawn published a second record naming $WT_DIR after refusing it"

  # The incumbent's own record is untouched - the refusal costs a spawn, never
  # the lane that already owned the slot.
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$other.meta" \
    "the refusal disturbed the incumbent task's record"

  # Same pool slot, no other claim: the spawn proceeds. A task's own record is
  # not a collision either, or every relaunch would refuse.
  rm -f "$HOME_DIR/state/$other.meta"
  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn must accept a worktree no other task records"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "spawn did not record the worktree once the collision was gone"
  pass "a pool slot another task's record names is refused by colliding id, and an unclaimed one is not"
}

test_treehouse_pool_refusal_replaces_the_generic_worktree_timeout() {
  local rec id out status capture case_dir
  id=settle-pool-refusal-z3
  rec=$(make_settle_case settle-pool-refusal "$id" 0)
  read_settle_record "$rec"
  case_dir=$(dirname "$HOME_DIR")
  capture="$case_dir/treehouse-refusal-pane.txt"
  printf '%s\n' 'treehouse: all 16 worktrees are in use or dirty (max_trees = 16)' > "$capture"

  out=$(run_refused_pool_spawn "$id" "$capture")
  status=$?
  expect_code 1 "$status" "spawn should fail when treehouse refuses the pool lease"
  assert_contains "$out" 'all 16 worktrees are in use or dirty (max_trees = 16)' \
    "spawn did not surface treehouse's pool refusal"
  assert_not_contains "$out" 'endpoint did not enter durable worktree' \
    "spawn waited for endpoint settling after Treehouse had already refused allocation"
  pass "treehouse pool refusal is reported instead of the generic worktree timeout"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_fresh_spawn_uses_a_durable_task_lease_and_records_its_holder
test_a_worktree_another_task_records_is_refused
test_final_iteration_first_match_is_not_settled
test_matching_read_that_disappears_is_not_settled

test_treehouse_pool_refusal_replaces_the_generic_worktree_timeout

echo "# all fm-spawn-worktree-settle tests passed"
