#!/usr/bin/env bash
# Shared-copy regression at the spawn, relaunch, promotion and teardown CLIs.
# Oracle: one copy per retained meta, even after worker exit; an unrelated
# checked-out branch must survive every cleanup attempt, including --force.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-shared-copy)

make_case() {
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/project"
  POOL_DIR="$CASE_DIR/pool/1/project"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  mkdir -p "$HOME_DIR"/{state,data,config,projects} "$CASE_DIR/pool/1"
  git init -qb main "$PROJECT_DIR"
  git -C "$PROJECT_DIR" -c user.name=Tests -c user.email=tests@example.invalid commit --allow-empty -qm initial
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$POOL_DIR" > "$CASE_DIR/pool/treehouse-state.json"
  : > "$HOME_DIR/config/keep-ai-trailers"
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  # No real pool operation: this adapter records only persistent lease state.
  cat > "$FAKEBIN_DIR/treehouse" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_POOL/log"
case "$*" in
  '--version') echo v3.1.8 ;;
  *'get --help'*) echo '--lease --lease-holder --json' ;;
  *'return --help'*) echo '--if-lease-id --if-lease-holder' ;;
  *'status --json'*)
    [ ! -e "$FM_TEST_POOL/fail-status" ] || exit 42
    jq '[.worktrees[] | . + {status:(if .leased then "leased" else "available" end),lease_id:(if .leased then "fixture-lease" else "" end),leased_at:null}]' "$FM_TEST_POOL/treehouse-state.json"
    ;;
  *'lease '[0-9]*)
    while [ "$1" != lease ]; do shift; done
    name=$2
    : > "$FM_TEST_POOL/leased-$name"
    jq --arg name "$name" '.worktrees |= map(if .name == $name then .leased = true else . end)' \
      "$FM_TEST_POOL/treehouse-state.json" > "$FM_TEST_POOL/state.new"
    mv "$FM_TEST_POOL/state.new" "$FM_TEST_POOL/treehouse-state.json"
    jq --arg name "$name" '.worktrees[] | select(.name == $name) | {path,lease_id:"fixture-lease",lease_holder:"fixture"}' "$FM_TEST_POOL/treehouse-state.json"
    ;;
  *'get --lease'*) printf '%s\n' "$FM_TEST_COPY" ;;
  *'return '*) echo 'unexpected return' >&2; exit 90 ;;
esac
FAKE
  chmod +x "$FAKEBIN_DIR/treehouse"
  export FM_TEST_POOL="$CASE_DIR/pool" FM_TEST_COPY="$POOL_DIR"
}

write_meta() { # <id> <kind> [branch]
  fm_write_meta "$HOME_DIR/state/$1.meta" \
    "window=firstmate:fm-$1" "endpoint_task_id=$1" "kind=$2" \
    "worktree=$POOL_DIR" "project=$PROJECT_DIR" "harness=codex" \
    "spawn_gen=s1" "branch=${3:-}"
}

spawn_case() {
  fm_test_spawn_brief "$HOME_DIR" new-task
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    new-task "$PROJECT_DIR" --scout --harness 'fixture-agent --worker'
}

assert_refuses() { # <expected> <command...>
  local expected=$1 rc=0
  shift
  "$@" > "$CASE_DIR/output" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "unsafe command succeeded: $*"
  assert_contains "$(cat "$CASE_DIR/output")" "$expected" "wrong refusal: $(cat "$CASE_DIR/output")"
}

run_cli() {
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_TEARDOWN_GUARD_DONE=1 \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$PATH" "$ROOT/bin/$1" "${@:2}"
}


# Public library seam used by spawn admission and home seeding; no real pool CLI.
protect_case() {
  # shellcheck disable=SC2016 # The child shell expands the positional arguments.
  env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" PATH="$FAKEBIN_DIR:$PATH" \
    "$BASH" -eu -c '
      . "$1/bin/fm-wake-lib.sh"
      . "$1/bin/fm-secondmate-registry-lib.sh"
      . "$1/bin/fm-backend.sh"
      . "$1/bin/fm-treehouse-lib.sh"
      fm_treehouse_protect_recorded_copies "$2" "$3" "$4"
    ' _ "$ROOT" "$HOME_DIR/state" "$PROJECT_DIR" "${1:-}"
}

