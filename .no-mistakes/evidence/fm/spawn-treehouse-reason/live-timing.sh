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
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "~/.no-mistakes/worktrees/049a88734b0e/01M6K2PVFHAGDMR9GPE62WEN11/tests/fixtures.sh"

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
window_file="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}.window"
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  capture-pane)
    capture_count_file="${FM_FAKE_PANE_COUNTFILE}.captures"
    captures=0
    [ ! -f "$capture_count_file" ] || captures=$(cat "$capture_count_file")
    captures=$((captures + 1))
    printf '%s\n' "$captures" > "$capture_count_file"
    [ "${FM_FAKE_CAPTURE_FAIL_ON:-0}" != "$captures" ] || exit 1
    [ "${FM_FAKE_CAPTURE_UNREADABLE:-0}" = 0 ] || exit 1
    lines=80
    previous=
    for arg in "$@"; do
      [ "$previous" != -S ] || lines=${arg#-}
      previous=$arg
    done
    {
      cat "${FM_FAKE_PANE_COUNTFILE}.output" 2>/dev/null
      printf '%s\n' "${FM_FAKE_CAPTURE_TRAILER:-}"
    } | tail -n "$lines"
    exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file"; exit 0 ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$window_file"
    exit 0 ;;
  kill-window) : > "$window_file"; exit 0 ;;
  has-session|new-session) exit 0 ;;
  send-keys)
    for arg in "$@"; do
      case "$arg" in
        'treehouse get'*)
          # Execute the submitted shell line against a fake external boundary,
          # so the exit marker is emitted by the real command, never the fake.
          "${FM_FAKE_PANE_SHELL:-bash}" -c "$arg" > "${FM_FAKE_PANE_COUNTFILE}.output" 2>&1
          ;;
      esac
    done
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_test_codex_first_turn_wrap "$fakebin"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "$*" = get ]; then
  printf '%s\n' "$*" >> "${FM_FAKE_PANE_COUNTFILE}.treehouse-calls"
  printf '%s\n' "${FM_FAKE_TREEHOUSE_OUTPUT:-}"
  exit "${FM_FAKE_TREEHOUSE_EXIT:-0}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
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
  printf '999999 0\n' > "$home/config/lane-capacity"
  fm_test_machine_policy "$home/config"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
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
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "${SPAWN_ARGS[@]}" 2>&1
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

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

test_unborn_head_project_is_refused_at_once() {
  local rec id out status started elapsed
  id=settle-unborn-head-z5
  rec=$(make_settle_case settle-unborn "$id" 0)
  read_settle_record "$rec"
  PROJ_DIR="$TMP_ROOT/settle-unborn/unborn-project"
  git init -q "$PROJ_DIR"

  started=$SECONDS
  out=$(run_settle_spawn "$id")
  status=$?
  elapsed=$((SECONDS - started))
  expect_code 1 "$status" "spawn into a project with no commit should be refused"
  assert_contains "$out" "unborn HEAD" "the refusal did not name the unborn HEAD cause"
  assert_contains "$out" "make one commit" "the refusal did not name the remedy"
  [ "$elapsed" -lt 30 ] || fail "refusal took ${elapsed}s instead of failing before the treehouse wait"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  [ -z "$(git -C "$PROJ_DIR" rev-list --all 2>/dev/null)" ] || fail "spawn committed into the project"
  pass "a project with an unborn HEAD is refused at once with its cause named"
}

# Public seam: invoke the real spawn with a backend returning command output
# and a controlled cwd sequence. No-op sleeps make all 60 deadline polls cheap.
test_treehouse_failure_reason() {
  local rec id out status reads
  id=settle-fetch-failed-z6
  rec=$(make_settle_case settle-fetch-failed "$id" 100000)
  read_settle_record "$rec"
  STALE_DIR=$PROJ_DIR
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(FM_FAKE_TREEHOUSE_OUTPUT='fetch failed: git fetch origin: git@github.com: Permission denied (publickey)' \
    FM_FAKE_TREEHOUSE_EXIT=1 FM_FAKE_CAPTURE_TRAILER='__FM_CWD_BEGIN__
/project
__FM_CWD_END__
worker$' run_settle_spawn "$id")
  status=$?
  expect_code 1 "$status" "failed treehouse get must refuse spawn"
  assert_contains "$out" 'fetch failed: git fetch origin: git@github.com: Permission denied (publickey)' "refusal lost treehouse's own error"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 2 ] || fail "failed get took $reads cwd reads instead of two consecutive failure reads"
  assert_contains "$out" 'treehouse get exited before entering an isolated worktree' 'failed get was reported as a timeout'
  pass "treehouse failure refuses after two reads with its own error"
}

