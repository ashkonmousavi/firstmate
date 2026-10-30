#!/usr/bin/env bash
# tests/fm-hold-release.test.sh - behavior tests for the structured hold
# release condition: the wrapper's --release-on flag and kind-external
# refusal, the record kept beside the hold, the evaluator's one wake per met
# condition, the keyed decision that stays open until the hold is released or
# re-held.
#
# Everything runs against a scratch home with the real tasks-axi markdown
# backend; pr lookups go through a fake gh, marker conditions through real
# files. No network, no forge.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-hold-release)
WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
CAPTAIN="$ROOT/bin/fm-captain-hold.sh"
LIB="$ROOT/bin/fm-hold-release-lib.sh"
export FM_TEST_HOLD_WRAPPER="$WRAPPER"

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

run_axi() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$WRAPPER" "$@"
}

seed_hold() {
  local home=$1 id=$2 condition=$3
  run_axi "$home" add "$id" "$id" --repo demo >/dev/null \
    && run_axi "$home" hold "$id" --reason waiting --kind external --release-on "$condition" >/dev/null
}

# run_lib <home> <function> [args...]: run one evaluator call in a subshell
# with the library sourced and the scratch home's environment, capturing
# stdout.
run_lib() {
  local home=$1 fn=$2
  shift 2
  (
    # Exported on their own lines: bash 5.2 drops a `VAR=x .` prefix once the
    # dot returns, and the evaluator's per-task reads must keep seeing this
    # home for the whole subshell.
    # shellcheck disable=SC2030  # the export is deliberately local to this subshell
    FM_HOME="$home"
    # shellcheck disable=SC2030  # the override is deliberately local to this subshell
    FM_STATE_OVERRIDE="$home/state"
    FM_DATA_OVERRIDE="$home/data"
    export FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE
    # shellcheck source=bin/fm-hold-release-lib.sh disable=SC1091
    . "$LIB"
    "$fn" "$@"
  )
}

open_decisions() {  # <home> <task>
  (
    # shellcheck source=bin/fm-classify-lib.sh disable=SC1091
    . "$ROOT/bin/fm-classify-lib.sh"
    status_open_decisions "$1/state/$2.status"
  )
}

# --- condition syntax --------------------------------------------------------

test_condition_syntax() {
  local out
  out=$(run_lib x fm_hold_release_valid 'pr:owner/repo#42') \
    || fail "pr:owner/repo#42 must be valid"
  [ "$out" = "pr:owner/repo#42" ] || fail "pr condition must normalize verbatim: $out"
  out=$(run_lib x fm_hold_release_valid "marker:$TMP_ROOT/flag") \
    || fail "marker:<absolute> must be valid"
  run_lib x fm_hold_release_valid 'pr:owner#42' >/dev/null \
    && fail "pr without a repo must be refused"
  run_lib x fm_hold_release_valid 'pr:owner/repo#0' >/dev/null \
    && fail "pr number 0 must be refused"
  run_lib x fm_hold_release_valid 'pr:owner/repo#01' >/dev/null \
    && fail "a zero-padded pr number must be refused"
  run_lib x fm_hold_release_valid 'pr:owner/repo#7' >/dev/null \
    || fail "a single-digit pr number must be valid"
  run_lib x fm_hold_release_valid 'marker:relative/path' >/dev/null \
    && fail "marker with a relative path must be refused"
  run_lib x fm_hold_release_valid 'when:tuesday' >/dev/null \
    && fail "an unknown condition kind must be refused"
  out=$(run_lib x fm_hold_release_pr_url 'pr:owner/repo#42') \
    || fail "pr url derivation must work"
  [ "$out" = "https://github.com/owner/repo/pull/42" ] || fail "pr url wrong: $out"
  pass "hold-release: condition syntax accepts exactly the two documented forms"
}

# --- wrapper refusal and record lifecycle -----------------------------------