add_retained_copy() { # <slot> [pool-directory]
  local name=$1 pool=${2:-$CASE_DIR/pool}
  POOL_DIR="$pool/$name/project"
  mkdir -p "$pool/$name"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR"
  if [ ! -f "$pool/treehouse-state.json" ]; then
    printf '{"worktrees":[]}\n' > "$pool/treehouse-state.json"
  fi
  jq --arg name "$name" --arg path "$POOL_DIR" '.worktrees += [{name:$name,path:$path}]' \
    "$pool/treehouse-state.json" > "$CASE_DIR/state.new"
  mv "$CASE_DIR/state.new" "$pool/treehouse-state.json"
  write_meta "retained-$name" scout
}

test_protect_reads_status_once_and_refreshes_on_replay() {
  local count leases
  make_case protect-status-count
  write_meta retained-1 scout
  add_retained_copy 2
  add_retained_copy 3
  # One slot already has a durable lease, which must never be replaced.
  jq '.worktrees[2].leased = true' "$FM_TEST_POOL/treehouse-state.json" > "$CASE_DIR/state.new"
  mv "$CASE_DIR/state.new" "$FM_TEST_POOL/treehouse-state.json"
  protect_case
  count=$(grep -c 'status --json' "$FM_TEST_POOL/log")
  [ "$count" -eq 1 ] || fail "3 retained records made $count status reads, expected 1"
  assert_present "$FM_TEST_POOL/leased-1" 'first retained slot was not held'
  assert_present "$FM_TEST_POOL/leased-2" 'second retained slot was not held'
  assert_absent "$FM_TEST_POOL/leased-3" 'existing durable lease was replaced'
  leases=$(grep -c ' lease ' "$FM_TEST_POOL/log")
  [ "$leases" -eq 2 ] || fail 'wrong slots were leased from the shared snapshot'
  protect_case
  count=$(grep -c 'status --json' "$FM_TEST_POOL/log")
  [ "$count" -eq 2 ] || fail 'replay reused a previous invocation snapshot'
  [ "$(grep -c ' lease ' "$FM_TEST_POOL/log")" -eq 2 ] || fail 'replay replaced durable leases'
  # Refresh must observe a changed pool rather than keep the earlier snapshot.
  add_retained_copy 4
  protect_case
  [ "$(grep -c 'status --json' "$FM_TEST_POOL/log")" -eq 3 ] || fail 'third protect did not read fresh status'
  assert_present "$FM_TEST_POOL/leased-4" 'fresh retained record was missed on replay'
  pass 'protect reads status once per root, filters each slot and refreshes on replay'
}

test_protect_status_failure_changes_nothing() {
  make_case protect-status-failure
  write_meta retained-1 scout
  add_retained_copy 2
  cp "$FM_TEST_POOL/treehouse-state.json" "$CASE_DIR/before.json"
  : > "$FM_TEST_POOL/fail-status"
  assert_refuses 'cannot durably protect' protect_case
  cmp -s "$CASE_DIR/before.json" "$FM_TEST_POOL/treehouse-state.json" || fail 'failed read changed pool state'
  assert_no_grep ' lease ' "$FM_TEST_POOL/log" 'failed read held a copy'
  assert_no_grep ' return ' "$FM_TEST_POOL/log" 'failed read released a copy'
  rm "$FM_TEST_POOL/fail-status"
  protect_case check
  assert_no_grep ' lease ' "$FM_TEST_POOL/log" 'check mode held a copy'
  assert_no_grep ' return ' "$FM_TEST_POOL/log" 'check mode released a copy'
  protect_case
  assert_present "$FM_TEST_POOL/leased-1" 'failed snapshot leaked into a later invocation'
  assert_present "$FM_TEST_POOL/leased-2" 'retry did not hold all copies'
  pass 'a failed status read holds and releases nothing; check mode also stays read-only'
}