test_treehouse_error_while_running_keeps_waiting() {
  local rec id out status reads
  id=settle-running-error-z7
  rec=$(make_settle_case settle-running-error "$id" 100000)
  read_settle_record "$rec"
  STALE_DIR=$PROJ_DIR
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(FM_FAKE_TREEHOUSE_OUTPUT='fetch failed: still retrying inside treehouse' run_settle_spawn "$id")
  status=$?
  expect_code 1 "$status" 'running get should refuse only at deadline'
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 60 ] || fail "running get was cut short after $reads reads"
  assert_contains "$out" 'within 60s' 'running get lost the existing timeout message'
  assert_contains "$out" 'fetch failed: still retrying inside treehouse' 'deadline refusal lost the recent output'
  pass "error output alone never cuts a running get short; deadline includes its reason"
}

test_unreadable_treehouse_pane_keeps_deadline() {
  local rec id out status reads
  id=settle-unreadable-z8
  rec=$(make_settle_case settle-unreadable "$id" 100000)
  read_settle_record "$rec"
  STALE_DIR=$PROJ_DIR
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(FM_FAKE_CAPTURE_UNREADABLE=1 run_settle_spawn "$id")
  status=$?
  expect_code 1 "$status" 'unreadable pane should keep refusal code'
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 60 ] || fail "unreadable pane was cut short after $reads reads"
  assert_contains "$out" 'within 60s' 'unreadable pane lost the existing timeout message'
  assert_contains "$out" 'pane could not be read' 'unreadable pane was silently ignored'
  pass "an unreadable pane keeps the full wait and explains the missing output"
}

test_slow_treehouse_get_still_succeeds() {
  local rec id out status
  id=settle-slow-healthy-z9
  rec=$(make_settle_case settle-slow-healthy "$id" 58)
  read_settle_record "$rec"
  STALE_DIR=$PROJ_DIR
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(FM_FAKE_TREEHOUSE_OUTPUT='Fetching origin...' run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "healthy get that settles on the final poll must succeed"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" 'slow get recorded the wrong worktree'
  pass "healthy get can use the entire wait window"
}

test_failure_reads_must_be_consecutive() {
  local rec id out status reads
  id=settle-interrupted-error-z10
  rec=$(make_settle_case settle-interrupted-error "$id" 100000)
  read_settle_record "$rec"
  STALE_DIR=$PROJ_DIR
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(FM_FAKE_TREEHOUSE_OUTPUT='fetch failed: Permission denied (publickey)' \
    FM_FAKE_TREEHOUSE_EXIT=1 FM_FAKE_CAPTURE_FAIL_ON=2 run_settle_spawn "$id")
  status=$?
  expect_code 1 "$status" 'failed get should refuse after capture recovers'
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 4 ] || fail "capture failure did not restart the two-read proof: $reads reads"
  assert_contains "$out" 'Permission denied (publickey)' 'recovered capture lost the reason'
  pass "an unreadable sample restarts consecutive failure confirmation"
}

test_treehouse_output_bound_and_stale_marker() {
  local rec id out status reads text
  id=settle-bounded-output-z11
  rec=$(make_settle_case settle-bounded-output "$id" 100000)
  read_settle_record "$rec"
  STALE_DIR=$PROJ_DIR
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  text=$(printf '%2000s' x)
  out=$(FM_FAKE_TREEHOUSE_OUTPUT="__FM_TREEHOUSE_GET_EXIT_0__=1
$text
fetch failed: key-role-name Permission denied (publickey)" run_settle_spawn "$id")
  status=$?
  expect_code 1 "$status" 'failed acquisition must refuse at deadline'
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 60 ] || fail "a stale exit marker cut the wait short at $reads reads"
  assert_contains "$out" 'key-role-name Permission denied (publickey)' 'bounded detail changed the printed identity'
  [ "${#out}" -lt 2500 ] || fail "pane output was not bounded (${#out} characters)"
  pass "diagnostics are bounded and an old exit marker cannot end a new get"
}