test_external_hold_refused_without_condition() {
  local home out rc
  home=$(make_home refused)
  run_axi "$home" add t1 "one" --repo demo >/dev/null
  out=$(run_axi "$home" hold t1 --reason "waiting" --kind external 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "undated kind-external hold must be refused"
  assert_contains "$out" "--release-on" "the refusal names the structured field"
  run_axi "$home" show t1 | grep -q '^  held: no$' \
    || fail "a refused hold must leave the row unheld"
  pass "hold-release: kind-external hold without --release-on/--until is refused"
}

test_hold_with_release_on_records_the_condition() {
  local home
  home=$(make_home record)
  run_axi "$home" add t1 "one" --repo demo >/dev/null
  run_axi "$home" hold t1 --reason "awaiting activation" --kind external \
    --release-on "marker:$TMP_ROOT/record.flag" >/dev/null \
    || fail "hold with --release-on must succeed"
  run_axi "$home" show t1 | grep -q '^  held: yes$' || fail "row must be held"
  [ "$(run_axi "$home" show t1 | sed -n 's/^  hold_reason: //p' | jq -r .)" = 'awaiting activation' ] \
    || fail "the condition must not leak into the hold reason"
  assert_grep "condition=marker:$TMP_ROOT/record.flag" "$home/state/hold-releases/t1" \
    "the record stores the structured condition beside the hold"
  pass "hold-release: --release-on stores the condition without touching the reason"
}

test_other_hold_kinds_still_work_without_a_condition() {
  local home rc
  home=$(make_home kinds)
  run_axi "$home" add t1 "one" --repo demo >/dev/null
  rc=0
  run_axi "$home" hold t1 --reason "plain wait" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an undated kindless hold must be refused"
  run_axi "$home" hold t1 --reason "dated wait" --until 2099-01-01 >/dev/null \
    || fail "a dated kindless hold must succeed"
  run_axi "$home" hold t1 --reason "parked" --kind parked >/dev/null \
    || fail "a non-external kind stays allowed without a condition"
  run_axi "$home" hold t1 --reason "dated" --kind external --until 2099-01-01 >/dev/null \
    || fail "a dated external hold stays allowed"
  [ ! -e "$home/state/hold-releases/t1" ] || fail "no record without --release-on"
  pass "hold-release: kindless and external holds require an event or date"
}

test_rehold_and_unhold_manage_the_record() {
  local home
  home=$(make_home rehold)
  run_axi "$home" add t1 "one" --repo demo >/dev/null
  run_axi "$home" hold t1 --reason "first" --kind external \
    --release-on "marker:$TMP_ROOT/rehold.flag" >/dev/null
  run_axi "$home" hold t1 --reason "second" --kind external --until 2099-01-01 >/dev/null \
    || fail "re-hold without --release-on must succeed"
  [ ! -e "$home/state/hold-releases/t1" ] \
    || fail "re-holding without --release-on must drop the record"
  run_axi "$home" hold t1 --reason "third" --kind external \
    --release-on "marker:$TMP_ROOT/rehold2.flag" >/dev/null
  run_axi "$home" unhold t1 >/dev/null || fail "unhold must succeed"
  [ ! -e "$home/state/hold-releases/t1" ] || fail "unhold must drop the record"
  pass "hold-release: re-hold and unhold keep the record exactly as long as the hold"
}

# --- evaluation and the keyed decision --------------------------------------

test_evaluation_wakes_once_and_keeps_the_decision_open() {
  local home out
  home=$(make_home evaluate)
  run_axi "$home" add t1 "one" --repo demo >/dev/null
  run_axi "$home" hold t1 --reason "awaiting activation" --kind external \
    --release-on "marker:$TMP_ROOT/evaluate.flag" >/dev/null
  out=$(run_lib "$home" fm_hold_release_evaluate "$home/state")
  [ -z "$out" ] || fail "an unmet condition must print nothing: $out"
  : > "$TMP_ROOT/evaluate.flag"
  out=$(run_lib "$home" fm_hold_release_evaluate "$home/state")
  [ "$out" = "hold condition met: t1 marker:$TMP_ROOT/evaluate.flag" ] \
    || fail "a met condition must print exactly one wake line: $out"
  assert_grep 'blocked [key=hold-release-t1]' "$home/state/t1.status" \
    "the met condition opens the keyed decision"
  out=$(run_lib "$home" fm_hold_release_evaluate "$home/state")
  [ -z "$out" ] || fail "a second sweep must not repeat the wake: $out"
  open_decisions "$home" t1 | grep -q '^hold-release-t1	blocked' \
    || fail "the decision must still be open in the fold"
  pass "hold-release: one wake per met condition, decision stays open"
}

test_release_and_rehold_close_the_decision() {
  local home
  home=$(make_home close)
  run_axi "$home" add t1 "one" --repo demo >/dev/null
  run_axi "$home" hold t1 --reason "awaiting activation" --kind external \
    --release-on "marker:$TMP_ROOT/close.flag" >/dev/null
  : > "$TMP_ROOT/close.flag"
  run_lib "$home" fm_hold_release_evaluate "$home/state" >/dev/null
  # A foreign close note must not clear the reserved key.
  printf '%s\n' 'resolved [key=hold-release-t1] [at=1]: answered: never mind' \
    >> "$home/state/t1.status"
  open_decisions "$home" t1 | grep -q '^hold-release-t1' \
    || fail "a foreign close note must not clear a reserved hold-release key"
  run_axi "$home" unhold t1 >/dev/null
  open_decisions "$home" t1 | grep -q '^hold-release-t1' \
    && fail "unhold must close the open decision"
  assert_grep 'resolved [key=hold-release-t1]' "$home/state/t1.status" \
    "the wrapper writes the reserved-vocabulary close"
  pass "hold-release: unhold closes the decision; foreign notes cannot"
}

test_rehold_after_met_opens_a_new_episode() {
  local home out
  home=$(make_home episode)
  run_axi "$home" add t1 "one" --repo demo >/dev/null
  run_axi "$home" hold t1 --reason "first" --kind external \
    --release-on "marker:$TMP_ROOT/ep1.flag" >/dev/null
  : > "$TMP_ROOT/ep1.flag"
  run_lib "$home" fm_hold_release_evaluate "$home/state" >/dev/null
  run_axi "$home" hold t1 --reason "second wait" --kind external \
    --release-on "marker:$TMP_ROOT/ep2.flag" >/dev/null \
    || fail "re-hold with a fresh condition must succeed"
  open_decisions "$home" t1 | grep -q '^hold-release-t1' \
    && fail "the old episode's decision must close on re-hold"
  out=$(run_lib "$home" fm_hold_release_evaluate "$home/state")
  [ -z "$out" ] || fail "the new condition is unmet; no wake expected: $out"
  : > "$TMP_ROOT/ep2.flag"
  out=$(run_lib "$home" fm_hold_release_evaluate "$home/state")
  [ "$out" = "hold condition met: t1 marker:$TMP_ROOT/ep2.flag" ] \
    || fail "the new episode must wake exactly once: $out"
  pass "hold-release: a re-held condition starts a fresh episode"
}

test_closed_task_reconciles_its_record_away() {
  local home
  home=$(make_home closed)
  run_axi "$home" add t1 "one" --repo demo >/dev/null
  run_axi "$home" hold t1 --reason "awaiting activation" --kind external \
    --release-on "marker:$TMP_ROOT/closed.flag" >/dev/null
  : > "$TMP_ROOT/closed.flag"
  run_lib "$home" fm_hold_release_evaluate "$home/state" >/dev/null
  run_axi "$home" 'done' t1 >/dev/null || fail "closing the held row must work"
  run_lib "$home" fm_hold_release_evaluate "$home/state" >/dev/null
  [ ! -e "$home/state/hold-releases/t1" ] \
    || fail "a closed task must reconcile its record away"
  open_decisions "$home" t1 | grep -q '^hold-release-t1' \
    && fail "the decision must close when the row closed"
  pass "hold-release: a closed row reconciles record and decision away"
}

test_removed_task_reconciles_its_record_away() {
  local home out
  home=$(make_home removed)
  run_axi "$home" add t1 "one" --repo demo >/dev/null
  run_axi "$home" hold t1 --reason "awaiting activation" --kind external \
    --release-on "marker:$home/met" >/dev/null
  : > "$home/met"
  run_lib "$home" fm_hold_release_evaluate "$home/state" >/dev/null
  open_decisions "$home" t1 | grep -q '^hold-release-t1' \
    || fail "the met hold must open a decision before removal"
  run_axi "$home" rm t1 >/dev/null || fail "removing the held row must work"
  out=$(run_lib "$home" fm_hold_release_evaluate "$home/state") \
    || fail "reconciling a removed task must succeed"
  [ -z "$out" ] || fail "a removed task must not wake again: $out"
  [ ! -e "$home/state/hold-releases/t1" ] \
    || fail "a removed task must reconcile its record away"
  open_decisions "$home" t1 | grep -q '^hold-release-t1' \
    && fail "the decision must close when the row is removed"
  pass "hold-release: a removed row reconciles record and decision away"
}

test_show_override_distinguishes_missing_from_unreadable() {
  local home channel mode out
  for channel in stdout stderr; do
    home=$(make_home "show-$channel")
    run_axi "$home" add t1 "one" --repo demo >/dev/null
    run_axi "$home" hold t1 --reason "awaiting activation" --kind external \
      --release-on "marker:$home/met" >/dev/null
    : > "$home/met"
    cat > "$home/show" <<'SH'
#!/usr/bin/env bash
case "$(cat "$FM_HOME/show-mode")" in
  held)
    printf 'backend warning\n' >&2
    "$FM_TEST_HOLD_WRAPPER" show "$1"
    ;;
  unknown) printf 'code: BACKEND_UNAVAILABLE\n' >&2; exit 1 ;;
  malformed) printf '  state: queued\n  held: yes\n  hold_release_on: {}\n  hold_release_episode: "bad"\n' ;;
  stdout) printf 'code: NOT_FOUND\n'; exit 1 ;;
  stderr) printf 'code: NOT_FOUND\n' >&2; exit 1 ;;