test_protect_caches_by_root_before_holding() {
  local second_pool root
  make_case protect-multiple-roots
  write_meta retained-1 scout
  second_pool="$CASE_DIR/other/.treehouse/project-pool"
  add_retained_copy 2 "$second_pool"
  # Model Treehouse root resolution, so cross-root snapshot reuse cannot pass.
  mv "$FAKEBIN_DIR/treehouse" "$FAKEBIN_DIR/treehouse.fixture"
  cat > "$FAKEBIN_DIR/treehouse" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = --root ] && [ "$2" = "$FM_TEST_SECOND_ROOT" ]; then
  export FM_TEST_POOL="$FM_TEST_SECOND_ROOT/.treehouse/project-pool"
fi
exec "$(dirname "$0")/treehouse.fixture" "$@"
FAKE
  chmod +x "$FAKEBIN_DIR/treehouse"
  export FM_TEST_SECOND_ROOT="$CASE_DIR/other"
  : > "$second_pool/fail-status"
  assert_refuses 'cannot durably protect' protect_case
  for root in "$FM_TEST_POOL" "$second_pool"; do
    assert_no_grep ' lease ' "$root/log" 'later root failure partially held copies'
    assert_no_grep ' return ' "$root/log" 'later root failure released a copy'
  done
  rm "$second_pool/fail-status"
  : > "$FM_TEST_POOL/log"
  : > "$second_pool/log"
  protect_case
  for root in "$FM_TEST_POOL" "$second_pool"; do
    [ "$(grep -c 'status --json' "$root/log")" -eq 1 ] || fail 'root did not get exactly one snapshot'
  done
  assert_present "$FM_TEST_POOL/leased-1" 'first root was not held'
  assert_present "$second_pool/leased-2" 'second root was not held'
  pass 'separate roots get separate snapshots and all reads precede lease changes'
}

test_spawn_refuses_retained_record() {
  local state
  for state in 'done' held; do
    make_case "spawn-$state"
    git -C "$POOL_DIR" checkout -qb fm/incumbent
    write_meta incumbent scout
    printf '%s: worker exited\n' "$state" > "$HOME_DIR/state/incumbent.status"
    printf 'task=incumbent\nhome=%s\n' "$HOME_DIR" > "$CASE_DIR/pool/1/.fm-slot-owner"
    assert_refuses 'also task incumbent' spawn_case
    [ "$(git -C "$POOL_DIR" symbolic-ref --short HEAD)" = fm/incumbent ] || fail 'spawn moved retained copy'
    assert_absent "$HOME_DIR/state/new-task.meta" 'spawn published a second owner'
    assert_grep 'task=incumbent' "$CASE_DIR/pool/1/.fm-slot-owner" 'spawn overwrote incumbent claim'
  done
  pass 'spawn refuses a retained done or held record, without changing its copy or claim'
}

test_teardown_refuses_wrong_branch() {
  local force
  for force in '' --force; do
    make_case "branch-${force:-ordinary}"
    git -C "$POOL_DIR" checkout -qb fm/designer
    write_meta finished ship fm/finished
    printf 'task=finished\nhome=%s\n' "$HOME_DIR" > "$CASE_DIR/pool/1/.fm-slot-owner"
    assert_refuses 'recorded branch' run_cli fm-teardown.sh finished ${force:+"$force"}
    [ "$(git -C "$POOL_DIR" symbolic-ref --short HEAD)" = fm/designer ] || fail 'cleanup detached designer'
    assert_present "$HOME_DIR/state/finished.meta" 'branch refusal removed record'
    assert_present "$CASE_DIR/pool/1/.fm-slot-owner" 'branch refusal removed claim'
  done
  pass 'ordinary and forced teardown refuse a branch different from the recorded branch'
}

