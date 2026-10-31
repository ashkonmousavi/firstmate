#!/usr/bin/env bash
# A spawn deferred because the machine has no free lane is recorded and
# retried, oldest first, when a later sweep sees a free lane.
# Cases drive bin/fm-spawn-deferred.sh record, retry, and sweep with a fake
# capacity command and a fake spawn program, and drive the real fm-spawn.sh
# against isolated homes.
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
  while [ ! -f "${FM_DEFERRED_TEST_LOG}.release" ]; do sleep 0.05; done
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

deferred_home() { # <action> <home> <case-dir>
  local action=$1 home=$2 case_dir=$3
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_DEFERRED_CAPACITY_BIN="$case_dir/capacity" \
    FM_SPAWN_DEFERRED_FREE_FILE="$case_dir/free" \
    FM_DEFERRED_TEST_LOG="$case_dir/spawn.log" \
    "$ROOT_BIN" "$action"
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
  out=$(deferred_home retry "$home" "$case_dir")
  assert_contains "$out" "started a-one" "the oldest deferred request did not start"
  assert_not_contains "$out" "started b-two" "a younger request started while only one lane was free"
  assert_not_contains "$out" "started c-three" "a third request started while only one lane was free"
  assert_equals "a-one" "$(cat "$case_dir/spawn.log")" "the spawn log was not the oldest task alone"
  queue_has "$home" a-one && fail "a started request stayed queued"
  queue_has "$home" b-two || fail "the younger request was dropped"
  queue_has "$home" c-three || fail "the youngest request was dropped"
  printf '2\n' > "$case_dir/free"
  out=$(deferred_home retry "$home" "$case_dir")
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
  deferred_home retry "$home" "$case_dir" >/dev/null
  deferred_home retry "$home" "$case_dir" >/dev/null
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
  printf '2\n' > "$case_dir/free"
  set +m
  FM_DEFERRED_SLEEP_ID=sleep-one deferred_home retry "$home" "$case_dir" >/dev/null &
  first=$!
  i=0
  while [ ! -s "$case_dir/spawn.log.child" ]; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || fail "the in-progress spawn did not reach its wait"
    sleep 0.05
  done
  deferred_home retry "$home" "$case_dir" >/dev/null
  assert_equals "sleep-one" "$(cat "$case_dir/spawn.log")" \
    "a second sweep started another request while the free lane was already claimed"
  queue_has "$home" next-one || fail "the waiting request was dropped while a claim was in progress"
  : > "$case_dir/spawn.log.release"
  wait "$first" || fail "the original sweep did not finish its serial retries"
  assert_equals "$(printf '%s\n' sleep-one next-one)" "$(cat "$case_dir/spawn.log")" \
    "the original sweep did not continue with the next request"
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
  out=$(deferred_home retry "$home" "$case_dir")
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
  out=$(deferred_home retry "$home" "$case_dir")
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
  deferred_home retry "$home" "$case_dir" >/dev/null
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
  deferred_home retry "$home" "$case_dir" >/dev/null
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
  out=$(deferred_home sweep "$home" "$case_dir")
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

real_command() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$case_dir/wt-retry" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" "$@"
}