esac
SH
    chmod +x "$home/show"
    printf 'held\n' > "$home/show-mode"
    out=$(FM_HOLD_RELEASE_SHOW_CMD="$home/show" \
      run_lib "$home" fm_hold_release_evaluate "$home/state") \
      || fail "a successful show with a stderr warning must be readable"
    [ "$out" = "hold condition met: t1 marker:$home/met" ] \
      || fail "a readable held task must publish its met condition: $out"
    for mode in unknown malformed held; do
      printf '%s\n' "$mode" > "$home/show-mode"
      out=$(FM_HOLD_RELEASE_SHOW_CMD="$home/show" \
        run_lib "$home" fm_hold_release_evaluate "$home/state") \
        || fail "a $mode read must leave reconciliation retryable"
      [ -z "$out" ] || fail "a $mode read must not repeat the wake: $out"
      [ -e "$home/state/hold-releases/t1" ] \
        || fail "a $mode read must preserve the release record"
      open_decisions "$home" t1 | grep -q '^hold-release-t1' \
        || fail "a $mode read must preserve the open decision"
    done
    printf '%s\n' "$channel" > "$home/show-mode"
    out=$(FM_HOLD_RELEASE_SHOW_CMD="$home/show" \
      run_lib "$home" fm_hold_release_evaluate "$home/state") \
      || fail "NOT_FOUND on $channel must reconcile successfully"
    [ -z "$out" ] || fail "a missing task must not wake again: $out"
    [ ! -e "$home/state/hold-releases/t1" ] \
      || fail "NOT_FOUND on $channel must drop the release record"
    open_decisions "$home" t1 | grep -q '^hold-release-t1' \
      && fail "NOT_FOUND on $channel must close the decision"
  done
  pass "hold-release: show overrides preserve unknown reads and reconcile missing tasks"
}

test_pr_condition_reads_merge_state_through_gh() {
  local home fakebin out state
  home=$(make_home prcond)
  mkdir -p "$home/fakebin"
  fakebin="$home/fakebin"
  run_axi "$home" add t1 "one" --repo demo >/dev/null
  run_axi "$home" hold t1 --reason "awaiting merge" --kind external \
    --release-on 'pr:owner/repo#42' >/dev/null
  # fake gh <state>: records its arguments so the URL the evaluation reads is
  # asserted from the dispatcher-facing evidence, not from the lib's source.
  make_gh() {
    cat > "$fakebin/gh" <<GH
#!/usr/bin/env bash
printf '%s ' "\$@" >> '$fakebin/gh.args'
printf '\\n' >> '$fakebin/gh.args'
echo '$1'
GH
    chmod +x "$fakebin/gh"
  }
  # OPEN: not met.
  make_gh OPEN
  out=$(PATH="$fakebin:$PATH" run_lib "$home" fm_hold_release_evaluate "$home/state")
  [ -z "$out" ] || fail "an open PR must not wake: $out"
  # Failure: unknown, never met, and the record stays for the next sweep.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/gh"
  chmod +x "$fakebin/gh"
  out=$(PATH="$fakebin:$PATH" run_lib "$home" fm_hold_release_evaluate "$home/state")
  [ -z "$out" ] || fail "a failed lookup must never read as met: $out"
  [ -e "$home/state/hold-releases/t1" ] || fail "an unknown lookup keeps the record"
  # MERGED: met, and the wake names the condition.
  make_gh MERGED
  out=$(PATH="$fakebin:$PATH" run_lib "$home" fm_hold_release_evaluate "$home/state")
  [ "$out" = "hold condition met: t1 pr:owner/repo#42" ] \
    || fail "a merged PR must wake once: $out"
  assert_grep 'pr view https://github.com/owner/repo/pull/42' "$fakebin/gh.args" \
    "the evaluation reads the canonical pull URL through gh"
  pass "hold-release: pr condition is met only on MERGED, never on failure"
}