test_teardown_rechecks_branch_after_process_barrier() {
  make_case branch-drift
  git -C "$POOL_DIR" checkout -qb fm/finished
  write_meta finished scout fm/finished
  printf 'task=finished\nhome=%s\n' "$HOME_DIR" > "$CASE_DIR/pool/1/.fm-slot-owner"
  cat > "$FAKEBIN_DIR/lsof" <<'FAKE'
#!/usr/bin/env bash
# Simulate the exiting worker changing branches after the initial preflight.
git -C "$FM_TEST_COPY" checkout -qb fm/designer
exit 0
FAKE
  chmod +x "$FAKEBIN_DIR/lsof"
  assert_refuses 'recorded branch' run_cli fm-teardown.sh finished --force
  [ "$(git -C "$POOL_DIR" symbolic-ref --short HEAD)" = fm/designer ] || fail 'late cleanup detached the new branch'
  assert_present "$HOME_DIR/state/finished.meta" 'late branch refusal lost the record'
  assert_grep 'task=finished' "$CASE_DIR/pool/1/.fm-slot-owner" 'late branch refusal lost the claim'
  pass 'teardown rechecks the branch after its process barrier before changing the checkout'
}

test_forced_descendant_refuses_wrong_branch() {
  local mate
  make_case child-branch
  mate="$CASE_DIR/mate"
  mkdir -p "$mate"/{state,data,config,projects,bin}
  printf 'parent\n' > "$mate/.fm-secondmate-home"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  git -C "$POOL_DIR" checkout -qb fm/designer
  fm_write_meta "$HOME_DIR/state/parent.meta" \
    'window=firstmate:fm-parent' 'endpoint_task_id=parent' 'kind=secondmate' \
    "worktree=$mate" "home=$mate" "project=$PROJECT_DIR" 'harness=codex' 'spawn_gen=s1'
  fm_write_meta "$mate/state/child.meta" \
    'window=firstmate:fm-child' 'endpoint_task_id=child' 'kind=ship' \
    "worktree=$POOL_DIR" "project=$PROJECT_DIR" 'harness=codex' 'spawn_gen=s1' 'branch=fm/child'
  printf 'task=child\nhome=%s\n' "$mate" > "$CASE_DIR/pool/1/.fm-slot-owner"
  assert_refuses 'recorded branch' run_cli fm-teardown.sh parent --force
  [ "$(git -C "$POOL_DIR" symbolic-ref --short HEAD)" = fm/designer ] || fail 'forced descendant cleanup detached designer'
  assert_present "$mate/state/child.meta" 'forced descendant refusal lost child identity'
  assert_present "$HOME_DIR/state/parent.meta" 'forced descendant refusal lost parent identity'
  pass 'forced descendant cleanup refuses a pooled child on another recorded branch'
}

test_promotion_and_control_refuse_shared_copy() {
  local command
  for command in promote control; do
    make_case "$command"
    write_meta stale scout
    write_meta live ship fm/live
    cp "$HOME_DIR/state/stale.meta" "$CASE_DIR/meta.before"
    if [ "$command" = promote ]; then
      assert_refuses 'also task live' run_cli fm-promote.sh stale --mode direct-PR --yolo off
    else
      assert_refuses 'also task live' run_cli fm-control.sh stale relaunch
    fi
    cmp -s "$CASE_DIR/meta.before" "$HOME_DIR/state/stale.meta" || fail "$command changed contested record"
  done
  pass 'promotion and transactional relaunch refuse shared copies before changing the task'
}

