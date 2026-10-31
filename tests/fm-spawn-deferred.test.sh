#!/usr/bin/env bash
# A spawn deferred because the machine has no free lane is recorded and
# retried, oldest first, when a later sweep sees a free lane.
# Cases drive bin/fm-spawn-deferred.sh record and sweep with a fake capacity
# command and a fake spawn program. One case drives the real fm-spawn.sh
# against an isolated home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT_BIN="$ROOT/bin/fm-spawn-deferred.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-deferred)
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

write_tools() { # <case-dir>
  local dir=$1
  cat > "$dir/capacity" <<'SH'
#!/usr/bin/env bash
n=$(cat "${FM_SPAWN_DEFERRED_FREE_FILE:?}")
printf 'capacity: free_lanes=%s reason=ok lanes=0 target=%s load1=0 cores=1 mem_free_pct=50 disk_free_mb=1 mem_available_kb=1 reserve_kb=0 headroom_kb=1\n' "$n" "$n"
exit 0
SH
  cat > "$dir/spawn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_DEFERRED_TEST_LOG:?}"
if [ -n "${FM_DEFERRED_SLEEP_ID:-}" ] && [ "$1" = "$FM_DEFERRED_SLEEP_ID" ]; then
  printf '%s\n' "$$" > "${FM_DEFERRED_TEST_LOG}.child"
  sleep 30
fi
exit 0
SH
  chmod 755 "$dir/capacity" "$dir/spawn"
}

make_home() { # <home> [task-id...]
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf 'codex\n' > "$home/config/crew-harness"
  printf '99 0\n' > "$home/config/lane-capacity"
  fm_test_machine_policy "$home/config"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
    for id in "$@"; do
      tasks-axi add "$id" "item for $id" --kind ship --file "$home/data/backlog.md" >/dev/null
    done
  fi
}

record_task() { # <home> <case-dir> <id>
  local home=$1 case_dir=$2 id=$3
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT_BIN" record "$id" -- "$case_dir/spawn" "$id"
}

sweep_home() { # <home> <case-dir>
  local home=$1 case_dir=$2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_DEFERRED_SYNC=1 \
    FM_SPAWN_DEFERRED_CAPACITY_BIN="$case_dir/capacity" \
    FM_SPAWN_DEFERRED_FREE_FILE="$case_dir/free" \
    FM_DEFERRED_TEST_LOG="$case_dir/spawn.log" \
    "$ROOT_BIN" sweep
}