# --- captain holds ---------------------------

test_captain_hold_carries_a_release_condition() {
  local home fakebin
  home=$(make_home captain)
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  PATH="$fakebin:$PATH" REAL_TASKS_AXI=$(command -v tasks-axi) \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$CAPTAIN" hold q1 --title "captain question" --reason "waiting on PR 42" \
    --repo demo --release-on 'pr:owner/repo#42' >/dev/null \
    || fail "a captain hold with --release-on must succeed"
  assert_grep "condition=pr:owner/repo#42" "$home/state/hold-releases/q1" \
    "the captain hold stores its release condition"
  # A process substitution is not a regular file, and load_decision refuses
  # anything but one, so the decision has to be a real file. Swallowing a
  # failed answer would leave the record in place and look like a pass.
  printf 'go ahead\n' > "$home/decision.txt"
  PATH="$fakebin:$PATH" REAL_TASKS_AXI=$(command -v tasks-axi) \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$CAPTAIN" answer q1 --decision-file "$home/decision.txt" >/dev/null \
    || fail "answering the captain hold must succeed"
  [ ! -e "$home/state/hold-releases/q1" ] \
    || fail "answering the hold must drop its release record"
  pass "hold-release: captain holds accept --release-on and answering drops it"
}

# A met captain hold stays open until the hold ends. Answering it, or
# re-holding it without a new structured condition, closes that decision.
test_captain_answer_and_rehold_close_the_decision() {
  local home fakebin decision
  home=$(make_home captain-close)
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  decision="$home/decision.txt"
  printf 'go ahead\n' > "$decision"
  PATH="$fakebin:$PATH" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$CAPTAIN" hold q1 --title "activation" --reason "waiting on the marker" \
    --repo demo --release-on "marker:$TMP_ROOT/captain-close.flag" >/dev/null \
    || fail "the marker captain hold must succeed"
  : > "$TMP_ROOT/captain-close.flag"
  run_lib "$home" fm_hold_release_evaluate "$home/state" >/dev/null
  open_decisions "$home" q1 | grep -q '^hold-release-q1	blocked' \
    || fail "a met captain hold must open the keyed decision"
  PATH="$fakebin:$PATH" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$CAPTAIN" answer q1 --decision-file "$decision" >/dev/null \
    || fail "answering a met captain hold must succeed"
  [ ! -e "$home/state/hold-releases/q1" ] \
    || fail "the answer must drop the met release record"
  open_decisions "$home" q1 | grep -q '^hold-release-q1' \
    && fail "the answer must close the open hold-release decision"
  PATH="$fakebin:$PATH" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$CAPTAIN" hold q2 --title "second" --reason "first reason" \
    --repo demo --release-on "marker:$TMP_ROOT/captain-rehold.flag" >/dev/null \
    || fail "the second captain hold must succeed"
  : > "$TMP_ROOT/captain-rehold.flag"
  run_lib "$home" fm_hold_release_evaluate "$home/state" >/dev/null
  open_decisions "$home" q2 | grep -q '^hold-release-q2	blocked' \
    || fail "the second met hold must open its decision"
  PATH="$fakebin:$PATH" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$CAPTAIN" hold q2 --reason "updated reason" >/dev/null \
    || fail "re-holding without --release-on must succeed"
  [ ! -e "$home/state/hold-releases/q2" ] \
    || fail "a captain re-hold without --release-on must drop the record"
  open_decisions "$home" q2 | grep -q '^hold-release-q2' \
    && fail "that re-hold must close the open hold-release decision"
  pass "hold-release: answering or re-holding a captain hold ends its release decision"
}

test_bounded_sweeps_visit_every_hold() {
  local home n id out first second
  home=$(make_home fair)
  : > "$home/met"
  for n in {1..26}; do
    printf -v id 't%02d' "$n"
    seed_hold "$home" "$id" "marker:$home/met" \
      || fail "release record $id must be written"
  done
  first=$(run_lib "$home" fm_hold_release_evaluate "$home/state") \
    || fail "the first bounded sweep must succeed"
  [ "$(printf '%s\n' "$first" | wc -l)" -eq 25 ] || fail "the first sweep must respect its 25-record cap"
  assert_not_contains "$first" 'hold condition met: t26' "the last hold must lie beyond the first sweep"
  second=$(run_lib "$home" fm_hold_release_evaluate "$home/state") \
    || fail "the second bounded sweep must succeed"
  assert_contains "$second" 'hold condition met: t26' "the next sweep must visit the deferred hold"
  [ "$(printf '%s\n' "$second" | wc -l)" -eq 1 ] || fail "already-open conditions must never wake twice"
  open_decisions "$home" t26 | grep -q '^hold-release-t26' || fail "the deferred hold must have a durable decision"
  pass "hold-release: bounded sweeps eventually disposition all 26 met holds"
}

