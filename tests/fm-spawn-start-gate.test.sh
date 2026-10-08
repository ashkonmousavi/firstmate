#!/usr/bin/env bash
# Behavior tests for the new-feature start gate in a fresh ship spawn
# (bin/fm-start-gate-lib.sh, configured by config/start-gate.json).
#
# Spawn cases drive the real bin/fm-spawn.sh in a disposable fixture home with
# the fake tmux and treehouse from tests/fixtures.sh and a synthetic fact
# snapshot. A refused feature start must allocate nothing: no task record, no
# inbox, no launch brief, and the copy's branch left alone. Repairs, scouts,
# ungated projects and healthy or covered facts must pass the gate, while the
# existing delivery guards keep their own authority.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-start-gate)
NOW=$(date +%s)

# make_gate_case <name> <id> [class]: a home whose project is gated, a copy, and
# a brief whose preparation record declares <class> (none omits the line).
make_gate_case() {
  local name=$1 id=$2 class=${3:-feature} case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id" "Exercise the start gate for $id."
  set_class "$home" "$id" "$class"
  printf '{"project":{"facts":"%s"}}\n' "$case_dir/facts.json" > "$home/config/start-gate.json"
  CASE_DIR=$case_dir HOME_DIR=$home PROJ_DIR=$proj WT_DIR=$wt FAKEBIN_DIR=$fakebin FACTS="$case_dir/facts.json"
}

set_class() {  # <home> <id> <class|none>
  local prep="$1/data/$2/prep.md"
  awk -v class="$3" '
    /^- Work class:/ { next }
    { print }
    /^- Delivery depth:/ && class != "none" { print "- Work class: " class }
  ' "$prep" > "$prep.class" && mv "$prep.class" "$prep"
}

# write_facts <causes-json> [generated_at] [project] [schema]
write_facts() {
  printf '{"schema":"%s","generated_at":%s,"project":"%s","causes":%s}\n' \
    "${4:-fm-start-facts.v1}" "${2:-$NOW}" "${3:-project}" "$1" > "$FACTS"
}

UNOWNED='[{"id":"q-main-nightly","kind":"main-failure","detail":"main nightly red on e2e","owner_task":null,"owner_state":null},{"id":"q-zenbook","kind":"frozen-machine","detail":"zenbook ready work, 0 working","owner_task":"zb-fix","owner_state":"paused"}]'
COVERED='[{"id":"q-main-nightly","kind":"main-failure","detail":"main nightly red on e2e","owner_task":"main-fix","owner_state":"working"},{"id":"q-zenbook","kind":"frozen-machine","detail":"zenbook ready work, 0 working","owner_task":"zb-fix","owner_state":"working"}]'

spawn_ship() {  # <id> [extra args]
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$@"
}

assert_nothing_allocated() {  # <id> <out>
  assert_absent "$HOME_DIR/state/$1.meta" "refused start published a task record"$'\n'"$2"
  assert_absent "$HOME_DIR/state/$1.inbox" "refused start created a steering inbox"
  assert_absent "$HOME_DIR/data/$1/launch-brief.md" "refused start rendered a launch brief"
  assert_equals "wt-$(basename "$CASE_DIR")" "$(git -C "$WT_DIR" branch --show-current)" \
    "refused start touched the copy's branch"
}

assert_spawned() {  # <id> <status> <out>
  [ "$2" -eq 0 ] || fail "spawn of $1 was refused"$'\n'"$3"
  assert_present "$HOME_DIR/state/$1.meta" "spawn of $1 published no task record"
}

assert_refused() {  # <id> <status> <out> <expected-substring>
  [ "$2" -ne 0 ] || fail "spawn of $1 was not refused"$'\n'"$3"
  assert_contains "$3" "$4" "refusal did not name the reason"
  assert_nothing_allocated "$1" "$3"
}

# G1: the dry run - a feature start against an unowned main failure and a
# frozen machine whose owner is not active is refused, naming both causes,
# before any allocation.
test_feature_refused_naming_each_uncovered_cause() {
  local id=gate-g1 out status
  make_gate_case g1 "$id"
  write_facts "$UNOWNED"
  out=$(spawn_ship "$id")
  status=$?
  assert_refused "$id" "$status" "$out" "no worker on main-failure q-main-nightly: main nightly red on e2e (owner: none)"
  assert_contains "$out" "no worker on frozen-machine q-zenbook: zenbook ready work, 0 working (owner: zb-fix, paused)" \
    "refusal did not name the frozen machine with an inactive owner"
  pass "G1 a new feature start is refused before allocation, naming every uncovered cause"
}