# The reported three-record incident: a merged ship and completed scout both
# have stale worktree= lines; the current marker and branch name the designer.
# No --force and no pool release is needed to retire either old record.
test_records_only_cleanup_keeps_designer() {
  local id head
  make_case records-only
  git -C "$POOL_DIR" checkout -qb fm/designer
  printf 'unfinished design\n' > "$POOL_DIR/design.txt"
  head=$(git -C "$POOL_DIR" rev-parse HEAD)
  write_meta finished-ship ship fm/finished-ship
  printf 'mode=local-only\n' >> "$HOME_DIR/state/finished-ship.meta"
  write_meta finished-scout scout
  mkdir -p "$HOME_DIR/data/finished-scout"
  printf 'report\n' > "$HOME_DIR/data/finished-scout/report.md"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >> "$HOME_DIR/state/finished-scout.meta"
  write_meta designer ship fm/designer
  printf 'task=designer\nhome=%s\n' "$HOME_DIR" > "$CASE_DIR/pool/1/.fm-slot-owner"
  cp "$HOME_DIR/state/designer.meta" "$CASE_DIR/designer.before"
  for id in finished-ship finished-scout; do
    run_cli fm-teardown.sh "$id" > "$CASE_DIR/output" 2>&1 || fail "records-only $id: $(cat "$CASE_DIR/output")"
    assert_absent "$HOME_DIR/state/$id.meta" 'finished record was not retired'
    [ "$(git -C "$POOL_DIR" symbolic-ref --short HEAD)" = fm/designer ] || fail 'records-only detached designer'
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$head" ] || fail 'records-only reset designer'
    assert_grep 'unfinished design' "$POOL_DIR/design.txt" 'records-only removed designer edits'
    cmp -s "$CASE_DIR/designer.before" "$HOME_DIR/state/designer.meta" || fail 'records-only changed designer meta'
    assert_grep 'task=designer' "$CASE_DIR/pool/1/.fm-slot-owner" 'records-only changed designer claim'
  done
  [ ! -e "$CASE_DIR/pool/log" ] || fail 'records-only invoked Treehouse'
  pass 'both stale records retire without force and leave the designer copy, branch, edits, claim and meta intact'
}


test_spawn_protects_retained_copy_before_acquiring_another() {
  local old
  make_case legacy-protection
  old=$POOL_DIR
  git -C "$old" checkout -qb fm/incumbent
  write_meta incumbent ship fm/incumbent
  mkdir -p "$CASE_DIR/pool/2"
  POOL_DIR="$CASE_DIR/pool/2/project"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR"
  jq --arg path "$POOL_DIR" '.worktrees += [{name:"2",path:$path}]' \
    "$CASE_DIR/pool/treehouse-state.json" > "$CASE_DIR/state.new"
  mv "$CASE_DIR/state.new" "$CASE_DIR/pool/treehouse-state.json"
  spawn_case > "$CASE_DIR/output" 2>&1 || fail "new independent copy: $(cat "$CASE_DIR/output")"
  assert_present "$CASE_DIR/pool/leased-1" 'retained copy was not protected before allocation'
  assert_present "$CASE_DIR/pool/leased-2" 'new copy has only a process reservation'
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/new-task.meta" 'new task did not record its independent copy'
  [ "$(git -C "$old" symbolic-ref --short HEAD)" = fm/incumbent ] || fail 'protecting legacy copy changed its branch'
  pass 'a legacy reservation and a fresh reservation both become durable without changing the retained copy'
}

test_fresh_scout_teardown_accepts_its_detached_copy() {
  make_case scout-cleanup
  # shellcheck source=tests/treehouse-fake-lib.sh
  . "$ROOT/tests/treehouse-fake-lib.sh"
  fm_test_treehouse_pool "$FAKEBIN_DIR" "$CASE_DIR/pool"
  spawn_case > "$CASE_DIR/output" 2>&1 || fail "scout spawn: $(cat "$CASE_DIR/output")"
  if git -C "$POOL_DIR" symbolic-ref --quiet HEAD; then
    fail 'the scout fixture must stay detached to exercise cleanup without a ship branch'
  fi
  run_cli fm-teardown.sh new-task --force > "$CASE_DIR/output" 2>&1 \
    || fail "scout cleanup: $(cat "$CASE_DIR/output")"
  assert_absent "$HOME_DIR/state/new-task.meta" 'detached scout record survived cleanup'
  jq -e '.worktrees[0].leased == false' "$CASE_DIR/pool/treehouse-state.json" >/dev/null \
    || fail 'detached scout copy stayed leased'
  pass 'a newly spawned scout can clean up its detached copy without an uncreated ship branch'
}