test_external_reads_respect_the_checkpoint_budget() {
  local home out rc deadline started elapsed n
  home=$(make_home budget)
  cat > "$home/gh" <<SH
#!/usr/bin/env bash
printf 'lookup\n' >> '$home/lookups'
sleep 10
echo MERGED
SH
  chmod +x "$home/gh"
  for n in 1 2 3; do
    seed_hold "$home" "t$n" 'pr:owner/repo#42'
  done
  : > "$home/lookups"
  started=$SECONDS
  deadline=$(( $(date +%s) + 2 ))
  rc=0
  out=$(FM_HOLD_RELEASE_GH="$home/gh" FM_HOLD_RELEASE_MAX_RECORDS=1 \
    FM_CHECKPOINT_DEADLINE="$deadline" FM_HOLD_RELEASE_SHOW_BOUND=10 \
    run_lib "$home" fm_hold_release_evaluate "$home/state") || rc=$?
  elapsed=$((SECONDS - started))
  expect_code 124 "$rc" "the sweep must stop at the checkpoint deadline"
  [ "$elapsed" -lt 5 ] || fail "a stalled PR lookup must not consume its full ten-second bound"
  # Expiry during startup may prevent even the first read on a loaded runner.
  [ "$(wc -l < "$home/lookups")" -le 1 ] || fail "no further lookups may start after the budget expires"
  [ -z "$out" ] || fail "a timed-out PR lookup must never count as merged"
  cat > "$home/show" <<SH
#!/usr/bin/env bash
printf 'show\n' >> '$home/shows'
sleep 10
printf '  state: queued\n  held: yes\n'
SH
  chmod +x "$home/show"
  : > "$home/shows"
  started=$SECONDS
  deadline=$(( $(date +%s) + 2 ))
  rc=0
  out=$(FM_HOLD_RELEASE_SHOW_CMD="$home/show" FM_HOLD_RELEASE_MAX_RECORDS=1 FM_CHECKPOINT_DEADLINE="$deadline" \
    FM_HOLD_RELEASE_SHOW_BOUND=10 run_lib "$home" fm_hold_release_evaluate "$home/state") || rc=$?
  expect_code 124 "$rc" "task reads must also stop at the checkpoint deadline"
  [ "$((SECONDS - started))" -lt 5 ] || fail "task reads must use the remaining checkpoint budget"
  [ "$(wc -l < "$home/shows")" -le 1 ] || fail "no further task reads may start after expiry"
  [ -z "$out" ] || fail "a timed-out task read must never publish a decision"
  pass "hold-release: PR and task reads respect the remaining sweep budget"
}

wait_for_file() {
  local file=$1 n=0
  until [ -f "$file" ]; do
    n=$((n + 1))
    [ "$n" -le 100 ] || return 1
    sleep 0.1
  done
}

run_captain() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$CAPTAIN" "$@"
}

hold_with_writer() {
  local home=$1 writer=$2
  shift 2
  if [ "$writer" = captain ]; then
    run_captain "$home" hold t1 --reason 'awaiting (activation)' "$@"
  else
    run_axi "$home" hold t1 --reason 'awaiting activation' --kind external "$@"
  fi
}

test_committed_holds_recover_without_cache_publication() {
  local home writer mode fakebin real_axi out rc command phase condition
  real_axi=$(command -v tasks-axi)
  for writer in tasks captain; do
    for mode in initial rehold same dated unhold refused; do
      home=$(make_home "interrupted-$writer-$mode")
      fakebin=$(fm_fakebin "$home")
      fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
      run_axi "$home" add t1 one --repo demo >/dev/null
      if [ "$mode" != initial ]; then
        PATH="$fakebin:$PATH" hold_with_writer "$home" "$writer" --release-on "marker:$home/old" >/dev/null \
          || fail "the original $writer hold must commit"
        : > "$home/old"
        run_lib "$home" fm_hold_release_evaluate "$home/state" >/dev/null
        open_decisions "$home" t1 | grep -q '^hold-release-t1' \
          || fail "the old episode must have an open decision"
      fi
      cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != --help ] || exec "$FM_TEST_REAL_TASKS_AXI" "$@"
done
if [ "${1:-}" = "${FM_TEST_COMMIT_COMMAND:-}" ] && [ "${FM_TEST_COMMIT_PHASE:-}" = before ]; then
  exit 99
fi
"$FM_TEST_REAL_TASKS_AXI" "$@" || exit $?
[ "${1:-}" != "${FM_TEST_COMMIT_COMMAND:-}" ] || exit 99
SH
      chmod +x "$fakebin/tasks-axi"
      command=hold
      phase=after
      condition="marker:$home/new"
      rc=0
      case "$mode" in
        dated)
          PATH="$fakebin:$PATH" FM_TEST_REAL_TASKS_AXI="$real_axi" FM_TEST_COMMIT_COMMAND="$command" \
            hold_with_writer "$home" "$writer" --until 2099-01-01 > "$home/write.out" 2>&1 || rc=$?
          ;;
        unhold)
          command=unhold
          printf 'resume\n' > "$home/answer"
          if [ "$writer" = captain ]; then
            PATH="$fakebin:$PATH" FM_TEST_REAL_TASKS_AXI="$real_axi" FM_TEST_COMMIT_COMMAND="$command" \
              run_captain "$home" answer t1 --release --decision-file "$home/answer" > "$home/write.out" 2>&1 || rc=$?
          else
            PATH="$fakebin:$PATH" FM_TEST_REAL_TASKS_AXI="$real_axi" FM_TEST_COMMIT_COMMAND="$command" \
              run_axi "$home" unhold t1 > "$home/write.out" 2>&1 || rc=$?
          fi
          ;;
        *)
          [ "$mode" != same ] || condition="marker:$home/old"
          [ "$mode" != refused ] || phase=before
          PATH="$fakebin:$PATH" FM_TEST_REAL_TASKS_AXI="$real_axi" FM_TEST_COMMIT_COMMAND="$command" FM_TEST_COMMIT_PHASE="$phase" \
            hold_with_writer "$home" "$writer" --release-on "$condition" > "$home/write.out" 2>&1 || rc=$?
          ;;
      esac
      [ "$rc" -ne 0 ] || fail "the $writer $mode writer must stop before cache publication"
      if [ "$mode" = initial ]; then
        [ ! -e "$home/state/hold-releases/t1" ] || fail "the interrupted initial hold must lack its cache"
      fi
      out=$(run_lib "$home" fm_hold_release_evaluate "$home/state") \
        || fail "the $writer $mode episode must reconcile"
      case "$mode" in
        refused)
          [ -z "$out" ] || fail "a refused write must not start an episode"
          open_decisions "$home" t1 | grep -q '^hold-release-t1' \
            || fail "a refused write must preserve the old decision"
          ;;
        same)
          [ "$out" = "hold condition met: t1 $condition" ] \
            || fail "a committed re-hold of the same condition must publish its new episode: $out"
          ;;
        *)
          [ -z "$out" ] || fail "the old met condition must not wake after $writer $mode: $out"
          open_decisions "$home" t1 | grep -q '^hold-release-t1' \
            && fail "the old decision must close after $writer $mode"
          case "$mode" in
            initial|rehold)
              : > "$home/new"
              out=$(run_lib "$home" fm_hold_release_evaluate "$home/state")
              [ "$out" = "hold condition met: t1 $condition" ] \
                || fail "the committed condition must remain discoverable after $writer $mode: $out"
              ;;
            *)
              [ ! -e "$home/state/hold-releases/t1" ] || fail "$writer $mode must retire the stale cache"
              ;;
          esac
          ;;
      esac
      out=$(run_lib "$home" fm_hold_release_evaluate "$home/state")
      [ -z "$out" ] || fail "recovery must not repeat the $writer $mode wake: $out"
    done
  done
  pass "hold-release: committed episodes recover after interrupted publication and refused writes preserve the prior hold"
}