test_treehouse_probe_backlog_keeps_reason() {
  local rec id out status reads trailer backend i treehouse_status expected_reads
  trailer=$(for backend in ZELLIJ CMUX PASEO; do
    for i in $(seq 1 20); do
      printf '__FM_%s_CWD_BEGIN__\n/project/%s\n__FM_%s_CWD_END__\n' "$backend" "$i" "$backend"
    done
  done)
  [ "$(printf '%s\n' "$trailer" | wc -l)" -gt 80 ] || fail 'fixture needs more than 80 queued probe lines'
  for treehouse_status in 0 1; do
    id="settle-probe-backlog-$treehouse_status-z14"
    rec=$(make_settle_case "settle-probe-backlog-$treehouse_status" "$id" 100000)
    read_settle_record "$rec"
    STALE_DIR=$PROJ_DIR
    fm_test_fake_sleep_noop "$FAKEBIN_DIR"
    out=$(FM_FAKE_TREEHOUSE_OUTPUT='fetch failed: git fetch origin: git@github.com: Permission denied (publickey)' \
      FM_FAKE_TREEHOUSE_EXIT="$treehouse_status" FM_FAKE_CAPTURE_TRAILER="$trailer" run_settle_spawn "$id")
    status=$?
    expect_code 1 "$status" 'acquisition without a worktree must refuse'
    assert_contains "$out" 'fetch failed: git fetch origin: git@github.com: Permission denied (publickey)' 'queued cwd probes hid the Treehouse reason'
    [ "${#out}" -lt 2500 ] || fail "probe backlog made the refusal unbounded (${#out} characters)"
    expected_reads=60
    if [ "$treehouse_status" -ne 0 ]; then
      expected_reads=2
      assert_contains "$out" 'exited before entering an isolated worktree' 'queued cwd probes hid the completion marker'
    else
      assert_contains "$out" 'within 60s' 'probe output without a completion marker cut the wait short'
    fi
    reads=$(cat "$COUNTFILE")
    [ "$reads" -eq "$expected_reads" ] || fail "probe backlog case $treehouse_status took $reads cwd reads, expected $expected_reads"
  done
  pass '180 queued cwd-probe lines preserve early and deadline failure reasons'
}

test_treehouse_failure_real_tmux() (
  local rec id out status real_tmux socket started elapsed
  fm_live_gate default-on FM_SPAWN_TREEHOUSE_REASON_LIVE tmux
  real_tmux=$(command -v tmux)
  socket="fm-treehouse-reason-$$"
  id=settle-real-failure-z12
  rec=$(make_settle_case settle-real-failure "$id" 100000)
  read_settle_record "$rec"
  # Use a private server with an ordinary shell and a fake treehouse binary.
  # This exercises the actual submitted command, terminal rendering and capture
  # without acquiring a pool slot or contacting GitHub.
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'fetch failed: git fetch origin: git@github.com: Permission denied (publickey)\n'
exit 1
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$real_tmux" -f /dev/null -L "$socket" "\$@"
SH
  PATH="$FAKEBIN_DIR:$PATH" "$real_tmux" -f /dev/null -L "$socket" new-session -d -s firstmate -n supervisor 'bash --noprofile --norc' \
    || fail 'could not start private tmux test server'
  "$real_tmux" -L "$socket" set-option -g default-command 'bash --noprofile --norc'
  started=$SECONDS
  out=$(run_settle_spawn "$id")
  status=$?
  elapsed=$((SECONDS - started))
  "$real_tmux" -L "$socket" kill-server
  expect_code 1 "$status" "real tmux failed get should refuse"$'\n'"$out"
  assert_contains "$out" 'fetch failed: git fetch origin: git@github.com: Permission denied (publickey)' 'real pane refusal lost the error'
  assert_contains "$out" 'exited before entering' 'real pane was treated as a timeout'
  [ "$elapsed" -lt 30 ] || fail "real failed get took ${elapsed}s"
  pass "real tmux $($real_tmux -V): shell exit plus captured error refuses in ${elapsed}s"
)

test_treehouse_fish_submission() (
  fm_live_gate default-on FM_SPAWN_TREEHOUSE_REASON_FISH fish
  local rec id out status reads treehouse_status stale_reads
  for treehouse_status in 0 7; do
    stale_reads=58
    [ "$treehouse_status" -eq 0 ] || stale_reads=100000
    id="settle-fish-$treehouse_status-z13"
    rec=$(make_settle_case "settle-fish-$treehouse_status" "$id" "$stale_reads")
    read_settle_record "$rec"
    STALE_DIR=$PROJ_DIR
    fm_test_fake_sleep_noop "$FAKEBIN_DIR"
    out=$(FM_FAKE_PANE_SHELL=fish FM_FAKE_TREEHOUSE_EXIT="$treehouse_status" \
      FM_FAKE_TREEHOUSE_OUTPUT='fetch failed: Permission denied (publickey)' run_settle_spawn "$id")
    status=$?
    grep -Fxq -- 'get' "$COUNTFILE.treehouse-calls" || fail 'fish must execute Treehouse before reporting its outcome'
    reads=$(cat "$COUNTFILE")
    if [ "$treehouse_status" -eq 0 ]; then
      expect_code 0 "$status" "healthy Treehouse acquisition through fish must succeed"$'\n'"$out"
      assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" 'fish spawn recorded the wrong worktree'
      [ "$reads" -eq 61 ] || fail "healthy fish acquisition took $reads cwd reads"
      pass 'fish executes a healthy acquisition without a failure marker'
    else
      expect_code 1 "$status" "failed Treehouse acquisition through fish must refuse"$'\n'"$out"
      assert_contains "$out" 'exited before entering an isolated worktree' 'fish failure was treated as a timeout'
      assert_contains "$out" 'fetch failed: Permission denied (publickey)' 'fish refusal lost the Treehouse error'
      [ "$reads" -eq 2 ] || fail "failed fish acquisition took $reads cwd reads"
      pass 'fish reports a nonzero Treehouse exit promptly with its reason'
    fi
  done
)