queue_has() { # <home> <id>
  local home=$1 id=$2 f task
  for f in "$home"/state/spawn-deferred/queue/*; do
    [ -f "$f" ] || continue
    task=$(sed -n 's/^task=//p' "$f" | head -1)
    [ "$task" = "$id" ] && return 0
  done
  return 1
}

new_case() { # <name> <ids...>
  local name=$1 case_dir
  shift
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  write_tools "$case_dir"
  : > "$case_dir/spawn.log"
  printf '0\n' > "$case_dir/free"
  make_home "$case_dir/home" "$@"
  printf '%s\n' "$case_dir"
}

require_tasks() {
  [ "$HAVE_TASKS_AXI" = 1 ] || {
    printf 'ok - skipped (tasks-axi is not installed)\n'
    return 1
  }
}

test_oldest_and_one_per_free_lane() {
  local case_dir home out
  require_tasks || return 0
  case_dir=$(new_case oldest a-one b-two c-three)
  home="$case_dir/home"
  record_task "$home" "$case_dir" a-one
  record_task "$home" "$case_dir" b-two
  record_task "$home" "$case_dir" c-three
  printf '1\n' > "$case_dir/free"
  out=$(sweep_home "$home" "$case_dir")
  assert_contains "$out" "started a-one" "the oldest deferred request did not start"
  assert_not_contains "$out" "started b-two" "a younger request started while only one lane was free"
  assert_not_contains "$out" "started c-three" "a third request started while only one lane was free"
  assert_equals "a-one" "$(cat "$case_dir/spawn.log")" "the spawn log was not the oldest task alone"
  queue_has "$home" a-one && fail "a started request stayed queued"
  queue_has "$home" b-two || fail "the younger request was dropped"
  queue_has "$home" c-three || fail "the youngest request was dropped"
  printf '2\n' > "$case_dir/free"
  out=$(sweep_home "$home" "$case_dir")
  assert_contains "$out" "started b-two" "the next oldest request did not start"
  assert_contains "$out" "started c-three" "the second free lane did not start the next request"
  assert_equals "$(printf '%s\n' a-one b-two c-three)" "$(cat "$case_dir/spawn.log")" \
    "two free lanes did not start the two oldest remaining requests in order"
  pass "oldest deferred request starts first, one start per free lane"
}

test_no_double_start() {
  local case_dir home out
  require_tasks || return 0
  case_dir=$(new_case once only-one)
  home="$case_dir/home"
  record_task "$home" "$case_dir" only-one
  printf '1\n' > "$case_dir/free"
  sweep_home "$home" "$case_dir" >/dev/null
  sweep_home "$home" "$case_dir" >/dev/null
  assert_equals "only-one" "$(cat "$case_dir/spawn.log")" "a second sweep started the same request again"
  queue_has "$home" only-one && fail "a finished request was recorded again"
  pass "a finished deferred request is not started twice"
}

test_in_progress_claim_consumes_the_lane() {
  local case_dir home first=0 i
  require_tasks || return 0
  case_dir=$(new_case claim sleep-one next-one)
  home="$case_dir/home"
  record_task "$home" "$case_dir" sleep-one
  record_task "$home" "$case_dir" next-one
  printf '1\n' > "$case_dir/free"
  set +m
  FM_DEFERRED_SLEEP_ID=sleep-one sweep_home "$home" "$case_dir" >/dev/null &
  first=$!
  i=0
  while [ ! -s "$case_dir/spawn.log.child" ]; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || fail "the in-progress spawn did not reach its wait"
    sleep 0.05
  done
  sweep_home "$home" "$case_dir" >/dev/null
  assert_equals "sleep-one" "$(cat "$case_dir/spawn.log")" \
    "a second sweep started another request while the free lane was already claimed"
  queue_has "$home" next-one || fail "the waiting request was dropped while a claim was in progress"
  kill "$(cat "$case_dir/spawn.log.child")" "$first" 2>/dev/null || true
  wait "$first" 2>/dev/null || true
  set -m
  pass "an in-progress claim consumes the free lane"
}

test_held_task_is_skipped() {
  local case_dir home out
  require_tasks || return 0
  case_dir=$(new_case held held-one young-one)
  home="$case_dir/home"
  record_task "$home" "$case_dir" held-one
  record_task "$home" "$case_dir" young-one
  tasks-axi hold held-one --reason "captain decision pending" --kind captain \
    --file "$home/data/backlog.md" >/dev/null
  printf '1\n' > "$case_dir/free"
  out=$(sweep_home "$home" "$case_dir")
  assert_not_contains "$out" "started held-one" "a held task was started"
  assert_contains "$out" "started young-one" "a held older task blocked a younger queued task"
  assert_equals "young-one" "$(cat "$case_dir/spawn.log")" "the spawn log included the held task"
  queue_has "$home" held-one || fail "the held request was removed"
  pass "a held task stays queued and does not take the free lane"
}

test_stale_request_is_reported() {
  local case_dir home out f
  require_tasks || return 0
  case_dir=$(new_case stale stale-one)
  home="$case_dir/home"
  record_task "$home" "$case_dir" stale-one
  f=$(find "$home/state/spawn-deferred/queue" -type f -print | head -1)
  [ -n "$f" ] || fail "the deferred request was not recorded"
  sed -i 's/^argv_sha256=.*/argv_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$f"
  printf '1\n' > "$case_dir/free"
  out=$(sweep_home "$home" "$case_dir")
  assert_contains "$out" "stale stale-one" "a tampered request was not reported stale"
  assert_equals "" "$(cat "$case_dir/spawn.log")" "a stale request was executed"
  queue_has "$home" stale-one && fail "a stale request was left queued"
  pass "a stale deferred request is reported and not started"
}