test_hold_conditions_travel_with_task_transfers() {
  local source dest route out fakebin bytes hash
  for route in move peer registered receipt; do
    source=$(make_home "transfer-$route-source")
    dest=$(make_home "transfer-$route-dest")
    seed_secondmate_home_marker "$dest" mate
    seed_hold "$source" t1 'pr:owner/repo#42' || fail "the source hold must commit"
    case "$route" in
      move)
        run_axi "$source" mv t1 --to "$dest/data/backlog.md" >/dev/null \
          || fail "the held task must move through the wrapper"
        ;;
      peer)
        FM_HOME="$source" "$ROOT/bin/fm-backlog-handoff.sh" --to "$dest" t1 > "$source/handoff.out" 2>&1 \
          || fail "the held task must transfer to a local peer: $(cat "$source/handoff.out")"
        ;;
      registered)
        printf -- '- mate - delegated work (home: %s; scope: demo; projects: demo; added 2026-10-29)\n' "$dest" > "$source/data/secondmates.md"
        printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\nworktree=%s\n' "$dest" "$dest" > "$source/state/mate.meta"
        fakebin=$(make_fake_tmux "$source/fake")
        PATH="$fakebin:$PATH" FM_HOME="$source" FM_FAKE_TMUX_WINDOW=firstmate:fm-mate \
          FM_FAKE_TMUX_LOG="$source/tmux.log" FM_FAKE_TMUX_CAPTURE="$source/fake/pane.txt" \
          FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 \
          "$ROOT/bin/fm-backlog-handoff.sh" mate t1 > "$source/handoff.out" 2>&1 \
          || fail "the held task must transfer to its registered mate: $(cat "$source/handoff.out")"
        ;;
      receipt)
        mkdir -p "$dest/state/handoff"
        run_axi "$source" mv t1 --to "$source/outbox.md" >/dev/null \
          || fail "the held task must stage in an outbox"
        bytes=$(wc -c < "$source/outbox.md" | tr -d '[:space:]')
        hash=$(perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)' "$source/outbox.md")
        FM_HOME="$dest" "$ROOT/bin/fm-remote-file.sh" put state/handoff/sender.outbox.md 1048576 "$bytes" "$hash" 1 < "$source/outbox.md" > "$source/upload.out" 2>&1 \
          || fail "the outbox upload must commit its payload: $(cat "$source/upload.out")"
        FM_HOME="$dest" "$ROOT/bin/fm-backlog-receive.sh" state/handoff/sender.outbox.md "$bytes" "$hash" 1 > "$source/receipt.out" 2>&1 \
          || fail "the held task must survive outbox receipt: $(cat "$source/receipt.out")"
        ;;
    esac
    [ ! -e "$dest/state/hold-releases/t1" ] || fail "transfer must not rely on a copied home-local cache"
    printf '#!/usr/bin/env bash\nprintf "MERGED\\n"\n' > "$dest/gh"
    chmod +x "$dest/gh"
    out=$(FM_HOLD_RELEASE_GH="$dest/gh" run_lib "$dest" fm_hold_release_evaluate "$dest/state") \
      || fail "the destination must discover the transferred hold after $route"
    [ "$out" = 'hold condition met: t1 pr:owner/repo#42' ] \
      || fail "$route must preserve the committed release condition: $out"
    open_decisions "$dest" t1 | grep -q '^hold-release-t1' \
      || fail "$route must leave a durable decision in the destination"
    out=$(FM_HOLD_RELEASE_GH="$dest/gh" run_lib "$dest" fm_hold_release_evaluate "$dest/state")
    [ -z "$out" ] || fail "$route must not repeat the destination wake"
  done
  pass "hold-release: raw moves, local peers, registered mates and remote receipts preserve conditions"
}

test_structured_reason_round_trips_across_readers() {
  local home reason condition shown listed quoted raw encoded snapshot rendered
  home=$(make_home structured-reason)
  reason=$'Wait for "north" (activation)\nThen resume café'
  condition="marker:$home/activation (north)"
  run_axi "$home" add t1 one --repo demo >/dev/null
  run_axi "$home" hold t1 --reason "$reason" --release-on "$condition" >/dev/null \
    || fail "structured holds must retain ordinary prose"
  quoted=$(jq -cn --arg value "$reason" '$value')
  shown=$(run_axi "$home" show t1)
  [ "$(printf '%s\n' "$shown" | sed -n 's/^  hold_reason: //p' | jq -r .)" = "$reason" ] \
    || fail "show must decode the human reason exactly once"
  [ "$(printf '%s\n' "$shown" | sed -n 's/^  hold_release_on: //p' | jq -r .)" = "$condition" ] \
    || fail "show must expose the committed release field independently of prose"
  listed=$(run_axi "$home" list --state held --fields hold_reason)
  assert_contains "$listed" "$quoted" "list must preserve the quoted human reason"
  raw=$(tasks-axi show t1 --file "$home/data/backlog.md" --backend markdown)
  encoded=$(printf '%s\n' "$raw" | sed -n 's/^  hold_reason: //p')
  case "$encoded" in \"*) encoded=$(printf '%s' "$encoded" | jq -r .) ;; esac
  snapshot=$(jq -cn --arg reason "$encoded" '{records:[{hold_reason:$reason}]}')
  rendered=$(printf '%s' "$snapshot" | bash -c '. "$1"; fm_hold_reason_decode_stream json' _ "$ROOT/bin/fm-hold-reason-lib.sh")
  [ "$(printf '%s' "$rendered" | jq -r '.records[0].hold_reason')" = "$reason" ] \
    || fail "snapshot decoding must preserve the human reason"
  rendered=$(bash -c '. "$1"; fm_hold_reason_decode_stream markdown' _ "$ROOT/bin/fm-hold-reason-lib.sh" < "$home/data/backlog.md")
  assert_contains "$rendered" "$quoted" "markdown decoding must preserve the quoted human reason"
  pass "hold-release: structured reasons round-trip through show, list, snapshots and markdown"
}