EVIDENCE=~/.no-mistakes/evidence/01M6K2PVFHAGDMR9GPE62WEN11
real_tmux=$(command -v tmux)
socket="fm-gate-live-$$"
cleanup_live() {
  "$real_tmux" -L "$socket" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_live EXIT INT TERM
for scenario in running-error unreadable slow-success; do
  id="live-$scenario-z1"
  rec=$(make_settle_case "$scenario" "$id" 100000)
  read_settle_record "$rec"

  SPAWN_ARGS=("$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  [ "$scenario" != scout ] || SPAWN_ARGS=("$id" "$PROJ_DIR" --scout)
  if [ "$scenario" = released ]; then
    head=$(git -C "$PROJ_DIR" rev-parse HEAD)
    cat > "$HOME_DIR/state/$id.meta" <<META
window=firstmate:fm-$id
endpoint_task_id=$id
worktree=$HOME_DIR/state/$id.released-copy
released_head=$head
released_branch=fm/$id
released_pr=https://github.com/example/repo/pull/7
project=$PROJ_DIR
harness=codex
backend=tmux
kind=ship
mode=no-mistakes
yolo=off
branch=fm/$id
model=default
effort=default
spawn_gen=s1.1.1
META
    cat > "$FAKEBIN_DIR/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-} \${2:-}" = 'api graphql' ]; then
  printf 'state=OPEN\\nmerged=false\\nhead=$head\\nhead_path=example/repo\\nhead_branch=fm/$id\\n'
  exit 0
fi
exit 1
SH
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$FAKEBIN_DIR/gh-axi"
    chmod +x "$FAKEBIN_DIR/gh" "$FAKEBIN_DIR/gh-axi"
    SPAWN_ARGS=("$id" --relaunch)
  fi
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'fetch failed: git fetch origin: git@github.com: Permission denied (publickey)\n'
exit 1
SH
  case "$scenario" in
    running-error)
      printf '%s\n' '#!/usr/bin/env bash' "printf '__FM_TREEHOUSE_GET_EXIT_0__=1\\nfetch failed: still retrying inside treehouse\\n'" 'sleep 90' 'exit 1' > "$FAKEBIN_DIR/treehouse" ;;
    unreadable)
      printf '%s\n' '#!/usr/bin/env bash' 'sleep 90' > "$FAKEBIN_DIR/treehouse" ;;
  esac
  chmod +x "$FAKEBIN_DIR/treehouse"
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/usr/bin/env bash
printf '• Working (1s • esc to interrupt)\n'
sleep 120
SH
  chmod +x "$FAKEBIN_DIR/codex"
  real_sleep=$(command -v sleep)
  cat > "$FAKEBIN_DIR/sleep" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$(date +%s.%N)" "\$*" >> "$EVIDENCE/sleeps-$scenario.txt"
exec "$real_sleep" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/sleep"
  cat > "$FAKEBIN_DIR/pane.rc" <<'SH'
PS1='lab$ '
SH
  if [ "$scenario" = slow-success ]; then
    cat >> "$FAKEBIN_DIR/pane.rc" <<SH
treehouse() { printf 'Fetching origin...\\n'; sleep 55; cd '$WT_DIR'; }
SH
  fi

  export LIVE_REAL_TMUX="$real_tmux" LIVE_SOCKET="$socket" LIVE_SCENARIO="$scenario" LIVE_EVIDENCE="$EVIDENCE"
  cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$(date +%s.%N)" >> "$LIVE_EVIDENCE/polls-$LIVE_SCENARIO.txt" ;;