# G2: the same unhealthy facts never refuse a fix, revert or live-breakage
# start, and the existing delivery guards keep their authority.
test_repairs_pass_same_unhealthy_facts() {
  local class id out status
  for class in fix revert live-breakage; do
    id="gate-g2-$class"
    make_gate_case "g2-$class" "$id" "$class"
    write_facts "$UNOWNED"
    out=$(spawn_ship "$id")
    status=$?
    assert_spawned "$id" "$status" "$out"
    assert_contains "$out" "work class $class is never refused" "gate did not report the repair exemption"
  done
  id=gate-g2-guard
  make_gate_case g2-guard "$id" fix
  write_facts "$UNOWNED"
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  assert_refused "$id" "$status" "$out" "declared Delivery depth"
  pass "G2 fix, revert and live-breakage pass unhealthy facts; existing guards still refuse"
}

# G3: covered causes and an empty cause list permit a feature, and the gate
# reads the snapshot's reconciled owner state, never a worker's status line.
test_covered_or_clear_facts_permit_feature() {
  local id out status
  id=gate-g3-covered
  make_gate_case g3-covered "$id"
  write_facts "$COVERED"
  out=$(spawn_ship "$id")
  status=$?
  assert_spawned "$id" "$status" "$out"
  assert_contains "$out" "feature start permitted" "permit was not reported explicitly"

  id=gate-g3-clear
  make_gate_case g3-clear "$id"
  write_facts '[]'
  out=$(spawn_ship "$id")
  status=$?
  assert_spawned "$id" "$status" "$out"

  id=gate-g3-status
  make_gate_case g3-status "$id"
  write_facts "$UNOWNED"
  printf 'working [at=%s]: fixing main\n' "$NOW" > "$HOME_DIR/state/zb-fix.status"
  out=$(spawn_ship "$id")
  status=$?
  assert_refused "$id" "$status" "$out" "owner: zb-fix, paused"
  pass "G3 covered or clear facts permit a feature; a status line never covers a cause"
}

# G4: unknown, stale or malformed facts and an unclassified task are refused
# with a named diagnosis, and a repair still passes the same bad facts.
test_unknown_facts_and_class_are_diagnosed() {
  local n=0 spec expect id out status
  while IFS='|' read -r spec expect; do
    n=$((n + 1))
    id="gate-g4-$n"
    make_gate_case "g4-$n" "$id"
    case "$spec" in
    missing) : ;;
    notjson) printf 'not json\n' > "$FACTS" ;;
    stale) write_facts '[]' "$((NOW - 1000))" ;;
    future) write_facts '[]' "$((NOW + 1000))" ;;
    textual-time) write_facts '[]' '"soon"' ;;
    wrong-project) write_facts '[]' "$NOW" other ;;
    wrong-schema) write_facts '[]' "$NOW" project fm-start-facts.v0 ;;
    bad-cause) write_facts '[{"id":"x","kind":"slow-machine","detail":"d","owner_task":null,"owner_state":null}]' ;;
    no-class) write_facts '[]'; set_class "$HOME_DIR" "$id" none ;;
    bad-class) write_facts '[]'; set_class "$HOME_DIR" "$id" chore ;;
    bad-config) write_facts '[]'; printf '[1]\n' > "$HOME_DIR/config/start-gate.json" ;;
    relative-facts) write_facts '[]'; printf '{"project":{"facts":"facts.json"}}\n' > "$HOME_DIR/config/start-gate.json" ;;
    esac
    out=$(spawn_ship "$id")
    status=$?
    assert_refused "$id" "$status" "$out" "$expect"
  done <<'EOF'
missing|facts unknown: no readable snapshot
notjson|facts unknown: snapshot is not valid JSON
stale|over the 900s limit
future|generated_at is in the future
textual-time|generated_at is not integer epoch seconds
wrong-project|snapshot is for project "other", not project
wrong-schema|schema is not fm-start-facts.v1
bad-cause|a cause lacks
no-class|must declare one Tier line '- Work class:
bad-class|must declare one Tier line '- Work class:
bad-config|is not one JSON object
relative-facts|needs an absolute "facts" path
EOF
  id=gate-g4-fix
  make_gate_case g4-fix "$id" fix
  printf 'not json\n' > "$FACTS"
  out=$(spawn_ship "$id")
  status=$?
  assert_spawned "$id" "$status" "$out"
  pass "G4 unknown facts and classification are diagnosed; a repair stays independent of them"
}