test_spawn_resolves_native_pool_root() {
  local native_root native_pool
  make_case native-root
  native_root="$CASE_DIR/native"
  native_pool="$native_root/.treehouse/project-pool"
  mkdir -p "$native_pool/1"
  git -C "$PROJECT_DIR" worktree move "$POOL_DIR" "$native_pool/1/project"
  POOL_DIR="$native_pool/1/project"
  jq --arg path "$POOL_DIR" '.worktrees[0].path = $path' \
    "$CASE_DIR/pool/treehouse-state.json" > "$native_pool/treehouse-state.json"
  export FM_TEST_POOL="$native_pool" FM_TEST_COPY="$POOL_DIR"
  mv "$FAKEBIN_DIR/treehouse" "$FAKEBIN_DIR/treehouse.fixture"
  cat > "$FAKEBIN_DIR/treehouse" <<'FAKE'
#!/usr/bin/env bash
set -eu
root=${TREEHOUSE_ROOT:?}
if [ "${1:-}" = --root ]; then root=$2; shift 2; fi
case "${1:-}" in
  status|lease)
    # Treehouse v3.1.8 ResolvePoolRoot appends .treehouse to explicit roots.
    export FM_TEST_POOL="$root/.treehouse/project-pool"
    if [ ! -f "$FM_TEST_POOL/treehouse-state.json" ]; then
      [ "$1" != status ] || { echo '[]'; exit 0; }
      exit 1
    fi
    ;;
esac
exec "$(dirname "$0")/treehouse.fixture" "$@"
FAKE
  chmod +x "$FAKEBIN_DIR/treehouse"
  # The recorded slot, rather than the current environment, identifies its pool.
  TREEHOUSE_ROOT="$CASE_DIR/other-root" spawn_case > "$CASE_DIR/output" 2>&1 \
    || fail "native pool root: $(cat "$CASE_DIR/output")"
  assert_present "$native_pool/leased-1" 'spawn did not durably lease the native pool slot'
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/new-task.meta" 'spawn did not record the native pool slot'
  pass 'spawn resolves native status and lease roots from the recorded pool'
}

test_direct_spawn_relaunch_refuses_shared_copy() {
  make_case spawn-relaunch
  write_meta stale scout
  write_meta live ship fm/live
  # The fake endpoint is agent-free. Direct recovery must still reject sharing.
  assert_refuses 'also task live' run_cli fm-spawn.sh stale --relaunch
  assert_present "$HOME_DIR/state/stale.meta" 'relaunch discarded the stale record'
  pass 'direct spawn recovery rejects a copy another meta still names'
}

