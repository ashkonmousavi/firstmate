#!/usr/bin/env bash
# Slice admission for fresh ship spawns (bin/fm-spawn-admission-lib.sh
# fm_spawn_slice_admit): a home with config/slicing.json runs the slice
# validator's gate before any worktree or record exists. Observe mode reports
# and launches; enforce mode refuses a ship whose task, brief and prep carry no
# valid SLICE line. These drive the real spawn path with a fake terminal.
# The stub validator below stands in for the vertical-slicing skill's
# scripts/slicing.py gate (exit 0 ok or not enforced, 1 fail, 2 unknown); the
# last case runs the installed validator itself when it is present.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-slice-gate)
STUB="$TMP_ROOT/stub-slicing.py"
cat > "$STUB" <<'PY'
import json, os, re, sys
args = sys.argv[1:]
with open(os.environ['FM_TEST_SLICE_ARGV'], 'a') as log:
    log.write(json.dumps(args) + '\n')
opt = lambda name: args[args.index(name) + 1]
home = opt('--home')
mode = json.load(open(os.path.join(home, 'config/slicing.json')))['mode']
texts = [args[i + 1] for i, a in enumerate(args) if a == '--text']
declared = any(re.search(r'^\s*SLICE:\s*\S+/\S+ \| \S', open(t).read(), re.M) for t in texts)
state = 'ok' if declared else 'fail'
reasons = [] if declared else [{'code': 'missing-slice', 'source': texts[0], 'detail': 'add a SLICE identity'}]
print(json.dumps({'schema': 'slice-result.v1', 'state': state, 'reasons': reasons, 'enforced': mode == 'enforce'}))
sys.exit(1 if mode == 'enforce' and state != 'ok' else 0)
PY

# make_case <name> <id> <mode|none> [<slice-line>]: a home with a slicing policy
# (none: no policy file), a project with a pooled worktree, and a filled brief.
make_case() {
  local name=$1 id=$2 mode=$3 line=${4-}
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/proj"
  POOL_DIR="$CASE_DIR/pool"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" codex
  printf -- '- proj [direct-PR] - fixture (added 2026-01-01)\n' > "$HOME_DIR/data/projects.md"
  git init --quiet -b main "$PROJECT_DIR"
  printf 'base\n' > "$PROJECT_DIR/README.md"
  git -C "$PROJECT_DIR" add README.md
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR" "$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  fm_test_spawn_brief "$HOME_DIR" "$id" "Build the slice-gated change."
  [ -z "$line" ] || printf '\n# Slice\n%s\n' "$line" >> "$HOME_DIR/data/$id/brief.md"
  if [ "$mode" != none ]; then
    printf '{"schema":"slice-policy.v1","mode":"%s","projects":["proj"],"catalog":"%s","revision":"r1","activated_at":"2026-11-05T00:00:00Z","home":"test"}\n' \
      "$mode" "$CASE_DIR/catalog.json" > "$HOME_DIR/config/slicing.json"
  fi
  printf '{"schema":"slice-catalog.v1","revision":"r1","slices":[{"id":"ops/demo","kind":"operational","journey":"operational","step":"demo","entrance":"operational","outcome":"demo outcome","owner":"test:%s","checkpoint":"fixture","acceptance_source":"fixture"}]}\n' \
    "$id" > "$CASE_DIR/catalog.json"
  : > "$CASE_DIR/argv.log"
}

run_spawn() {  # <id> [args...]
  local id=$1
  shift
  FM_SLICE_VALIDATOR=${VALIDATOR-$STUB} FM_TEST_SLICE_ARGV="$CASE_DIR/argv.log" \
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" --mode direct-PR --yolo off "$@"
}

test_enforce_refuses_a_ship_without_a_slice_line() {
  local id=slice-enforce-missing out status
  make_case enforce-missing "$id" enforce
  out=$(run_spawn "$id"); status=$?
  [ "$status" -ne 0 ] || fail "an enforce home launched a ship whose brief has no SLICE line"$'\n'"$out"
  assert_contains "$out" "slice admission" "the refusal did not name slice admission"
  assert_contains "$out" "missing-slice" "the refusal did not carry the validator's reason"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the refused spawn still published a task record"
  assert_contains "$(cat "$CASE_DIR/argv.log")" '"gate", "--home", "'"$HOME_DIR"'", "--project", "proj", "--kind", "ship", "--task-id", "'"$id"'"' \
    "the gate was not asked about this home, project, kind and task"
  assert_contains "$(cat "$CASE_DIR/argv.log")" "\"--text\", \"$HOME_DIR/data/$id/brief.md\"" "the gate did not read the task's brief"
  pass "fm-spawn: an enforce home refuses a fresh ship with no SLICE line before any record exists"
}