wait_for_task_completion() {
  local home=$1 id=$2 i f active
  for ((i=0; i<200; i++)); do
    active=0
    for f in "$home"/state/spawn-deferred/claim/*; do
      [ -f "$f" ] || continue
      [ "$(sed -n 's/^task=//p' "$f" | head -1)" != "$id" ] || active=1
    done
    if ! queue_has "$home" "$id" && [ "$active" -eq 0 ]; then
      return 0
    fi
    sleep 0.05
  done
  fail "the detached retry of $id did not complete"
}

test_real_spawn_starts_after_a_lane_frees() {
  local variant=${1:-ship} case_dir home fakebin project out rc=0 began ended elapsed proof
  local args=() projects_override= retry_backend=tmux expected_kind=ship
  require_tasks || return 0
  case_dir=$(new_case "real-lane-$variant")
  home="$case_dir/home"
  fakebin=$(install_real_fakes "$case_dir")
  project="$case_dir/project"
  if [ "$variant" = pinned ]; then
    projects_override="$case_dir/selected-projects"
    project="$projects_override/demo"
  fi
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
  case "$variant" in
    ship) args=(retry-one "$project" --mode no-mistakes --yolo off) ;;
    scout) args=(--scout retry-one "$project"); expected_kind=scout ;;
    flags) args=(--harness codex --mode=no-mistakes --yolo off --backend=tmux retry-one "$project") ;;
    pinned)
      mkdir -p "$home/projects"
      fm_git_init_commit "$home/projects/demo"
      args=(retry-one projects/demo --mode no-mistakes --yolo off)
      retry_backend=orca
      ;;
  esac
  rc=0
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE="$projects_override" FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$case_dir/wt-retry" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "${args[@]}" 2>&1) || rc=$?
  [ "$rc" -eq 75 ] || fail "the occupied machine did not defer the spawn (exit $rc): $out"
  queue_has "$home" retry-one || fail "the real deferred spawn was not recorded"
  rm -f -- "$home/state/occupant.meta"
  began=$(date +%s)
  rc=0
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND="$retry_backend" \
    FM_FAKE_PANE_PATH="$case_dir/wt-retry" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$fakebin:$PATH" \
    "$ROOT_BIN" sweep 2>&1) || rc=$?
  wait_for_task_completion "$home" retry-one
  out="$out$(real_command "$case_dir" "$ROOT_BIN" sweep)"
  ended=$(date +%s)
  elapsed=$((ended - began))
  [ "$rc" -eq 0 ] || fail "the retry sweep failed (exit $rc): $out"
  assert_contains "$out" "started retry-one" "the deferred task did not start after the lane freed"
  [ -f "$home/state/retry-one.meta" ] || fail "the retried spawn did not publish a task record: $out"
  queue_has "$home" retry-one && fail "the started request was left queued"
  assert_equals "$expected_kind" "$(sed -n 's/^kind=//p' "$home/state/retry-one.meta")" "retry changed the worker kind"
  assert_equals "$project" "$(sed -n 's/^project=//p' "$home/state/retry-one.meta")" "retry followed a different projects directory"
  assert_equals "" "$(sed -n 's/^backend=//p' "$home/state/retry-one.meta")" "retry followed the sweep backend instead of the recorded tmux backend"
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
retry_command=FM_HOME=$home FM_SPAWN_NO_GUARD=1 TMUX=fake,1,0 FM_BACKEND=tmux PATH=$fakebin:\$PATH $ROOT_BIN sweep
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

test_retries_are_serial() {
  local case_dir home out
  require_tasks || return 0
  case_dir=$(new_case serial first-one second-one)
  home="$case_dir/home"
  cat > "$case_dir/spawn" <<'SH'
#!/usr/bin/env bash
if ! mkdir "${FM_DEFERRED_TEST_LOG}.lock" 2>/dev/null; then
  printf 'overlap\n' >> "$FM_DEFERRED_TEST_LOG"
  exit 1
fi
printf '%s begin\n' "$1" >> "$FM_DEFERRED_TEST_LOG"
sleep 0.2
printf '%s end\n' "$1" >> "$FM_DEFERRED_TEST_LOG"
rmdir "${FM_DEFERRED_TEST_LOG}.lock"
SH
  record_task "$home" "$case_dir" first-one
  record_task "$home" "$case_dir" second-one
  printf '2\n' > "$case_dir/free"
  out=$(deferred_home retry "$home" "$case_dir")
  assert_contains "$out" "started second-one" "the second serial retry did not start"
  assert_equals "$(printf '%s\n' 'first-one begin' 'first-one end' 'second-one begin' 'second-one end')" \
    "$(cat "$case_dir/spawn.log")" "retries overlapped or ran out of order"
  queue_has "$home" first-one && fail "the first retry stayed queued"
  queue_has "$home" second-one && fail "the second retry stayed queued"
  pass "retries complete serially in deferred order"
}

test_refusal_preserves_launch_budget() {
  local case_dir home out rc
  require_tasks || return 0
  for rc in 75 1; do
    case_dir=$(new_case "refusal-$rc" blocked-one ready-one third-one)
    home="$case_dir/home"
    cat > "$case_dir/spawn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_DEFERRED_TEST_LOG"
if [ "$1" = blocked-one ]; then
  if [ "$FM_DEFERRED_TEST_RC" = 75 ]; then
    "${FM_DEFERRED_TEST_BIN:?}" record "$1" -- "$0" "$1" || exit 1
  fi
  exit "$FM_DEFERRED_TEST_RC"
fi
exit 0
SH
    record_task "$home" "$case_dir" blocked-one
    record_task "$home" "$case_dir" ready-one
    record_task "$home" "$case_dir" third-one
    printf '1\n' > "$case_dir/free"
    out=$(FM_DEFERRED_TEST_RC="$rc" FM_DEFERRED_TEST_BIN="$ROOT_BIN" deferred_home retry "$home" "$case_dir")
    assert_contains "$out" "started ready-one" "the younger request was not launched after refusal"
    assert_not_contains "$out" "started blocked-one" "a refused request was reported as started"
    assert_equals "$(printf '%s\n' blocked-one ready-one)" "$(cat "$case_dir/spawn.log")" \
      "exit $rc consumed the lane or prevented the younger ready task from starting"
    queue_has "$home" blocked-one || fail "the refused request lost its queue record"
    queue_has "$home" ready-one && fail "the successful younger request stayed queued"
    queue_has "$home" third-one || fail "a launch exceeded the successful-launch budget"
    out=$(FM_DEFERRED_TEST_RC="$rc" FM_DEFERRED_TEST_BIN="$ROOT_BIN" deferred_home retry "$home" "$case_dir")
    if [ "$rc" -eq 1 ]; then
      assert_equals "$(printf '%s\n' blocked-one ready-one third-one)" "$(cat "$case_dir/spawn.log")" "a permanent failure was attempted again"
    else
      assert_equals "$(printf '%s\n' blocked-one ready-one blocked-one third-one)" "$(cat "$case_dir/spawn.log")" "a temporary refusal stopped being retryable"
    fi
  done
  pass "refused retries leave the free lane for younger ready work"
}

test_argument_bytes_survive_retry() {
  local case_dir home out
  require_tasks || return 0
  case_dir=$(new_case argument-bytes bytes-one)
  home="$case_dir/home"
  cat > "$case_dir/spawn" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${FM_DEFERRED_TEST_LOG}.argv"
SH
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT_BIN" record bytes-one -- "$case_dir/spawn" bytes-one '' $'\n' $'printf hello\n\n' trailing-x
  printf '%s\0' bytes-one '' $'\n' $'printf hello\n\n' trailing-x > "$case_dir/expected.argv"
  printf '1\n' > "$case_dir/free"
  out=$(deferred_home retry "$home" "$case_dir")
  [ -f "$case_dir/spawn.log.argv" ] || fail "the byte-preserving request was discarded instead of executed: $out"
  cmp -s "$case_dir/expected.argv" "$case_dir/spawn.log.argv" || fail "retry changed the argument bytes"
  queue_has "$home" bytes-one && fail "the byte-preserving request stayed queued after success"
  pass "retry preserves empty arguments and trailing newlines"
}

test_sweep_returns_while_spawn_is_hung() {
  local case_dir home first i out
  require_tasks || return 0
  case_dir=$(new_case detached sleep-one next-one)
  home="$case_dir/home"
  record_task "$home" "$case_dir" sleep-one
  record_task "$home" "$case_dir" next-one
  printf '2\n' > "$case_dir/free"
  (
    FM_DEFERRED_SLEEP_ID=sleep-one deferred_home sweep "$home" "$case_dir" > "$case_dir/sweep.out"
    : > "$case_dir/returned"
  ) &
  first=$!
  for ((i=0; i<100; i++)); do
    [ ! -f "$case_dir/returned" ] || [ ! -s "$case_dir/spawn.log.child" ] || break
    sleep 0.05
  done
  if [ ! -f "$case_dir/returned" ]; then
    : > "$case_dir/spawn.log.release"
    wait "$first" || true
    fail "the watcher-facing sweep waited for the hung spawn"
  fi
  wait "$first" || fail "the detached sweep failed"
  [ -s "$case_dir/spawn.log.child" ] || fail "the detached spawn did not reach its wait"
  kill -0 "$(cat "$case_dir/spawn.log.child")" 2>/dev/null || fail "the spawn was not still running when sweep returned"
  assert_not_contains "$(cat "$case_dir/sweep.out")" "started sleep-one" "the hung attempt was reported as started"
  out=$(deferred_home sweep "$home" "$case_dir")
  assert_equals "sleep-one" "$(cat "$case_dir/spawn.log")" "overlapping sweeps ran concurrent retries"
  assert_not_contains "$out" "started sleep-one" "an overlapping sweep reported an unfinished launch"
  : > "$case_dir/spawn.log.release"
  wait_for_task_completion "$home" next-one
  out=$(deferred_home sweep "$home" "$case_dir")
  assert_equals "$(printf '%s\n' 'started sleep-one' 'started next-one')" "$out" "completed launches were not reported in order"
  assert_equals "" "$(deferred_home sweep "$home" "$case_dir")" "completed launches were reported twice"
  pass "the sweep returns during a hung spawn and reports completed launches once"
}

test_only_full_machine_refusals_are_recorded() {
  local case_dir home project fakebin out rc reason
  require_tasks || return 0
  for reason in memory unreadable pressure disk config; do
    case_dir=$(new_case "not-full-$reason" retry-one)
    home="$case_dir/home"
    project="$case_dir/project"
    fm_git_init_commit "$project"
    fakebin=$(install_real_fakes "$case_dir")
    write_brief "$home" retry-one
    printf '5 3\n' > "$home/config/lane-capacity"
    cp "$FM_CAPACITY_MEMINFO" "$case_dir/meminfo"
    cp "$FM_CAPACITY_PRESSURE_FILE" "$case_dir/pressure"
    case "$reason" in
      memory) printf 'MemAvailable: 1 kB\n' > "$case_dir/meminfo" ;;
      unreadable) printf 'MemAvailable: unknown kB\n' > "$case_dir/meminfo" ;;
      pressure) printf 'full avg10=0.00 avg60=100.00 avg300=0.00 total=0\n' > "$case_dir/pressure" ;;
      disk) jq '.disk_floor_gib=1000000000' "$home/config/machine-admission.json" > "$case_dir/policy"; mv "$case_dir/policy" "$home/config/machine-admission.json" ;;
      config) printf 'broken\n' > "$home/config/lane-capacity" ;;
    esac
    rc=0
    out=$(FM_CAPACITY_MEMINFO="${case_dir}/meminfo" \
      FM_CAPACITY_PRESSURE_FILE="${case_dir}/pressure" \
      PATH="$fakebin:$PATH" real_command "$case_dir" "$SPAWN" retry-one "$project" --mode no-mistakes --yolo off 2>&1) || rc=$?
    [ "$rc" -eq 75 ] || fail "$reason was not an admission refusal (exit $rc): $out"
    case "$reason" in
      memory) assert_contains "$out" "headroom=-" "the low-memory fixture did not reach memory admission" ;;
      unreadable) assert_contains "$out" "$case_dir/meminfo" "the unreadable fixture did not reach its input" ;;
      pressure) assert_contains "$out" "memory PSI full avg60" "the pressure fixture did not reach PSI admission" ;;
      disk) assert_contains "$out" "disk" "the disk fixture did not reach disk admission" ;;
      config) assert_contains "$out" "lane-capacity" "the invalid configuration did not reach admission" ;;
    esac
    queue_has "$home" retry-one && fail "$reason refusal created an automatic retry"
  done
  pass "non-lane machine refusals do not create retry records"
}

test_lock_contention_keeps_existing_retries() {
  local axis case_dir home project fakebin holder i out
  require_tasks || return 0
  for axis in task-set task project; do
    case_dir=$(new_case "contention-$axis" retry-one)
    home="$case_dir/home"
    project="$case_dir/project"
    fakebin=$(install_real_fakes "$case_dir")
    fm_git_init_commit "$project"
    fm_git_add_origin "$project" "$case_dir/project.origin.git"
    git -C "$project" worktree add --quiet -b wt-retry "$case_dir/wt-retry"
    write_brief "$home" retry-one
    real_command "$case_dir" "$ROOT_BIN" record retry-one -- "$SPAWN" retry-one "$project" --mode no-mistakes --yolo off
    cat > "$case_dir/hold" <<'SH'
#!/usr/bin/env bash
. "$1/bin/fm-wake-lib.sh"
case "$3" in
  task-set) lock=$(fm_task_set_lock_path "$2/home/state") ;;
  task) lock="$2/home/state/.spawn-retry-one.lock" ;;
  project) lock=$(fm_treehouse_project_lock_path "$2/project") ;;
esac
fm_lock_acquire_wait "$lock" || exit 1
fm_lock_set_role "$lock" task-spawn || exit 1
: > "$2/holder.ready"
while [ ! -f "$2/holder.release" ]; do sleep 0.05; done
fm_lock_release "$lock"
SH
    FM_HOME="$home" bash "$case_dir/hold" "$ROOT" "$case_dir" "$axis" >/dev/null 2>&1 &
    holder=$!
    for ((i=0; i<100; i++)); do
      [ ! -f "$case_dir/holder.ready" ] || break
      sleep 0.05
    done
    [ -f "$case_dir/holder.ready" ] || fail "$axis lock was not acquired"
    out=$(PATH="$fakebin:$PATH" real_command "$case_dir" "$ROOT_BIN" retry)
    : > "$case_dir/holder.release"
    wait "$holder" || fail "the $axis lock holder failed"
    assert_not_contains "$out" "started retry-one" "$axis contention was reported as a launch"
    assert_not_contains "$out" "failed retry-one" "$axis contention permanently suppressed the retry"
    queue_has "$home" retry-one || fail "$axis contention dropped the deferred request"
    out=$(real_command "$case_dir" "$ROOT_BIN" retry)
    assert_contains "$out" "started retry-one" "$axis contention prevented retry after the lock was released"
    [ -f "$home/state/retry-one.meta" ] || fail "$axis retry did not create a worker record"
  done
  pass "home, task, and project contention preserve existing automatic retries"
}

test_manual_or_missing_backlog_never_starts() {
  local state case_dir home out
  require_tasks || return 0
  for state in done held queued missing; do
    case_dir=$(new_case "unproven-$state" retry-one)
    home="$case_dir/home"
    record_task "$home" "$case_dir" retry-one
    if [ "$state" = missing ]; then
      rm "$home/data/backlog.md"
    else
      printf 'manual\n' > "$home/config/backlog-backend"
      case "$state" in
        done)
          tasks-axi start retry-one --file "$home/data/backlog.md" >/dev/null
          tasks-axi done retry-one --file "$home/data/backlog.md" >/dev/null
          ;;
        held) tasks-axi hold retry-one --kind captain --reason 'wait' --file "$home/data/backlog.md" >/dev/null ;;
      esac
    fi
    printf '1\n' > "$case_dir/free"
    out=$(deferred_home retry "$home" "$case_dir")
    assert_contains "$out" 'cannot establish queued eligibility' "an unproven $state row was not reported"
    assert_equals "" "$(cat "$case_dir/spawn.log")" "an unproven $state row was launched"
    assert_not_contains "$out" 'started retry-one' "an unproven $state row was reported as started"
  done
  pass "manual and absent backlogs cannot establish automatic queued eligibility"
}

test_temporary_preflight_refusals_remain_retryable() {
  local condition case_dir home project out actor
  require_tasks || return 0
  for condition in spend hold dependency branch-hold branch-dependency; do
    case_dir=$(new_case "temporary-$condition" retry-one blocker)
    home="$case_dir/home"
    project="$case_dir/project"
    install_real_fakes "$case_dir" >/dev/null
    fm_git_init_commit "$project"
    fm_git_add_origin "$project" "$case_dir/project.origin.git"
    git -C "$project" worktree add --quiet -b wt-retry "$case_dir/wt-retry"
    write_brief "$home" retry-one
    actor=main
    case "$condition" in
      branch-*)
        actor=branch
        real_command "$case_dir" "$ROOT/bin/fm-afk-contract.sh" enter --words 'continue queued work' --spend 3 >/dev/null
        ;;
    esac
    cat > "$case_dir/spawn" <<'SH'
#!/usr/bin/env bash
if [ ! -f "$FM_HOME/mutated" ]; then
  : > "$FM_HOME/mutated"
  case "$FM_DEFERRED_TEST_CONDITION" in
    hold|branch-hold) tasks-axi hold "$1" --kind captain --reason 'wait' --file "$FM_HOME/data/backlog.md" >/dev/null || exit 1 ;;
    dependency|branch-dependency) tasks-axi block "$1" --by blocker --file "$FM_HOME/data/backlog.md" >/dev/null || exit 1 ;;
  esac
fi
exec "$FM_DEFERRED_REAL_SPAWN" "$@"
SH
    real_command "$case_dir" "$ROOT_BIN" record retry-one -- "$case_dir/spawn" retry-one "$project" --mode no-mistakes --yolo off
    if [ "$condition" = spend ]; then
      fm_write_meta "$home/state/blocker.meta" \
        "window=firstmate:fm-blocker" "endpoint_task_id=blocker" \
        "worktree=$home/absent-worktree-blocker" "project=$project" \
        "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" "spawn_gen=s-blocker"
      real_command "$case_dir" "$ROOT/bin/fm-afk-contract.sh" enter --words 'wait for current work' --spend 1 >/dev/null
    fi
    out=$(FM_SUPERVISION_ACTOR="$actor" FM_DEFERRED_TEST_CONDITION="$condition" FM_DEFERRED_REAL_SPAWN="$SPAWN" real_command "$case_dir" "$ROOT_BIN" retry)
    assert_not_contains "$out" 'failed retry-one' "$condition refusal permanently suppressed the request"
    assert_not_contains "$out" 'started retry-one' "$condition refusal was reported as a launch"
    queue_has "$home" retry-one || fail "$condition refusal lost the queued request"
    [ ! -f "$home/state/retry-one.meta" ] || fail "$condition refusal created a worker"
    case "$condition" in
      spend) real_command "$case_dir" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null ;;
      hold|branch-hold) tasks-axi unhold retry-one --file "$home/data/backlog.md" >/dev/null ;;
      dependency|branch-dependency)
        tasks-axi start blocker --file "$home/data/backlog.md" >/dev/null
        tasks-axi done blocker --file "$home/data/backlog.md" >/dev/null
        ;;
    esac
    out=$(FM_SUPERVISION_ACTOR="$actor" FM_DEFERRED_TEST_CONDITION="$condition" FM_DEFERRED_REAL_SPAWN="$SPAWN" real_command "$case_dir" "$ROOT_BIN" retry)
    assert_contains "$out" 'started retry-one' "$condition refusal did not resume after clearing"
    [ -f "$home/state/retry-one.meta" ] || fail "$condition retry did not publish a worker"
  done
  pass "AFK spend caps and raced holds or dependencies preserve retryability"
}

test_manual_or_missing_backlog_never_starts
test_temporary_preflight_refusals_remain_retryable
test_sweep_returns_while_spawn_is_hung
test_lock_contention_keeps_existing_retries
test_only_full_machine_refusals_are_recorded
test_retries_are_serial
test_refusal_preserves_launch_budget
test_argument_bytes_survive_retry
test_oldest_and_one_per_free_lane
test_no_double_start
test_in_progress_claim_consumes_the_lane
test_held_task_is_skipped
test_stale_request_is_reported
test_closed_rows_are_removed_without_a_start
test_seat_already_held_is_skipped
test_busy_lock_starts_nothing
test_real_spawn_starts_after_a_lane_frees ship
test_real_spawn_starts_after_a_lane_frees scout
test_real_spawn_starts_after_a_lane_frees flags
test_real_spawn_starts_after_a_lane_frees pinned