esac
if [ "$LIVE_SCENARIO" = unreadable ] && [ "${1:-}" = capture-pane ]; then exit 1; fi
if [ "${1:-}" = capture-pane ]; then
  "$LIVE_REAL_TMUX" -f /dev/null -L "$LIVE_SOCKET" "$@" | tee "$LIVE_EVIDENCE/pane-$LIVE_SCENARIO.txt"
  exit "${PIPESTATUS[0]}"
fi
"$LIVE_REAL_TMUX" -f /dev/null -L "$LIVE_SOCKET" "$@"
result=$?
if [ "$LIVE_SCENARIO" = backlog ] && [ "${1:-}" = send-keys ]; then
  previous= target=
  for arg in "$@"; do
    [ "$previous" != -t ] || target=$arg
    previous=$arg
  done
  for arg in "$@"; do
    case "$arg" in
      'treehouse get'*)
        "$LIVE_REAL_TMUX" -L "$LIVE_SOCKET" send-keys -t "$target" 'for i in $(seq 1 60); do printf "__FM_CMUX_CWD_BEGIN__\n/project/$i\n__FM_CMUX_CWD_END__\n"; done' Enter || exit 1 ;;
    esac
  done
fi
exit "$result"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  PATH="$FAKEBIN_DIR:$PATH" "$real_tmux" -f /dev/null -L "$socket" new-session -d -x 240 -y 40 -s firstmate -n supervisor 'bash --noprofile --norc' || fail 'private server startup'
  "$real_tmux" -L "$socket" set-option -g default-command "bash --noprofile --rcfile '$FAKEBIN_DIR/pane.rc' -i"
  "$real_tmux" -L "$socket" set-option -g history-limit 5000
  "$real_tmux" -L "$socket" set-environment -g PATH "$FAKEBIN_DIR:$PATH"
  started=$SECONDS
  out=$(run_settle_spawn "$id")
  status=$?
  elapsed=$((SECONDS-started))
  {
    printf 'Scenario: %s\nBackend: ' "$scenario"
    "$real_tmux" -V
    printf 'Command: bin/fm-spawn.sh %s <disposable-project> --mode no-mistakes --yolo off\nExit: %s\nElapsed: %ss\n%s\n' "$id" "$status" "$elapsed" "$out"
    printf '\nActual pane transcript (last acquisition capture before cleanup):\n'
    [ ! -f "$EVIDENCE/pane-$scenario.txt" ] || cat "$EVIDENCE/pane-$scenario.txt"
    if [ -f "$HOME_DIR/state/$id.meta" ]; then
      printf '\nPersisted worktree:\n'
      sed -n '/^worktree=/p' "$HOME_DIR/state/$id.meta"
    fi
  } > "$EVIDENCE/live-$scenario.txt"
  "$real_tmux" -L "$socket" kill-server || fail 'private server cleanup'
  case "$scenario" in
    failure|backlog|scout|released)
      expected=1
      [ "$scenario" != released ] || expected=75
      expect_code "$expected" "$status" "$scenario must refuse"
      assert_contains "$out" 'exited before entering an isolated worktree' 'failure must be early'
      assert_contains "$out" 'Permission denied (publickey)' 'must retain cause'
      [ "$elapsed" -lt 30 ] || fail 'failure waited too long'
      [ "${#out}" -lt 2500 ] || fail 'unbounded refusal'
      if [ "$scenario" = backlog ]; then
        count=$(grep -c '^__FM_CMUX_CWD_' "$EVIDENCE/pane-$scenario.txt")
        [ "$count" -ge 120 ] || fail "real queued probes missing: $count boundary lines"
      fi ;;
    running-error|unreadable)
      expect_code 1 "$status" "$scenario must refuse"
      assert_contains "$out" 'within 60s' 'must retain full wait'
      polls=$(wc -l < "$EVIDENCE/polls-$scenario.txt")
      [ "$polls" -eq 60 ] || fail "wait was shortened: $polls polls"
      sleeps=$(grep -c ' 1$' "$EVIDENCE/sleeps-$scenario.txt")
      [ "$sleeps" -eq 60 ] || fail "wait was shortened: $sleeps one-second sleeps"
      if [ "$scenario" = running-error ]; then
        assert_contains "$out" 'still retrying inside treehouse' 'deadline must include output'
      else
        assert_contains "$out" 'pane could not be read' 'must explain unreadable capture'
      fi ;;
    slow-success)
      expect_code 0 "$status" 'healthy slow acquisition must succeed'
      assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" 'must record isolated worktree' ;;
  esac
  pass "LIVE $scenario: exit=$status elapsed=${elapsed}s"
done