test_closed_rows_are_removed_without_a_start() {
  local case_dir home
  require_tasks || return 0
  case_dir=$(new_case closed fly-one done-one gone-one)
  home="$case_dir/home"
  record_task "$home" "$case_dir" fly-one
  record_task "$home" "$case_dir" done-one
  record_task "$home" "$case_dir" gone-one
  tasks-axi start fly-one --file "$home/data/backlog.md" >/dev/null
  tasks-axi start done-one --file "$home/data/backlog.md" >/dev/null
  tasks-axi done done-one --file "$home/data/backlog.md" >/dev/null
  tasks-axi rm gone-one --file "$home/data/backlog.md" >/dev/null
  printf '3\n' > "$case_dir/free"
  sweep_home "$home" "$case_dir" >/dev/null
  assert_equals "" "$(cat "$case_dir/spawn.log")" "a task that is not queued was started"
  queue_has "$home" fly-one && fail "an in-flight request was kept"
  queue_has "$home" done-one && fail "a done request was kept"
  queue_has "$home" gone-one && fail "a missing request was kept"
  pass "in-flight, done, and missing tasks are removed without a start"
}

test_seat_already_held_is_skipped() {
  local case_dir home
  require_tasks || return 0
  case_dir=$(new_case seat seat-one)
  home="$case_dir/home"
  record_task "$home" "$case_dir" seat-one
  fm_write_meta "$home/state/seat-one.meta" \
    "window=firstmate:fm-seat-one" \
    "endpoint_task_id=seat-one" \
    "worktree=$home/absent-worktree-seat-one" \
    "project=$case_dir" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s-seat-one"
  printf '1\n' > "$case_dir/free"
  sweep_home "$home" "$case_dir" >/dev/null
  assert_equals "" "$(cat "$case_dir/spawn.log")" "a task that already holds a seat was started"
  queue_has "$home" seat-one || fail "a seated request was removed while it was still queued"
  pass "a queued task that already holds a seat is left for the next sweep"
}

test_busy_lock_starts_nothing() {
  local case_dir home out holder=0 i
  require_tasks || return 0
  case_dir=$(new_case lock lock-one)
  home="$case_dir/home"
  record_task "$home" "$case_dir" lock-one
  printf '1\n' > "$case_dir/free"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
    # shellcheck source=bin/fm-wake-lib.sh
    . "'"$ROOT"'/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$STATE/.spawn-deferred.lock"
    printf "%s\n" "$$" > "'"$case_dir"'/holder.pid"
    while [ ! -f "'"$case_dir"'/holder.release" ]; do
      sleep 0.05
    done
    fm_lock_release "$STATE/.spawn-deferred.lock"
  ' >/dev/null 2>&1 &
  holder=$!
  i=0
  while [ ! -s "$case_dir/holder.pid" ]; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || fail "the lock holder did not take the lock"
    sleep 0.05
  done
  out=$(sweep_home "$home" "$case_dir")
  assert_equals "" "$out" "a sweep whose lock was busy produced a report"
  assert_equals "" "$(cat "$case_dir/spawn.log")" "a sweep whose lock was busy started a request"
  queue_has "$home" lock-one || fail "a busy sweep dropped the queued request"
  : > "$case_dir/holder.release"
  wait "$holder" || true
  pass "a sweep with a busy lock starts nothing"
}

write_brief() { # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Run the deferred retry proof for $2.

## Firstmate spec
Exercise machine admission retry.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
}

install_real_fakes() { # <case-dir>
  local case_dir=$1 fakebin
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
window_file="$FM_FAKE_CALL_LOG.window"
case "$*" in
  *"#{pane_current_command}"*) printf 'codex\n'; exit 0 ;;
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file" ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    grep -Fqx -- "$name" "$window_file" 2>/dev/null || printf '%s\n' "$name" >> "$window_file"
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  printf '%s\n' "$fakebin"
}

