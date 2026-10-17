#!/usr/bin/env bash
# tests/fm-watch-gate-nudge.test.sh - crew_gate_class in bin/fm-classify-lib.sh.
#
# The public watcher selected for this tree has no gate-nudge ladder.
# The owner ladder cases are omitted with that watcher.
# This file keeps the classifier those cases read.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-gate-nudge-tests)

# --- pure classifier (fm-classify-lib.sh) -----------------------------------

test_crew_gate_class_reads_only_run_step_gates() {
  local dir fakebin
  dir=$(make_case gate-class); fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE

  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 3 finding(s)'
  [ "$(crew_gate_class a)" = "parked$(printf '\t')parked at review: 3 finding(s)" ] \
    || fail "a parked run-step gate was not classified as a gate: $(crew_gate_class a)"
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  [ "$(crew_gate_class a)" = "ci-green$(printf '\t')checks green: PR ready for review" ] \
    || fail "a green-CI run-step verdict was not classified as a gate: $(crew_gate_class a)"
  # A done reconciled from the status log means the worker already reported.
  FM_FAKE_CREW_STATE='state: done · source: status-log · done: PR ...  ·  run still monitoring PR'
  [ "$(crew_gate_class a)" = none ] \
    || fail "a status-log done was read as a gate the worker still owes"
  FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'
  [ "$(crew_gate_class a)" = resumed ] \
    || fail "a working read from the run itself was not read as a resume: $(crew_gate_class a)"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (background run)'
  [ "$(crew_gate_class a)" = none ] \
    || fail "a coarse runs-list read was taken as proof the run resumed"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  [ "$(crew_gate_class a)" = none ] || fail "a failed run was read as a gate"
  FM_FAKE_CREW_STATE='state: parked · source: pane · idle prompt'
  [ "$(crew_gate_class a)" = none ] || fail "a pane verdict was read as a gate"
  FM_FAKE_CREW_STATE='not a state line at all'
  [ "$(crew_gate_class a)" = none ] || fail "an unreadable verdict was read as a gate"
  [ "$(crew_gate_class "")" = none ] || fail "an empty id was read as a gate"

  unset FM_FAKE_CREW_STATE FM_CREW_STATE_BIN
  pass "crew_gate_class: only a run-step parked or green-CI verdict is a gate, and only the run's own working read is a resume"
}

test_crew_gate_class_reads_only_run_step_gates
