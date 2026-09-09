#!/usr/bin/env bash
# tests/fm-classify-parked.test.sh - the two pieces bin/fm-classify-lib.sh owns
# for parked lanes and the declared-wait cadence:
#
#   1. config/pause-resurface-secs (fm_pause_resurface_secs), the LOCAL,
#      gitignored per-home override for FM_PAUSE_RESURFACE_SECS documented in
#      docs/configuration.md. ONE resolver backs both bin/fm-watch.sh and
#      bin/fm-supervise-daemon.sh so the effective declared-wait cadence cannot
#      drift between the two supervisors, exactly as
#      tests/fm-classify-stale-escalate-secs.test.sh pins for the wedge
#      threshold.
#   2. fm_task_is_parked / fm_task_parked_since / fm_task_parked_reason, the
#      durable-record predicate every consumer reads instead of guessing a
#      parked lane from a live terminal or a stale status line.
#
# These drive the real functions over crafted directories rather than asserting
# their source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-parked-tests)

case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# --- config/pause-resurface-secs -------------------------------------------

# Proves: with no config file the resolver defers to the env var, then to the
# caller's own default - it never invents a cadence of its own.
test_absent_config_falls_through_to_env_then_default() {
  local dir
  dir=$(case_dir absent)
  [ "$(fm_pause_resurface_secs "$dir" 3600)" = 3600 ] \
    || fail "an absent config file did not fall through to the caller's default"
  [ "$(FM_PAUSE_RESURFACE_SECS=999 fm_pause_resurface_secs "$dir" 3600)" = 999 ] \
    || fail "an absent config file did not fall through to FM_PAUSE_RESURFACE_SECS"
  pass "an absent config/pause-resurface-secs falls through to the env var, then the default"
}

# Proves: the file wins over the environment, which is the whole point of the
# knob - an operator retunes a home without exporting into every backend.
test_valid_config_overrides_the_env_var() {
  local dir
  dir=$(case_dir valid-overrides-env)
  printf '1800\n' > "$dir/pause-resurface-secs"
  [ "$(FM_PAUSE_RESURFACE_SECS=999 fm_pause_resurface_secs "$dir" 3600)" = 1800 ] \
    || fail "a valid config file did not override FM_PAUSE_RESURFACE_SECS"
  [ "$(fm_pause_resurface_secs "$dir" 3600)" = 1800 ] \
    || fail "a valid config file was not read with no env var set"
  pass "a valid config/pause-resurface-secs overrides FM_PAUSE_RESURFACE_SECS for this home"
}

test_config_value_tolerates_surrounding_whitespace() {
  local dir
  dir=$(case_dir whitespace)
  printf '  240 \n' > "$dir/pause-resurface-secs"
  [ "$(fm_pause_resurface_secs "$dir" 3600)" = 240 ] \
    || fail "surrounding whitespace in the config value was not tolerated"
  pass "config/pause-resurface-secs tolerates surrounding whitespace"
}

# Proves: a malformed value is never read as "re-surface immediately" or "never
# re-surface" - it falls through, so a typo cannot silently disable the recheck
# a forgotten declared wait depends on.
test_malformed_config_falls_through_rather_than_erroring() {
  local dir
  dir=$(case_dir malformed)
  printf 'not-a-number\n' > "$dir/pause-resurface-secs"
  [ "$(FM_PAUSE_RESURFACE_SECS=999 fm_pause_resurface_secs "$dir" 3600)" = 999 ] \
    || fail "a non-numeric config value was not rejected in favor of the env var"

  printf '0\n' > "$dir/pause-resurface-secs"
  [ "$(fm_pause_resurface_secs "$dir" 3600)" = 3600 ] \
    || fail "a zero config value was not rejected in favor of the default"

  printf '' > "$dir/pause-resurface-secs"
  [ "$(fm_pause_resurface_secs "$dir" 3600)" = 3600 ] \
    || fail "an empty config file was not rejected in favor of the default"

  printf -- '-5\n' > "$dir/pause-resurface-secs"
  [ "$(fm_pause_resurface_secs "$dir" 3600)" = 3600 ] \
    || fail "a negative config value was not rejected in favor of the default"
  pass "a malformed config/pause-resurface-secs falls through to the env var, then the default, never erroring"
}