race_hold_mutation() {
  local home=$1 mode=$2
  case "$mode" in
    unhold) run_axi "$home" unhold t1 >/dev/null ;;
    rehold) run_axi "$home" hold t1 --reason new --kind external --release-on "marker:$home/unmet" >/dev/null ;;
    captain-answer) run_captain "$home" answer t1 --decision-file "$home/answer" >/dev/null ;;
    captain-rehold) run_captain "$home" hold t1 --reason new --release-on "marker:$home/unmet" >/dev/null ;;
  esac
}

# shellcheck disable=SC2031  # the racing mutation runs in its own background subshell
test_hold_mutations_cannot_reopen_stale_decisions() {
  local home mode fakebin evaluator mutation
  for mode in unhold rehold captain-answer captain-rehold; do
    home=$(make_home "race-$mode")
    fakebin=$(fm_fakebin "$home")
    fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
    case "$mode" in
      captain-*)
        PATH="$fakebin:$PATH" run_captain "$home" hold t1 --title one --reason waiting --repo demo \
          --release-on 'pr:owner/repo#42' >/dev/null || fail "the initial captain hold must succeed"
        ;;
      *)
        run_axi "$home" add t1 one --repo demo >/dev/null
        run_axi "$home" hold t1 --reason waiting --kind external --release-on 'pr:owner/repo#42' >/dev/null
        ;;
    esac
    printf 'yes\n' > "$home/answer"
    cat > "$home/gh" <<SH
#!/usr/bin/env bash
case "\$*" in *'/pull/43 '*) echo OPEN; exit 0 ;; esac
: > '$home/evaluating'
until [ -f '$home/release' ]; do sleep 0.05; done
echo MERGED
SH
    chmod +x "$home/gh"
    FM_HOLD_RELEASE_GH="$home/gh" run_lib "$home" fm_hold_release_evaluate "$home/state" > "$home/wakes" &
    evaluator=$!
    wait_for_file "$home/evaluating" || fail "evaluation must reach the external lookup"
    (
      PATH="$fakebin:$PATH" race_hold_mutation "$home" "$mode" || exit 1
      : > "$home/mutated"
    ) &
    mutation=$!
    sleep 0.2
    if [ -f "$home/mutated" ]; then
      : > "$home/release"
      wait "$evaluator" || true
      wait "$mutation" || true
      fail "$mode must serialize with decision publication"
    fi
    : > "$home/release"
    wait "$evaluator" || fail "the racing evaluation must finish"
    wait "$mutation" || fail "the $mode mutation must finish"
    [ -f "$home/mutated" ] || fail "the mutation must commit"
    open_decisions "$home" t1 | grep -q '^hold-release-t1' \
      && fail "$mode must close the stale condition's decision"
    FM_HOLD_RELEASE_GH="$home/gh" run_lib "$home" fm_hold_release_evaluate "$home/state" > "$home/after"
    [ ! -s "$home/after" ] || fail "$mode must not reopen the old condition on a later sweep"
    open_decisions "$home" t1 | grep -q '^hold-release-t1' \
      && fail "$mode must leave no orphan decision"
  done
  pass "hold-release: all hold mutations serialize with evaluation and close stale decisions"
}

test_met_wake_is_durable_before_later_reads_expire() {
  local home held_episode out rc keys
  home=$(make_home durable-wake)
  : > "$home/met"
  seed_hold "$home" t1 "marker:$home/met"
  seed_hold "$home" t2 'pr:owner/repo#42'
  seed_hold "$home" t3 "marker:$home/unmet"
  held_episode=$(run_axi "$home" show t1 | sed -n 's/^  hold_release_episode: //p' | jq -r .)
  # Expire at the second backend read, after the first can publish regardless
  # of runner speed. Real command timeout bounds are exercised separately.
  # shellcheck disable=SC2329  # Invoked by run_lib through "$fn".
  evaluate_with_expired_second_read() {
    # shellcheck disable=SC2329,SC2034  # Backend outputs consumed by the evaluator.
    _fm_hold_release_show() {
      case "$1" in
        t1)
          FM_HOLD_RELEASE_SHOW_STATE=queued
          FM_HOLD_RELEASE_SHOW_HELD=yes
          FM_HOLD_RELEASE_SHOW_CONDITION="marker:$home/met"
          FM_HOLD_RELEASE_SHOW_EPISODE=$held_episode
          ;;
        t2) FM_CHECKPOINT_DEADLINE=0; return 2 ;;
        *) fail "no further task reads may start after expiry" ;;
      esac
    }
    fm_hold_release_evaluate "$@"
  }
  rc=0
  out=$(run_lib "$home" evaluate_with_expired_second_read "$home/state") || rc=$?
  expect_code 124 "$rc" "a later read must exhaust the checkpoint budget"
  assert_contains "$out" 'hold condition met: t1' "the first hold must have been evaluated"
  keys=$(STATE="$home/state" FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1"; fm_wake_queued_keys check' _ "$ROOT/bin/fm-wake-lib.sh")
  assert_contains "$keys" 'hold-release:t1' "the first hold must already have a durable check wake"
  open_decisions "$home" t1 | grep -q '^hold-release-t1' || fail "the announced hold must retain its decision"
  FM_HOLD_RELEASE_MAX_RECORDS=2 \
    run_lib "$home" fm_hold_release_evaluate "$home/state" >/dev/null
  [ "$(awk -F '\t' '$3 == "check" && $4 == "hold-release:t1" {n++} END {print n+0}' "$home/state/.wake-queue")" -eq 1 ] \
    || fail "a later sweep must not duplicate the committed wake"
  pass "hold-release: an announced decision always has a durable wake before budget expiry"
}