test_enforce_admits_a_ship_with_a_slice_line_and_reads_its_prep() {
  local id=slice-enforce-ok out status
  make_case enforce-ok "$id" enforce 'SLICE: ops/demo | demo outcome | role=owner'
  printf '# Prep\nSLICE: ops/demo | demo outcome | role=owner\n' > "$HOME_DIR/data/$id/prep.md"
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "an enforce home should launch a ship with a valid SLICE line"$'\n'"$out"
  assert_contains "$(cat "$CASE_DIR/argv.log")" "\"--text\", \"$HOME_DIR/data/$id/prep.md\"" "the gate did not read the task's prep"
  pass "fm-spawn: an enforce home launches a ship whose brief and prep declare its slice"
}

test_observe_reports_and_launches() {
  local id=slice-observe out status
  make_case observe "$id" observe
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "an observe home must never stop a spawn"$'\n'"$out"
  assert_contains "$out" "missing-slice" "observe mode did not report what enforce would refuse"
  [ -s "$CASE_DIR/argv.log" ] || fail "observe mode did not run the gate"
  pass "fm-spawn: an observe home reports a missing SLICE line and launches"
}

test_unconfigured_scout_and_missing_validator() {
  local id out status
  id=slice-unconfigured
  make_case unconfigured "$id" none
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "a home with no slicing policy should launch"$'\n'"$out"
  [ ! -s "$CASE_DIR/argv.log" ] || fail "a home with no slicing policy still ran the gate"

  id=slice-scout
  make_case scout "$id" enforce
  out=$(FM_SLICE_VALIDATOR=$STUB FM_TEST_SLICE_ARGV="$CASE_DIR/argv.log" \
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" --scout); status=$?
  expect_code 0 "$status" "slice admission applies to fresh ships only, not scouts"$'\n'"$out"
  [ ! -s "$CASE_DIR/argv.log" ] || fail "a scout spawn ran the ship slice gate"

  id=slice-novalidator-enforce
  make_case novalidator-enforce "$id" enforce 'SLICE: ops/demo | demo outcome'
  out=$(VALIDATOR="$CASE_DIR/absent.py" run_spawn "$id"); status=$?
  [ "$status" -ne 0 ] || fail "an enforce home launched although its slice validator is missing"$'\n'"$out"
  assert_contains "$out" "absent.py" "the refusal did not name the missing validator"

  id=slice-novalidator-observe
  make_case novalidator-observe "$id" observe
  out=$(VALIDATOR="$CASE_DIR/absent.py" run_spawn "$id"); status=$?
  expect_code 0 "$status" "an observe home with no validator must still launch"$'\n'"$out"
  assert_contains "$out" "absent.py" "observe mode did not report the missing validator"
  pass "fm-spawn: no policy and scouts bypass; a missing validator refuses in enforce and is reported in observe"
}

# The installed vertical-slicing validator, when present: the same refusal and
# the malformed-policy refusal its contract defines (FM_TEST_SLICE_VALIDATOR
# overrides the path; an absent validator is reported, never a silent pass).
test_installed_validator() {
  local real=${FM_TEST_SLICE_VALIDATOR:-${FM_TEST_REAL_HOME:-$HOME}/.config/skills-master/.agents/skills/vertical-slicing/scripts/slicing.py}
  local id out status
  if [ ! -r "$real" ]; then
    echo "skip: installed slice validator not found at $real (capability skip; the stub cases above still ran)"
    return 0
  fi
  id=slice-real-missing
  make_case real-missing "$id" enforce
  out=$(VALIDATOR=$real run_spawn "$id"); status=$?
  [ "$status" -ne 0 ] || fail "the installed validator admitted a ship with no SLICE line in enforce"$'\n'"$out"
  assert_contains "$out" "missing-slice" "the installed validator's refusal did not name missing-slice"

  id=slice-real-malformed
  make_case real-malformed "$id" enforce 'SLICE: ops/demo | demo outcome'
  printf '{"schema":"slice-policy.v1","mode":"enforce","projects":["proj"]}\n' > "$HOME_DIR/config/slicing.json"
  out=$(VALIDATOR=$real run_spawn "$id"); status=$?
  [ "$status" -ne 0 ] || fail "the installed validator admitted a ship under a malformed enforce policy"$'\n'"$out"
  assert_contains "$out" "policy-unavailable" "the malformed-policy refusal did not name the policy"

  id=slice-real-observe
  make_case real-observe "$id" observe
  out=$(VALIDATOR=$real run_spawn "$id"); status=$?
  expect_code 0 "$status" "the installed validator stopped a spawn in observe mode"$'\n'"$out"
  assert_contains "$out" "missing-slice" "observe mode with the installed validator did not report missing-slice"
  pass "fm-spawn: the installed slice validator refuses a missing SLICE line and a malformed policy in enforce, and only reports in observe"
}

FM_TEST_REAL_HOME=$HOME
test_enforce_refuses_a_ship_without_a_slice_line
test_enforce_admits_a_ship_with_a_slice_line_and_reads_its_prep
test_observe_reports_and_launches
test_unconfigured_scout_and_missing_validator
test_installed_validator

echo "# all fm-spawn-slice-gate tests passed"