# Proves the two knobs are independent: setting one must not move the other,
# which is the failure a single shared file or a copy-pasted key name produces.
test_the_two_cadence_knobs_are_independent() {
  local dir
  dir=$(case_dir independent)
  printf '120\n' > "$dir/stale-escalate-secs"
  [ "$(fm_pause_resurface_secs "$dir" 3600)" = 3600 ] \
    || fail "config/stale-escalate-secs changed the declared-wait cadence"
  printf '1800\n' > "$dir/pause-resurface-secs"
  [ "$(fm_stale_escalate_secs "$dir" 240)" = 120 ] \
    || fail "config/pause-resurface-secs changed the wedge threshold"
  pass "config/pause-resurface-secs and config/stale-escalate-secs are independent"
}

# --- the parked-record predicate -------------------------------------------

write_meta() {  # <state-dir> <id> [extra-line]...
  local state=$1 id=$2
  shift 2
  mkdir -p "$state"
  {
    printf 'window=fmses:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=/tmp/wt-%s\n' "$id"
    printf 'project=/tmp/proj\n'
    printf 'harness=claude\n'
    printf 'kind=ship\n'
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$state/$id.meta"
}

# Proves: an ordinary running lane is not parked. This is the case every
# supervision path takes, so a predicate that answered yes here would silence
# the whole fleet.
test_an_ordinary_task_is_not_parked() {
  local state
  state=$(case_dir not-parked)
  write_meta "$state" t1
  fm_task_is_parked "$state" t1 \
    && fail "a task with no parked marker was reported parked"
  [ -z "$(fm_task_parked_since "$state" t1)" ] \
    || fail "an unparked task reported a parked timestamp"
  pass "a task with no parked marker is not parked"
}

# Proves: the marker is read from the durable record, and its reason and
# timestamp come back for the reader to present.
test_a_parked_marker_is_recognized_with_its_reason() {
  local state
  state=$(case_dir parked)
  write_meta "$state" t2 'parked=1788900000' 'parked_reason=resting while the fleet is over capacity'
  fm_task_is_parked "$state" t2 \
    || fail "a parked marker was not recognized"
  [ "$(fm_task_parked_since "$state" t2)" = 1788900000 ] \
    || fail "the parked timestamp was not returned: $(fm_task_parked_since "$state" t2)"
  [ "$(fm_task_parked_reason "$state" t2)" = "resting while the fleet is over capacity" ] \
    || fail "the parked reason was not returned: $(fm_task_parked_reason "$state" t2)"
  pass "a parked marker is recognized from the durable record with its reason"
}

# Proves: the predicate identifies a parked lane whose last status line is an
# ordinary `working:`. This is the real shape - a worker exits without writing a
# terminal status - and it is exactly why no status vocabulary could do this job.
test_a_parked_lane_is_recognized_despite_a_working_status_line() {
  local state
  state=$(case_dir parked-working-log)
  write_meta "$state" t3 'parked=1788900000'
  printf 'working: mid-refactor\n' > "$state/t3.status"
  fm_task_is_parked "$state" t3 \
    || fail "a parked lane with a working: status line was not recognized"
  pass "a parked lane is recognized even though its last status line reads working"
}

# Proves: a malformed or empty marker is not parked. Fail-closed toward ordinary
# supervision - a corrupt record must never silence a lane.
test_a_malformed_marker_is_not_parked() {
  local state
  state=$(case_dir malformed-marker)
  write_meta "$state" t4 'parked='
  fm_task_is_parked "$state" t4 && fail "an empty parked marker was treated as parked"
  write_meta "$state" t5 'parked=not-a-number'
  fm_task_is_parked "$state" t5 && fail "a non-numeric parked marker was treated as parked"
  write_meta "$state" t6 'parked=0'
  fm_task_is_parked "$state" t6 && fail "a zero parked marker was treated as parked"
  pass "a malformed parked marker falls back to ordinary supervision"
}

test_a_missing_record_is_not_parked() {
  local state
  state=$(case_dir no-record)
  fm_task_is_parked "$state" nosuch && fail "a task with no record was reported parked"
  pass "a task with no durable record is not parked"
}

test_absent_config_falls_through_to_env_then_default
test_valid_config_overrides_the_env_var
test_config_value_tolerates_surrounding_whitespace
test_malformed_config_falls_through_rather_than_erroring
test_the_two_cadence_knobs_are_independent
test_an_ordinary_task_is_not_parked
test_a_parked_marker_is_recognized_with_its_reason
test_a_parked_lane_is_recognized_despite_a_working_status_line
test_a_malformed_marker_is_not_parked
test_a_missing_record_is_not_parked