test_uncommitted_wake_does_not_suppress_publication() {
  local home out
  home=$(make_home rejected-wake)
  : > "$home/met"
  seed_hold "$home" t1 "marker:$home/met"
  mkdir "$home/state/.wake-queue"
  run_lib "$home" fm_hold_release_evaluate "$home/state" >/dev/null 2>&1 || true
  open_decisions "$home" t1 | grep -q '^hold-release-t1' && fail "a failed wake commit must not announce the decision"
  rmdir "$home/state/.wake-queue"
  out=$(run_lib "$home" fm_hold_release_evaluate "$home/state")
  assert_contains "$out" 'hold condition met: t1' "publication must resume when the queue can accept the wake"
  pass "hold-release: failed wake commits leave publication retryable"
}

test_wrapper_spellings_and_captain_exemption() {
  local home fakebin rc args
  home=$(make_home kindless-spellings)
  run_axi "$home" add t1 one --repo demo >/dev/null
  for args in '' '--kind=external'; do
    rc=0
    run_axi "$home" hold t1 --reason waiting ${args:+$args} >/dev/null 2>&1 || rc=$?
    expect_code 2 "$rc" "every kindless and external spelling must require an event or date"
    run_axi "$home" hold t1 --reason dated ${args:+$args} --until=2099-01-01 >/dev/null || fail "dated holds must work"
    run_axi "$home" hold t1 --reason event ${args:+$args} --release-on="marker:$home/unmet" >/dev/null || fail "event holds must work"
  done
  run_axi "$home" hold --help >/dev/null || fail "help must remain available without a hold condition"
  run_axi "$home" hold --reason before-id t1 --release-on "marker:$home/ordered" >/dev/null \
    || fail "options before the task id must retain the same hold contract"
  assert_grep "condition=marker:$home/ordered" "$home/state/hold-releases/t1" "option ordering must store the condition on the named task"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  PATH="$fakebin:$PATH" run_captain "$home" hold c1 --title question --reason 'owner decision' --repo demo >/dev/null \
    || fail "captain holds must remain exempt from the event-or-date rule"
  PATH="$fakebin:$PATH" run_captain "$home" hold c1 --reason deferred --until 2099-01-01 >/dev/null \
    || fail "captain holds must retain date deferral"
  [ ! -e "$home/state/hold-releases/c1" ] || fail "captain holds must not acquire a synthetic release condition"
  pass "hold-release: all wrapper spellings require a condition while captain holds stay exempt"
}

# shellcheck disable=SC2031  # the check subshell assigns its own copies
test_hold_reads_reserve_time_for_registered_checks() {
  local home
  home=$(make_home reserved-check)
  cat > "$home/gh" <<'SH'
#!/usr/bin/env bash
sleep 10
echo OPEN
SH
  chmod +x "$home/gh"
  seed_hold "$home" t1 'pr:owner/repo#42'
  seed_hold "$home" t2 'pr:owner/repo#43'
  (
    # shellcheck source=bin/fm-hold-release-lib.sh disable=SC1091
    . "$LIB"
    # shellcheck disable=SC2031  # these exports assign fresh values for this subshell
    export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_HOLD_RELEASE_GH="$home/gh"
    FM_CHECKPOINT_DEADLINE=$(( $(date +%s) + 4 ))
    fm_hold_release_evaluate "$home/state" >/dev/null || true
    remaining=$(fm_checkpoint_budget 10) || fail "hold reads must leave time for later registered checks"
    # shellcheck disable=SC2016  # the child bash must expand its own positional argument
    fm_run_timed "$remaining" bash -c ': > "$1"' _ "$home/registered-check-ran" || fail "the next registered check must run"
  ) || fail "hold evaluation must reserve the next check's turn"
  [ -f "$home/registered-check-ran" ] || fail "later work must make observable progress"
  pass "hold-release: stalled lookups reserve processing time for later registered checks"
}

test_condition_syntax
test_external_hold_refused_without_condition
test_hold_with_release_on_records_the_condition
test_other_hold_kinds_still_work_without_a_condition
test_rehold_and_unhold_manage_the_record
test_evaluation_wakes_once_and_keeps_the_decision_open
test_release_and_rehold_close_the_decision
test_rehold_after_met_opens_a_new_episode
test_closed_task_reconciles_its_record_away
test_removed_task_reconciles_its_record_away
test_show_override_distinguishes_missing_from_unreadable
test_committed_holds_recover_without_cache_publication
test_hold_conditions_travel_with_task_transfers
test_structured_reason_round_trips_across_readers
test_pr_condition_reads_merge_state_through_gh
test_captain_hold_carries_a_release_condition
test_captain_answer_and_rehold_close_the_decision
test_bounded_sweeps_visit_every_hold
test_external_reads_respect_the_checkpoint_budget
test_hold_mutations_cannot_reopen_stale_decisions
test_met_wake_is_durable_before_later_reads_expire
test_uncommitted_wake_does_not_suppress_publication
test_wrapper_spellings_and_captain_exemption
test_hold_reads_reserve_time_for_registered_checks

echo "# fm-hold-release.test.sh: all assertions passed"