test_invalid_configuration_is_refused() {
  local n=0 spec id out status
  for spec in entry-false entry-null entry-string entry-array entry-number empty-file multiple-objects mixed-documents bad-json bad-map unreadable; do
    n=$((n + 1))
    id="gate-config-$n"
    make_gate_case "config-$n" "$id"
    write_facts '[]'
    case "$spec" in
    entry-false) printf '{"project":false}\n' > "$HOME_DIR/config/start-gate.json" ;;
    entry-null) printf '{"project":null}\n' > "$HOME_DIR/config/start-gate.json" ;;
    entry-string) printf '{"project":"facts"}\n' > "$HOME_DIR/config/start-gate.json" ;;
    entry-array) printf '{"project":[]}\n' > "$HOME_DIR/config/start-gate.json" ;;
    entry-number) printf '{"project":1}\n' > "$HOME_DIR/config/start-gate.json" ;;
    empty-file) : > "$HOME_DIR/config/start-gate.json" ;;
    multiple-objects) printf '{}\n{}\n' >> "$HOME_DIR/config/start-gate.json" ;;
    mixed-documents) printf 'false\n' >> "$HOME_DIR/config/start-gate.json" ;;
    bad-json) printf 'not json\n' > "$HOME_DIR/config/start-gate.json" ;;
    bad-map) printf '[1]\n' > "$HOME_DIR/config/start-gate.json" ;;
    unreadable) rm "$HOME_DIR/config/start-gate.json"; mkdir "$HOME_DIR/config/start-gate.json" ;;
    esac
    out=$(spawn_ship "$id")
    status=$?
    assert_refused "$id" "$status" "$out" "is not one JSON object with an object entry"
  done
  pass "malformed configuration refuses features before allocation"
}

test_repairs_bypass_configuration_and_dependency_failures() {
  local class spec id out status n=0
  for class in fix revert live-breakage; do
    for spec in bad-json bad-map bad-entry unreadable relative missing-facts; do
      n=$((n + 1))
      id="gate-repair-$n"
      make_gate_case "repair-$n" "$id" "$class"
      case "$spec" in
      bad-json) printf 'not json\n' > "$HOME_DIR/config/start-gate.json" ;;
      bad-map) printf '[1]\n' > "$HOME_DIR/config/start-gate.json" ;;
      bad-entry) printf '{"project":null}\n' > "$HOME_DIR/config/start-gate.json" ;;
      unreadable) rm "$HOME_DIR/config/start-gate.json"; mkdir "$HOME_DIR/config/start-gate.json" ;;
      relative) printf '{"project":{"facts":"relative.json"}}\n' > "$HOME_DIR/config/start-gate.json" ;;
      missing-facts) : ;;
      esac
      out=$(spawn_ship "$id")
      status=$?
      assert_spawned "$id" "$status" "$out"
      assert_contains "$out" "work class $class is never refused" "repair exemption was not reported"
    done
  done

  # shellcheck source=bin/fm-dod-lib.sh
  . "$ROOT/bin/fm-dod-lib.sh"
  # shellcheck source=bin/fm-start-gate-lib.sh
  . "$ROOT/bin/fm-start-gate-lib.sh"
  make_gate_case no-jq gate-no-jq fix
  mkdir "$CASE_DIR/no-jq"
  ln -s "$(command -v awk)" "$CASE_DIR/no-jq/awk"
  for class in fix revert live-breakage; do
    set_class "$HOME_DIR" gate-no-jq "$class"
    out=$(PATH="$CASE_DIR/no-jq" fm_start_gate_admit "$HOME_DIR/config/start-gate.json" project "$HOME_DIR/data/gate-no-jq/prep.md" 2>&1)
    status=$?
    expect_code 0 "$status" "repair must pass without jq"
    assert_contains "$out" "work class $class is never refused" "missing-jq repair exemption was not reported"
  done
  set_class "$HOME_DIR" gate-no-jq feature
  out=$(PATH="$CASE_DIR/no-jq" fm_start_gate_admit "$HOME_DIR/config/start-gate.json" project "$HOME_DIR/data/gate-no-jq/prep.md" 2>&1)
  status=$?
  expect_code 1 "$status" "feature must refuse without jq"
  assert_contains "$out" "jq is required" "missing-jq feature refusal was not diagnosed"
  pass "all repair classes bypass malformed configuration, bad locators, missing facts, and missing jq"
}