test_fresh_same_id_retry_preserves_retained_copy() {
  local capacity old head
  for capacity in capped uncapped; do
    make_case "same-id-$capacity"
    [ "$capacity" != capped ] || printf 'project 1\n' > "$HOME_DIR/config/project-capacity"
    old=$POOL_DIR
    git -C "$old" checkout -qb fm/new-task
    head=$(git -C "$old" rev-parse HEAD)
    printf 'retained investigation\n' > "$old/work.txt"
    write_meta new-task scout fm/new-task
    printf 'done: worker exited\n' > "$HOME_DIR/state/new-task.status"
    printf 'task=new-task\nhome=%s\n' "$HOME_DIR" > "$CASE_DIR/pool/1/.fm-slot-owner"
    : > "$CASE_DIR/pool/leased-1"
    cp "$HOME_DIR/state/new-task.meta" "$CASE_DIR/meta.before"
    mkdir -p "$CASE_DIR/pool/2"
    POOL_DIR="$CASE_DIR/pool/2/project"
    git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR"
    jq --arg path "$POOL_DIR" '.worktrees += [{name:"2",path:$path}]' \
      "$CASE_DIR/pool/treehouse-state.json" > "$CASE_DIR/state.new"
    mv "$CASE_DIR/state.new" "$CASE_DIR/pool/treehouse-state.json"
    assert_refuses 'retains a recorded copy' spawn_case
    cmp -s "$CASE_DIR/meta.before" "$HOME_DIR/state/new-task.meta" || fail 'same-id retry replaced retained-copy ownership'
    [ "$(git -C "$old" symbolic-ref --short HEAD)" = fm/new-task ] || fail 'same-id retry changed retained branch'
    [ "$(git -C "$old" rev-parse HEAD)" = "$head" ] || fail 'same-id retry reset retained HEAD'
    assert_grep 'retained investigation' "$old/work.txt" 'same-id retry discarded retained work'
    assert_grep 'task=new-task' "$CASE_DIR/pool/1/.fm-slot-owner" 'same-id retry removed retained claim'
    assert_present "$CASE_DIR/pool/leased-1" 'same-id retry released retained lease'
    assert_absent "$FAKEBIN_DIR/.spawn-window" 'same-id retry opened a replacement endpoint'
    assert_absent "$CASE_DIR/pool/leased-2" 'same-id retry leased a replacement copy'
    if [ -e "$CASE_DIR/pool/log" ]; then
      assert_no_grep 'get --lease' "$CASE_DIR/pool/log" 'same-id retry allocated a replacement copy'
    fi
  done
  pass 'capped and uncapped fresh same-id retries preserve retained ownership and work'
}

test_deferred_spawn_refuses_retained_copy() {
  command -v tasks-axi >/dev/null 2>&1 || {
    echo 'ok - skipped deferred ownership fixture (tasks-axi unavailable)'
    return
  }
  make_case deferred
  git -C "$POOL_DIR" checkout -qb fm/incumbent
  write_meta incumbent scout
  printf 'done: scout stopped, record retained\n' > "$HOME_DIR/state/incumbent.status"
  printf 'task=incumbent\nhome=%s\n' "$HOME_DIR" > "$CASE_DIR/pool/1/.fm-slot-owner"
  rm "$HOME_DIR/config/backlog-backend"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$HOME_DIR/.tasks.toml"
  tasks-axi add new-task 'deferred ownership fixture' --kind scout --file "$HOME_DIR/data/backlog.md" >/dev/null
  fm_test_spawn_brief "$HOME_DIR" new-task
  printf '#!/usr/bin/env bash\necho "capacity: free_lanes=1"\n' > "$CASE_DIR/capacity"
  chmod +x "$CASE_DIR/capacity"
  run_cli fm-spawn-deferred.sh record new-task -- "$ROOT/bin/fm-spawn.sh" \
    new-task "$PROJECT_DIR" --scout --harness 'fixture-agent --worker'
  FM_SPAWN_DEFERRED_CAPACITY_BIN="$CASE_DIR/capacity" FM_FAKE_PANE_PATH="$POOL_DIR" TMUX=fake,1,0 \
    run_cli fm-spawn-deferred.sh retry > "$CASE_DIR/output" 2>&1
  assert_grep 'failed new-task exit 1' "$CASE_DIR/output" 'deferred retry claimed a successful launch'
  assert_grep 'also task incumbent' "$HOME_DIR/state/spawn-deferred/retry.log" 'deferred retry bypassed the spawn ownership guard'
  assert_absent "$HOME_DIR/state/new-task.meta" 'deferred retry published a second owner'
  [ "$(git -C "$POOL_DIR" symbolic-ref --short HEAD)" = fm/incumbent ] || fail 'deferred retry moved the retained copy'
  assert_grep 'task=incumbent' "$CASE_DIR/pool/1/.fm-slot-owner" 'deferred retry overwrote the retained claim'
  pass 'the deferred queue invokes the guarded spawn and refuses a retained scout copy'
}