test_real_spawn_starts_after_a_lane_frees() {
  local case_dir home fakebin project out rc=0 began ended elapsed proof
  require_tasks || return 0
  case_dir=$(new_case real-lane)
  home="$case_dir/home"
  fakebin=$(install_real_fakes "$case_dir")
  project="$case_dir/project"
  fm_git_init_commit "$project"
  fm_git_add_origin "$project" "$case_dir/project.origin.git"
  git -C "$project" worktree add --quiet -b wt-retry "$case_dir/wt-retry"
  write_brief "$home" occupant
  write_brief "$home" retry-one
  tasks-axi add occupant "occupant" --kind ship --file "$home/data/backlog.md" >/dev/null
  tasks-axi add retry-one "retry" --kind ship --file "$home/data/backlog.md" >/dev/null
  tasks-axi start occupant --file "$home/data/backlog.md" >/dev/null
  printf '1 3\n' > "$home/config/lane-capacity"
  fm_write_meta "$home/state/occupant.meta" \
    "window=firstmate:fm-occupant" \
    "endpoint_task_id=occupant" \
    "worktree=$home/absent-worktree-occupant" \
    "project=$project" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s-occupant"
  rc=0
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$case_dir/wt-retry" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" retry-one "$project" --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -eq 75 ] || fail "the occupied machine did not defer the spawn (exit $rc): $out"
  queue_has "$home" retry-one || fail "the real deferred spawn was not recorded"
  rm -f -- "$home/state/occupant.meta"
  began=$(date +%s)
  rc=0
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$case_dir/wt-retry" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    FM_SPAWN_DEFERRED_SYNC=1 \
    PATH="$fakebin:$PATH" \
    "$ROOT_BIN" sweep 2>&1) || rc=$?
  ended=$(date +%s)
  elapsed=$((ended - began))
  [ "$rc" -eq 0 ] || fail "the retry sweep failed (exit $rc): $out"
  assert_contains "$out" "started retry-one" "the deferred task did not start after the lane freed"
  [ -f "$home/state/retry-one.meta" ] || fail "the retried spawn did not publish a task record: $out"
  queue_has "$home" retry-one && fail "the started request was left queued"
  [ "$elapsed" -lt 300 ] || fail "the retry took ${elapsed}s, which is not within five minutes"
  proof=${FM_SPAWN_DEFERRED_PROOF_DIR:-}
  if [ -n "$proof" ]; then
    mkdir -p "$proof"
    cat > "$proof/proof.txt" <<EOF
isolated_home=$home
defer_command=FM_HOME=$home FM_SPAWN_NO_GUARD=1 TMUX=fake,1,0 FM_BACKEND=tmux PATH=$fakebin:\$PATH $SPAWN retry-one $project --mode no-mistakes --yolo off
defer_exit=75
defer_record=state/spawn-deferred/queue task=retry-one
lane_free_command=rm -f $home/state/occupant.meta
lane_freed_epoch=$began
retry_command=FM_HOME=$home FM_SPAWN_NO_GUARD=1 TMUX=fake,1,0 FM_BACKEND=tmux FM_SPAWN_DEFERRED_SYNC=1 PATH=$fakebin:\$PATH $ROOT_BIN sweep
retry_finished_epoch=$ended
elapsed_s=$elapsed
sweep_exit=$rc
sweep_output:
$out
task_record=$home/state/retry-one.meta
EOF
  fi
  pass "a deferred spawn starts within five minutes of a lane freeing (${elapsed}s)"
}

test_oldest_and_one_per_free_lane
test_no_double_start
test_in_progress_claim_consumes_the_lane
test_held_task_is_skipped
test_stale_request_is_reported
test_closed_rows_are_removed_without_a_start
test_seat_already_held_is_skipped
test_busy_lock_starts_nothing
test_real_spawn_starts_after_a_lane_frees