test_classification_preserves_internal_whitespace() {
  local class id out status n=0
  for class in 'f eature' 'f ix' 'r evert' 'live- breakage' $'f\tix'; do
    n=$((n + 1))
    id="gate-class-$n"
    make_gate_case "class-$n" "$id" "$class"
    write_facts '[]'
    out=$(spawn_ship "$id")
    status=$?
    assert_refused "$id" "$status" "$out" "must declare one Tier line '- Work class:"
  done
  for class in feature fix revert live-breakage; do
    n=$((n + 1))
    id="gate-class-$n"
    make_gate_case "class-$n" "$id" $' \t'"$class"$' \t'
    write_facts '[]'
    out=$(spawn_ship "$id")
    status=$?
    assert_spawned "$id" "$status" "$out"
  done
  pass "internal class whitespace is invalid; surrounding whitespace preserves canonical classes"
}

test_fact_clock_and_reconciled_state_contract() {
  local spec kind id out status real_date n=0
  real_date=$(command -v date)
  for spec in future stale boundary; do
    id="gate-clock-$spec"
    make_gate_case "clock-$spec" "$id"
    cat > "$FAKEBIN_DIR/date" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 1 ] && [ "\$1" = +%s ]; then
  printf '%s\n' "$NOW"
else
  exec "$real_date" "\$@"
fi
SH
    chmod +x "$FAKEBIN_DIR/date"
    case "$spec" in
    future) write_facts '[]' "$((NOW + 1))" ;;
    stale) write_facts '[]' "$((NOW - 901))" ;;
    boundary) write_facts '[]' "$((NOW - 900))" ;;
    esac
    out=$(spawn_ship "$id")
    status=$?
    case "$spec" in
    future) assert_refused "$id" "$status" "$out" "generated_at is in the future" ;;
    stale) assert_refused "$id" "$status" "$out" "over the 900s limit" ;;
    boundary) assert_spawned "$id" "$status" "$out" ;;
    esac
  done
  for kind in main-failure frozen-machine; do
    n=$((n + 1))
    id="gate-state-$n"
    make_gate_case "state-$n" "$id"
    write_facts "[{\"id\":\"cause\",\"kind\":\"$kind\",\"detail\":\"broken\",\"owner_task\":\"repair\",\"owner_state\":\"validating\"}]"
    out=$(spawn_ship "$id")
    status=$?
    assert_refused "$id" "$status" "$out" "no worker on $kind cause"
  done
  pass "facts after now or older than 900 seconds refuse; only reconciled working covers causes"
}

test_inherited_map_controls_feature_admission() {
  local id=gate-inherited out status primary remote_home bytes hash
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  make_gate_case inherited "$id"
  primary="$CASE_DIR/primary-config"
  remote_home="$CASE_DIR/remote-home"
  mkdir -p "$primary" "$remote_home/state"
  cp "$HOME_DIR/config/start-gate.json" "$primary/start-gate.json"
  printf '{}\n' > "$HOME_DIR/config/start-gate.json"
  propagate_inheritable_config "$primary" "$HOME_DIR/config" || fail "local map inheritance failed"
  cmp -s "$primary/start-gate.json" "$HOME_DIR/config/start-gate.json" || fail "local map bytes were not inherited"
  write_facts "$UNOWNED"
  out=$(spawn_ship "$id")
  status=$?
  assert_refused "$id" "$status" "$out" "no worker on main-failure"

  bytes=$(wc -c < "$primary/start-gate.json" | tr -d ' ')
  hash=$(fm_inherit_sha256 "$primary/start-gate.json")
  out=$(FM_HOME="$remote_home" FM_STATE_OVERRIDE="$remote_home/state" bash "$ROOT/bin/fm-remote-inherit.sh" \
    put config/start-gate.json "$bytes" "$hash" 1 < "$primary/start-gate.json" 2>&1) || fail "remote map inheritance failed: $out"
  cmp -s "$primary/start-gate.json" "$remote_home/config/start-gate.json" || fail "remote map bytes were not inherited"
  : > "$CASE_DIR/empty"
  hash=$(fm_inherit_sha256 "$CASE_DIR/empty")
  out=$(FM_HOME="$remote_home" FM_STATE_OVERRIDE="$remote_home/state" bash "$ROOT/bin/fm-remote-inherit.sh" \
    absent config/start-gate.json 0 "$hash" 2 2>&1) || fail "remote map absence failed: $out"
  assert_absent "$remote_home/config/start-gate.json" "remote map absence was not mirrored"

  rm "$primary/start-gate.json"
  propagate_inheritable_config "$primary" "$HOME_DIR/config" || fail "local map absence failed"
  assert_absent "$HOME_DIR/config/start-gate.json" "local map absence was not mirrored"
  set_class "$HOME_DIR" "$id" none
  out=$(spawn_ship "$id")
  status=$?
  assert_spawned "$id" "$status" "$out"
  assert_not_contains "$out" "start gate" "absent inherited map produced gate output"
  pass "local and remote inheritance copy and remove the map; inherited unhealthy facts refuse features"
}