test_home_seed_refuses_retained_copy() {
  local requested
  for requested in - explicit; do
    make_case "seed-$requested"
    write_meta incumbent scout
    printf 'unfinished scout\n' > "$POOL_DIR/scout.txt"
    [ "$requested" != explicit ] || requested=$POOL_DIR
    assert_refuses 'also task incumbent' env \
      -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
      FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT_DIR" PATH="$FAKEBIN_DIR:$PATH" \
      "$ROOT/bin/fm-home-seed.sh" new-mate "$requested" --no-projects
    assert_grep 'unfinished scout' "$POOL_DIR/scout.txt" 'home seeding or rollback touched retained scout'
    assert_absent "$POOL_DIR/.fm-secondmate-home" 'home seeding adopted the retained copy'
    assert_present "$HOME_DIR/state/incumbent.meta" 'home seeding discarded incumbent record'
    assert_no_grep 'return /' "$CASE_DIR/pool/log" 'seed rollback returned another task copy'
  done
  pass 'leased and explicit home seeding refuse a retained scout copy without rolling it back'
}

test_autolaunch_refuses_retained_copy() {
  command -v tasks-axi >/dev/null 2>&1 || {
    echo 'ok - skipped autolaunch ownership fixture (tasks-axi unavailable)'
    return
  }
  make_case autolaunch
  git -C "$POOL_DIR" checkout -qb fm/incumbent
  write_meta incumbent scout
  printf 'task=incumbent\nhome=%s\n' "$HOME_DIR" > "$CASE_DIR/pool/1/.fm-slot-owner"
  rm "$HOME_DIR/config/backlog-backend"
  ln -s "$PROJECT_DIR" "$HOME_DIR/projects/project"
  printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$HOME_DIR/.tasks.toml"
  printf '## In flight\n## Queued\n- [ ] new-task - queued scout (repo: project) (kind: scout)\n## Done\n' > "$HOME_DIR/data/backlog.md"
  fm_test_spawn_brief "$HOME_DIR" new-task
  printf 'Investigate the queued task.\n' > "$HOME_DIR/data/new-task/prep.md"
  printf '{"shared_quota":true,"default":{"harness":"claude"}}\n' > "$HOME_DIR/config/crew-dispatch.json"
  printf '#!/usr/bin/env bash\necho "capacity: free_lanes=1"\n' > "$CASE_DIR/capacity"
  chmod +x "$CASE_DIR/capacity"
  FM_AUTOLAUNCH_CAPACITY_BIN="$CASE_DIR/capacity" FM_FAKE_PANE_PATH="$POOL_DIR" TMUX=fake,1,0 \
    run_cli fm-autolaunch.sh > "$CASE_DIR/output" 2>&1
  assert_grep 'also task incumbent' "$HOME_DIR/state/autolaunch.log" 'autolaunch bypassed the spawn ownership guard'
  assert_absent "$HOME_DIR/state/new-task.meta" 'autolaunch published a second owner'
  [ "$(git -C "$POOL_DIR" symbolic-ref --short HEAD)" = fm/incumbent ] || fail 'autolaunch moved retained scout'
  assert_grep 'task=incumbent' "$CASE_DIR/pool/1/.fm-slot-owner" 'autolaunch overwrote retained claim'
  pass 'automatic prepared-backlog launch refuses a retained copy through the shared spawn guard'
}



test_protect_reads_status_once_and_refreshes_on_replay
test_protect_status_failure_changes_nothing
test_protect_caches_by_root_before_holding
test_spawn_resolves_native_pool_root
test_teardown_rechecks_branch_after_process_barrier
test_forced_descendant_refuses_wrong_branch
test_spawn_refuses_retained_record
test_spawn_protects_retained_copy_before_acquiring_another
test_fresh_scout_teardown_accepts_its_detached_copy
test_direct_spawn_relaunch_refuses_shared_copy
test_fresh_same_id_retry_preserves_retained_copy
test_deferred_spawn_refuses_retained_copy
test_home_seed_refuses_retained_copy
test_autolaunch_refuses_retained_copy
test_teardown_refuses_wrong_branch
test_promotion_and_control_refuse_shared_copy
test_records_only_cleanup_keeps_designer