test_owner_task_identity_is_validated() {
  local kind state owner n=0 id out status
  for kind in main-failure frozen-machine; do
    for state in working validating paused; do
      for owner in '" "' '"a b"' '".hidden"' '"../task"' '"a/b"' '"a\nb"' '"a\u0000b"' '"fix-\u00e9"' 'false' '1' '[]' '{}'; do
        n=$((n + 1))
        id="gate-owner-$n"
        make_gate_case "owner-$n" "$id"
        write_facts "[{\"id\":\"cause\",\"kind\":\"$kind\",\"detail\":\"broken\",\"owner_task\":$owner,\"owner_state\":\"$state\"}]"
        out=$(spawn_ship "$id")
        status=$?
        assert_refused "$id" "$status" "$out" "facts unknown: a cause lacks"
      done
    done
    for owner in null '""'; do
      n=$((n + 1))
      id="gate-owner-$n"
      make_gate_case "owner-$n" "$id"
      write_facts "[{\"id\":\"cause\",\"kind\":\"$kind\",\"detail\":\"broken\",\"owner_task\":$owner,\"owner_state\":\"working\"}]"
      out=$(spawn_ship "$id")
      status=$?
      assert_refused "$id" "$status" "$out" "no worker on $kind cause"
      assert_not_contains "$out" "facts unknown" "empty ownership was treated as malformed"
    done
    for owner in '"Main_9.fix-2"' '"_"' '"-"'; do
      n=$((n + 1))
      id="gate-owner-$n"
      make_gate_case "owner-$n" "$id"
      write_facts "[{\"id\":\"cause\",\"kind\":\"$kind\",\"detail\":\"broken\",\"owner_task\":$owner,\"owner_state\":\"working\"}]"
      out=$(spawn_ship "$id")
      status=$?
      assert_spawned "$id" "$status" "$out"
    done
  done
  pass "both cause kinds validate owner task identity independently of worker state"
}

# G5: an ungated project, an absent config and a scout keep today's contract
# with no class line at all.
test_ungated_paths_keep_existing_contract() {
  local id out status
  id=gate-g5-other
  make_gate_case g5-other "$id" none
  write_facts "$UNOWNED"
  printf '{"Q":{"facts":"%s"}}\n' "$FACTS" > "$HOME_DIR/config/start-gate.json"
  out=$(spawn_ship "$id")
  status=$?
  assert_spawned "$id" "$status" "$out"
  assert_not_contains "$out" "start gate" "an ungated project heard from the start gate"

  id=gate-g5-absent
  make_gate_case g5-absent "$id" none
  rm -f "$HOME_DIR/config/start-gate.json"
  out=$(spawn_ship "$id")
  status=$?
  assert_spawned "$id" "$status" "$out"

  id=gate-g5-scout
  make_gate_case g5-scout "$id" none
  write_facts "$UNOWNED"
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout)
  status=$?
  assert_spawned "$id" "$status" "$out"
  pass "G5 ungated projects, an absent config and scouts are unaffected"
}

test_feature_refused_naming_each_uncovered_cause
test_repairs_pass_same_unhealthy_facts
test_covered_or_clear_facts_permit_feature
test_unknown_facts_and_class_are_diagnosed
test_invalid_configuration_is_refused
test_repairs_bypass_configuration_and_dependency_failures
test_classification_preserves_internal_whitespace
test_fact_clock_and_reconciled_state_contract
test_inherited_map_controls_feature_admission
test_owner_task_identity_is_validated
test_ungated_paths_keep_existing_contract

echo "# all fm-spawn-start-gate tests passed"
