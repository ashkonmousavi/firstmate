#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-state.sh - the deterministic crew-current-state
# helper.
#
# The status file (state/<id>.status) is a best-effort append-only EVENT LOG, so
# `tail -1` of it reports the last event, not the current state. fm-crew-state
# reads the AUTHORITATIVE source (a matching no-mistakes run-step, else the
# semantic busy-state contract) and reconciles the possibly-stale log against it. These
# cases pin every branch of that logic, hermetically, over real throwaway git
# repos with a fake `no-mistakes` (run-step source) and a fake `tmux` (pane
# source):
#   (a) active run-step is authoritative                          -> run-step
#   (b) needs-decision/blocked log + resumed run = SUPERSEDED     -> run-step
#   (c) genuine parked run + needs-decision log = NOT superseded  -> run-step
#   (d) terminal run-step (passed/failed) is authoritative        -> run-step
#   (e) cross-branch attribution: this branch's own run found via list lookup
#   (f) no run + semantic busy                                    -> pane
#   (g) no run + semantic idle falls to the status-log verb       -> status-log
#   (h) dead pane: no run -> unknown/none; with a run -> run-step (not the shell)
#   (i) kind=scout skips the run lookup                           -> pane/status-log
#   (j) torn-down worktree / missing meta                         -> unknown/none
#   (k) crew_is_provably_working end-to-end over the REAL helper (not a canned
#       fake fm-crew-state.sh verdict): cross-branch attribution via the runs
#       list -> absorbed; genuinely no run anywhere + idle pane -> surfaced.
#       This is the direct regression pair for the 2026-07-02 herdr incident,
#       proving the watcher's own absorb-only-when-provably-working predicate
#       benefits from the fix in both directions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state)
fm_git_identity fmtest fmtest@example.invalid

# A real git repo checked out on <branch>, so the helper's branch attribution
# (git symbolic-ref) resolves like it would for a live crew worktree.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
  # Real worktree HEAD for run head-binding (fixtures read FM_FAKE_RUN_HEAD).
  FM_FAKE_RUN_HEAD=$(git -C "$dir" rev-parse HEAD)
  export FM_FAKE_RUN_HEAD
}

# A fakebin with a fake `no-mistakes` (serves the env-driven run output) and a
# fake `tmux` (serves a busy or idle pane). The fake no-mistakes mirrors the real
# command surface the helper uses: `axi status`, `axi status --run <id>` (the
# `axi` surface - no runs-listing subcommand exists under it, verified against
# the real CLI), and the actual top-level run-listing command, `no-mistakes
# runs --limit N`, which is plain text - no run id, no quoting - serving
# FM_FAKE_RUNS_LIST verbatim.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
      logs)
        printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs)
    printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
  daemon)
    [ "${FM_FAKE_DAEMON_DOWN:-0}" = 1 ] && exit 1
    printf '%s\n' 'daemon running (pid 4242)'
    exit 0 ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\n%s\n' "${FM_FAKE_BUSY_TEXT:-esc to interrupt}"
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    [ "${2:-}" = --json ] && {
      printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
      exit 0
    } ;;
  server)
    exit 0 ;;
  pane)
    case "${2:-}" in
      read)
        [ "${FM_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        if [ "${FM_FAKE_HERDR_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
        else printf 'all quiet\n> \n'; fi
        exit 0 ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        [ -n "${FM_FAKE_HERDR_AGENT_STATUS:-}" ] || exit 1
        printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$FM_FAKE_HERDR_AGENT_STATUS"
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_GH_AXI_CALLS:-/dev/null}"
case "$*" in
  api*/pulls/*)
    printf 'api_response:\n  body: "%s|%s"\n  truncated: false\n' \
      "${FM_FAKE_PR_STATE:-}" "${FM_FAKE_PR_HEAD:-}"
    ;;
  api*/check-runs*)
    printf 'api_response:\n  body: "%s|%s|%s"\n  truncated: false\n' \
      "${FM_FAKE_PR_CHECKS_TOTAL:-0}" \
      "${FM_FAKE_PR_CHECKS_COMPLETED:-0}" \
      "${FM_FAKE_PR_CHECKS_BAD:-0}"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/herdr" "$fb/gh-axi"
  printf '%s\n' "$fb"
}

make_no_timeout_toolbin() {  # <dir> -> echoes toolbin path
  local dir=$1 tb="$1/notimeoutbin" tool real
  mkdir -p "$tb"
  for tool in bash git grep sed head cut tail dirname perl; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for no-timeout path: $tool"
    ln -s "$real" "$tb/$tool"
  done
  printf '%s\n' "$tb"
}

# Run the helper for one case dir. FM_FAKE_* env (run output, busy flag) are read
# from the caller's environment by the fakes above.
run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

arm_idle_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

# Clear the fake-driver vars and (re-)mark them exported, so the per-test plain
# assignments below stay exported into the fakes without an `export VAR=$(...)`
# command-substitution assignment (SC2155).
reset_fakes() {
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_AXI_STATUS_RUN=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  FM_FAKE_BUSY_TEXT=
  FM_FAKE_TMUX_MISSING=0
  FM_FAKE_HERDR_BUSY=0
  FM_FAKE_HERDR_MISSING=0
  FM_FAKE_HERDR_AGENT_STATUS=""
  FM_FAKE_CI_LOGS=""
  FM_FAKE_DAEMON_DOWN=0
  FM_FAKE_GH_AXI_CALLS=""
  FM_FAKE_PR_STATE=""
  FM_FAKE_PR_HEAD=""
  FM_FAKE_PR_CHECKS_TOTAL=0
  FM_FAKE_PR_CHECKS_COMPLETED=0
  FM_FAKE_PR_CHECKS_BAD=0
  export FM_FAKE_AXI_STATUS FM_FAKE_AXI_STATUS_RUN FM_FAKE_RUNS_LIST FM_FAKE_BUSY FM_FAKE_BUSY_TEXT FM_FAKE_TMUX_MISSING
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_CI_LOGS
  export FM_FAKE_DAEMON_DOWN
  export FM_FAKE_GH_AXI_CALLS FM_FAKE_PR_STATE FM_FAKE_PR_HEAD
  export FM_FAKE_PR_CHECKS_TOTAL FM_FAKE_PR_CHECKS_COMPLETED FM_FAKE_PR_CHECKS_BAD
}

# --- run-object fixtures (TOON, as `no-mistakes axi status` emits) -----------

run_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

run_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
EOF
}

run_top_level_ci() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: ci
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
EOF
}

run_parked() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_scalar_gate_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_in_gate_block() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate:
  step: review
  status: fix_review
steps[3]{step,status,findings,duration_ms}:
  intent,completed,0,0
  review,fix_review,1,0
  test,pending,0,0
EOF
}

run_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed
EOF
}

run_failed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: failed
EOF
}

run_cancelled_outcome() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: cancelled
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
outcome: cancelled
error: "cancelled: aborted by user"
EOF
}

run_cancelled_status() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: cancelled
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
error: "cancelled: aborted by user"
EOF
}

# A human approved past a live CI check that was still red. Verified identical
# in no-mistakes v1.64.0 and v1.65.4 (internal/cli/axi_drive.go:69-70,
# outcomeForRun): "passed-with-override" is the exact literal both releases emit.
run_passed_with_override() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed-with-override
EOF
}

# A synthetic, never-real outcome word: proves the catch-all default rather
# than pinning behavior to any one currently-unmapped real outcome (a future
# release may map a real word like ci-monitor-interrupted explicitly).
# A run whose CI monitor stopped before any merge verdict. no-mistakes reports
# this terminal condition in TWO distinct spellings from ONE cause
# (internal/types/types.go RunCIMonitorInterrupted = "ci_monitor_interrupted",
# rendered by internal/cli/axi_drive.go outcomeFor as "ci-monitor-interrupted"),
# so both are fixtures here. The PR stays open and intact - the daemon merely
# restarted while babysitting it - so this is neither a pipeline failure nor a
# green result.
run_ci_monitor_interrupted_outcome() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: ci_monitor_interrupted
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/430"
  findings: none
outcome: ci-monitor-interrupted
EOF
}

run_ci_monitor_interrupted_status() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: ci_monitor_interrupted
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/430"
  findings: none
  steps[3]{step,status,findings,duration_ms}:
    push,completed,0,4617
    pr,completed,0,14186
    ci,skipped,0,0
EOF
}

# outcomeForRun's other qualified-pass word (internal/cli/axi_render.go
# automaticSkips): the run completed, but its PR or CI step was skipped
# automatically, so nothing proved the change was published and checked.
run_passed_with_skips() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: passed-with-skips
EOF
}

run_unrecognized_outcome() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: zzz-not-a-real-outcome
EOF
}

run_ci_monitoring() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_fixing_ci_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_ci_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,fixing,0,0
EOF
}

# ---------------------------------------------------------------------------
# (a) active run-step is authoritative
test_active_run_is_authoritative() {
  reset_fakes
  local d; d=$(new_case active)
  make_repo_on_branch "$d/wt" fm/feat-a
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-a.meta" "window=fm:fm-feat-a" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-a)"
  local out; out=$(run_crew_state "$d" feat-a)
  assert_contains "$out" "state: working" "active run -> working"
  assert_contains "$out" "source: run-step" "active run -> run-step source"
  assert_contains "$out" "validating (running)" "active run reports the step"
  pass "active run-step is authoritative"
}

# (b) needs-decision log + a resumed (running/fixing) run = SUPERSEDED
test_stale_needs_decision_superseded() {
  reset_fakes
  local d; d=$(new_case superseded)
  make_repo_on_branch "$d/wt" fm/feat-b
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-b.meta" "window=fm:fm-feat-b" "worktree=$d/wt" "kind=ship"
  printf 'working: started\nneeds-decision: pick A or B\n' > "$d/state/feat-b.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-b)"
  local out; out=$(run_crew_state "$d" feat-b)
  assert_contains "$out" "state: working" "resumed run -> working despite needs-decision log"
  assert_contains "$out" "source: run-step" "resumed run -> run-step source"
  assert_contains "$out" "superseded" "stale needs-decision log flagged superseded"
  pass "stale needs-decision over active run is superseded"
}

# blocked log + a resumed run is also superseded
test_stale_blocked_superseded() {
  reset_fakes
  local d; d=$(new_case superseded-blocked)
  make_repo_on_branch "$d/wt" fm/feat-bb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-bb.meta" "window=fm:fm-feat-bb" "worktree=$d/wt" "kind=ship"
  printf 'blocked: waiting on review answer\n' > "$d/state/feat-bb.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-bb)"
  local out; out=$(run_crew_state "$d" feat-bb)
  assert_contains "$out" "state: working" "resumed run -> working despite blocked log"
  assert_contains "$out" "superseded" "stale blocked log flagged superseded"
  pass "stale blocked over active run is superseded"
}

# (c) genuine parked run + needs-decision log AGREE -> parked, NOT superseded
test_genuine_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked)
  make_repo_on_branch "$d/wt" fm/feat-c
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-c.meta" "window=fm:fm-feat-c" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-c.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-c)"
  local out; out=$(run_crew_state "$d" feat-c)
  assert_contains "$out" "state: parked" "genuine parked run -> parked"
  assert_contains "$out" "source: run-step" "parked -> run-step source"
  assert_contains "$out" "2 finding(s)" "parked includes gate finding count"
  assert_contains "$out" "ask-user" "parked surfaces ask-user finding"
  assert_not_contains "$out" "superseded" "agreeing parked+needs-decision not flagged stale"
  pass "genuine parked run is not flagged superseded"
}

test_scalar_gate_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-scalar-gate)
  make_repo_on_branch "$d/wt" fm/feat-cs
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cs.meta" "window=fm:fm-feat-cs" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cs.status"
  FM_FAKE_AXI_STATUS="$(run_parked_scalar_gate_running fm/feat-cs)"
  local out; out=$(run_crew_state "$d" feat-cs)
  assert_contains "$out" "state: parked" "scalar gate wait -> parked"
  assert_contains "$out" "source: run-step" "scalar gate wait -> run-step source"
  assert_contains "$out" "parked at review" "scalar gate wait names the gate"
  assert_contains "$out" "1 finding(s)" "scalar gate wait includes finding count"
  assert_not_contains "$out" "superseded" "scalar gate wait not flagged stale"
  pass "scalar gate parked run is not flagged superseded"
}

test_gate_block_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-gate-block)
  make_repo_on_branch "$d/wt" fm/feat-cb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cb.meta" "window=fm:fm-feat-cb" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cb.status"
  FM_FAKE_AXI_STATUS="$(run_parked_in_gate_block fm/feat-cb)"
  local out; out=$(run_crew_state "$d" feat-cb)
  assert_contains "$out" "state: parked" "gate block wait -> parked"
  assert_contains "$out" "source: run-step" "gate block wait -> run-step source"
  assert_contains "$out" "parked at review" "gate block wait names the gate"
  assert_contains "$out" "1 finding(s)" "gate block wait includes finding count"
  assert_not_contains "$out" "superseded" "gate block wait not flagged stale"
  pass "gate block parked run is not flagged superseded"
}

test_ci_ready_done_log_beats_monitoring_run() {
  reset_fakes
  local d; d=$(new_case ci-ready)
  make_repo_on_branch "$d/wt" fm/feat-ci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci.meta" "window=fm:fm-feat-ci" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-ci.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ci)"
  local out; out=$(run_crew_state "$d" feat-ci)
  assert_contains "$out" "state: done" "ci-ready status log -> done"
  assert_contains "$out" "source: status-log" "ci-ready state comes from the status log"
  assert_contains "$out" "checks green" "ci-ready detail preserves the report"
  assert_not_contains "$out" "state: working" "ci-ready is not hidden by monitoring run"
  pass "ci-ready status log beats monitoring run"
}

# Regression for the PR #252 incident: the crew's own status log never got a
# "done: ... checks green" line (log_reports_ci_ready above does not apply),
# but the ci step's log tail shows CI is actually green and only waiting on
# merge/close. fm-crew-state must surface this as done, not "validating
# (running)", so a green PR is never silently absorbed as still-in-progress.
test_ci_monitoring_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-green)
  make_repo_on_branch "$d/wt" fm/feat-cigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cigreen.meta" "window=fm:fm-feat-cigreen" "worktree=$d/wt" "kind=ship"
  # No status-log line at all: the crew never reported its own checks-green line.
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cigreen)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
CI checks running, waiting for results...
all CI checks passed - still monitoring until merged or closed
EOF
)
  local out; out=$(run_crew_state "$d" feat-cigreen)
  assert_contains "$out" "state: done" "green ci-monitor run -> done"
  assert_contains "$out" "source: run-step" "green ci-monitor -> run-step source"
  assert_contains "$out" "checks green" "green ci-monitor detail mentions checks green"
  assert_not_contains "$out" "state: working" "green ci-monitor must not read as still validating"
  pass "ci-monitoring run with checks already green surfaces done"
}

test_top_level_ci_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case top-level-ci-green)
  make_repo_on_branch "$d/wt" fm/feat-topcigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topcigreen.meta" "window=fm:fm-feat-topcigreen" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_top_level_ci fm/feat-topcigreen)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topcigreen)
  assert_contains "$out" "state: done" "top-level ci with green log -> done"
  assert_contains "$out" "source: run-step" "top-level ci green -> run-step source"
  assert_contains "$out" "checks green" "top-level ci green detail mentions checks green"
  assert_not_contains "$out" "state: working" "top-level ci green must not stay working"
  pass "top-level ci status uses ci log green marker"
}

test_ci_monitoring_no_checks_terminal_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-nochecks)
  make_repo_on_branch "$d/wt" fm/feat-cinochecks
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecks.meta" "window=fm:fm-feat-cinochecks" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecks)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cinochecks)
  assert_contains "$out" "state: done" "terminal no-checks ci-monitor run -> done"
  assert_contains "$out" "checks green" "terminal no-checks ci-monitor detail mentions checks green"
  pass "terminal no-checks ci-monitor marker surfaces done"
}

test_ci_monitoring_green_then_rearm_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-rearm)
  make_repo_on_branch "$d/wt" fm/feat-cirearm
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirearm.meta" "window=fm:fm-feat-cirearm" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirearm)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirearm)
  assert_contains "$out" "state: working" "base-advance rearm marker -> working"
  assert_not_contains "$out" "state: done" "base-advance rearm marker must not read as done"
  assert_not_contains "$out" "checks green" "base-advance rearm marker must not read as checks green"
  pass "base-advance rearm after green stays working"
}

test_ci_monitoring_no_checks_yet_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-yet)
  make_repo_on_branch "$d/wt" fm/feat-cinochecksyet
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecksyet.meta" "window=fm:fm-feat-cinochecksyet" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecksyet)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
no CI checks reported - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
no CI checks reported yet, waiting for checks to register...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cinochecksyet)
  assert_contains "$out" "state: working" "pending no-checks marker -> working"
  assert_not_contains "$out" "state: done" "pending no-checks marker must not read as done"
  assert_not_contains "$out" "checks green" "pending no-checks marker must not read as checks green"
  pass "pending no-checks ci-monitor marker stays working"
}

test_ci_monitoring_still_waiting_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-waiting)
  make_repo_on_branch "$d/wt" fm/feat-ciwait
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciwait.meta" "window=fm:fm-feat-ciwait" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciwait)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-ciwait)
  assert_contains "$out" "state: working" "ci step still red -> working"
  assert_not_contains "$out" "checks green" "no green marker present -> no checks-green detail"
  pass "ci-monitoring run with checks not yet green stays working"
}

# A later merge-conflict auto-fix round after an earlier green reading must
# not be masked: the MOST RECENT marker in the log tail wins.
test_ci_monitoring_green_then_new_issue_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-issue)
  make_repo_on_branch "$d/wt" fm/feat-cirelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirelapse.meta" "window=fm:fm-feat-cirelapse" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
issues detected: merge conflict - auto-fixing (attempt 2/10)...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirelapse)
  assert_contains "$out" "state: working" "a later relapse marker must win over an earlier green one"
  assert_not_contains "$out" "state: done" "relapsed ci run must not read as done"
  pass "a fresh issue after an earlier green reading is not masked"
}

test_ci_ready_done_log_relapse_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-ready-then-relapse)
  make_repo_on_branch "$d/wt" fm/feat-cireadyrelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cireadyrelapse.meta" "window=fm:fm-feat-cireadyrelapse" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cireadyrelapse.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cireadyrelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
CI checks running, waiting for results...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cireadyrelapse)
  assert_contains "$out" "state: working" "a stale ready status must not mask a later CI relapse"
  assert_contains "$out" "source: run-step" "relapsed ci run remains run-step sourced"
  assert_not_contains "$out" "state: done" "relapsed ci run with stale done log must not read as done"
  pass "stale checks-green status log does not mask CI relapse"
}

test_ci_fixing_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-fixing-after-green)
  make_repo_on_branch "$d/wt" fm/feat-cifixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cifixing.meta" "window=fm:fm-feat-cifixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cifixing.status"
  FM_FAKE_AXI_STATUS="$(run_ci_fixing fm/feat-cifixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cifixing)
  assert_contains "$out" "state: working" "ci fixing step must stay working"
  assert_contains "$out" "source: run-step" "ci fixing remains run-step sourced"
  assert_not_contains "$out" "state: done" "ci fixing must not read as checks-green done"
  pass "ci fixing is not overridden by an earlier green marker"
}

test_top_level_fixing_ci_running_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-ci-running)
  make_repo_on_branch "$d/wt" fm/feat-topfixingci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixingci.meta" "window=fm:fm-feat-topfixingci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_fixing_ci_running fm/feat-topfixingci)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixingci)
  assert_contains "$out" "state: working" "top-level fixing with ci running must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing with ci running remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not use stale green marker"
  pass "top-level fixing is not overridden by a stale ci running row"
}

test_top_level_fixing_done_log_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-done-log)
  make_repo_on_branch "$d/wt" fm/feat-topfixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixing.meta" "window=fm:fm-feat-topfixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-topfixing.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-topfixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixing)
  assert_contains "$out" "state: working" "top-level fixing must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not read as stale checks-green done"
  pass "top-level fixing is not overridden by a stale done log"
}

# (d) terminal run-step is authoritative
test_terminal_passed() {
  reset_fakes
  local d; d=$(new_case passed)
  make_repo_on_branch "$d/wt" fm/feat-d
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-d.meta" "window=fm:fm-feat-d" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-d)"
  local out; out=$(run_crew_state "$d" feat-d)
  assert_contains "$out" "state: done" "passed run -> done"
  assert_contains "$out" "source: run-step" "passed -> run-step source"
  pass "terminal passed run is authoritative"
}

test_terminal_failed() {
  reset_fakes
  local d; d=$(new_case failed)
  make_repo_on_branch "$d/wt" fm/feat-e
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-e.meta" "window=fm:fm-feat-e" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-e)"
  local out; out=$(run_crew_state "$d" feat-e)
  assert_contains "$out" "state: failed" "failed run -> failed"
  assert_contains "$out" "source: run-step" "failed -> run-step source"
  pass "terminal failed run is authoritative"
}

# A deliberately cancelled merge monitor is no longer the product verdict once
# the worker's latest event declares the bounded external wait that follows it.
# This is red on the historical unconditional cancelled -> failed mapping.
test_cancelled_outcome_then_latest_declared_pause_reads_paused() {
  reset_fakes
  local d; d=$(new_case cancelled-then-pause)
  make_repo_on_branch "$d/wt" fm/feat-cancel-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cancel-pause.meta" \
    "window=fm:fm-feat-cancel-pause" "worktree=$d/wt" "kind=ship"
  printf 'working: cancelling the redundant merge monitor\npaused: holding the green pull request for its landing turn\n' \
    > "$d/state/feat-cancel-pause.status"
  FM_FAKE_AXI_STATUS="$(run_cancelled_outcome fm/feat-cancel-pause)"
  local out; out=$(run_crew_state "$d" feat-cancel-pause)
  assert_contains "$out" "state: paused" "a later declared wait overrides only the cancelled monitor verdict"
  assert_contains "$out" "source: status-log" "the later declaration is the paused-state source"
  assert_not_contains "$out" "state: failed" "a deliberately cancelled monitor is not a failed product"
  pass "cancelled outcome followed by the latest declared pause reads paused"
}

# A checks-green delivery line carries the same hold meaning when the recorded
# pull request is still open, its current head is the recorded pr_head, and all
# checks at that head are complete and green. The fake gh-axi shadows the real
# forge client and records both reads, so this proof cannot reach the real forge.
test_cancelled_status_then_latest_open_green_done_pr_reads_paused() {
  reset_fakes
  local d; d=$(new_case cancelled-then-green-done)
  make_repo_on_branch "$d/wt" fm/feat-cancel-green
  make_fakebin "$d" >/dev/null
  : > "$d/gh-axi.calls"
  fm_write_meta "$d/state/feat-cancel-green.meta" \
    "window=fm:fm-feat-cancel-green" "worktree=$d/wt" "kind=ship" \
    "pr=https://github.com/o/r/pull/2" "pr_head=$FM_FAKE_RUN_HEAD"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' \
    > "$d/state/feat-cancel-green.status"
  FM_FAKE_AXI_STATUS="$(run_cancelled_status fm/feat-cancel-green)"
  FM_FAKE_GH_AXI_CALLS="$d/gh-axi.calls"
  FM_FAKE_PR_STATE=open
  FM_FAKE_PR_HEAD=$FM_FAKE_RUN_HEAD
  FM_FAKE_PR_CHECKS_TOTAL=3
  FM_FAKE_PR_CHECKS_COMPLETED=3
  FM_FAKE_PR_CHECKS_BAD=0
  local out; out=$(run_crew_state "$d" feat-cancel-green)
  assert_contains "$out" "state: paused" "an open green PR at recorded pr_head overrides only cancelled"
  assert_contains "$out" "source: status-log" "the verified done line is the paused-state source"
  [ "$(wc -l < "$d/gh-axi.calls" | tr -d '[:space:]')" -eq 2 ] \
    || fail "the fake forge should receive exactly the PR identity and check reads"
  pass "cancelled status with a latest verified open-green PR declaration reads paused"
}

# The recorded head is part of the declaration proof, not an advisory cache. A
# newer live head makes the checks-green line stale and leaves cancelled failed.
test_cancelled_done_pr_at_a_different_live_head_stays_failed() {
  reset_fakes
  local d; d=$(new_case cancelled-green-stale-head)
  make_repo_on_branch "$d/wt" fm/feat-cancel-stale-head
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cancel-stale-head.meta" \
    "window=fm:fm-feat-cancel-stale-head" "worktree=$d/wt" "kind=ship" \
    "pr=https://github.com/o/r/pull/2" "pr_head=$FM_FAKE_RUN_HEAD"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' \
    > "$d/state/feat-cancel-stale-head.status"
  FM_FAKE_AXI_STATUS="$(run_cancelled_status fm/feat-cancel-stale-head)"
  FM_FAKE_PR_STATE=open
  FM_FAKE_PR_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  FM_FAKE_PR_CHECKS_TOTAL=3
  FM_FAKE_PR_CHECKS_COMPLETED=3
  FM_FAKE_PR_CHECKS_BAD=0
  local out; out=$(run_crew_state "$d" feat-cancel-stale-head)
  assert_contains "$out" "state: failed" "a different live PR head cannot corroborate the declaration"
  assert_contains "$out" "run cancelled" "a stale recorded head keeps cancelled detail"
  pass "a cancelled run with a stale checks-green PR head remains failed"
}

# A live head match is still insufficient when any check is pending or has a
# non-green conclusion. The cancelled failure remains visible.
test_cancelled_done_pr_with_a_non_green_check_stays_failed() {
  reset_fakes
  local d; d=$(new_case cancelled-green-bad-check)
  make_repo_on_branch "$d/wt" fm/feat-cancel-bad-check
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cancel-bad-check.meta" \
    "window=fm:fm-feat-cancel-bad-check" "worktree=$d/wt" "kind=ship" \
    "pr=https://github.com/o/r/pull/2" "pr_head=$FM_FAKE_RUN_HEAD"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' \
    > "$d/state/feat-cancel-bad-check.status"
  FM_FAKE_AXI_STATUS="$(run_cancelled_status fm/feat-cancel-bad-check)"
  FM_FAKE_PR_STATE=open
  FM_FAKE_PR_HEAD=$FM_FAKE_RUN_HEAD
  FM_FAKE_PR_CHECKS_TOTAL=3
  FM_FAKE_PR_CHECKS_COMPLETED=3
  FM_FAKE_PR_CHECKS_BAD=1
  local out; out=$(run_crew_state "$d" feat-cancel-bad-check)
  assert_contains "$out" "state: failed" "a non-green check cannot corroborate the declaration"
  assert_contains "$out" "run cancelled" "a non-green PR keeps cancelled detail"
  pass "a cancelled run with a non-green PR remains failed"
}

# Counterexample: the coarse runs-list source retains today's exact cancelled
# failure when no later declaration exists.
test_coarse_cancelled_with_no_later_declaration_stays_failed_with_detail() {
  reset_fakes
  local d short; d=$(new_case cancelled-coarse-no-declaration)
  make_repo_on_branch "$d/wt" fm/feat-cancel-coarse
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cancel-coarse.meta" \
    "window=fm:fm-feat-cancel-coarse" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="  cancelled  fm/feat-cancel-coarse ${short}  2026-09-09 21:40"
  local out; out=$(run_crew_state "$d" feat-cancel-coarse)
  assert_contains "$out" "state: failed" "cancelled without a later declaration remains failed"
  assert_contains "$out" "source: run-step" "the unchanged cancellation remains run-step sourced"
  assert_contains "$out" "run cancelled" "the unchanged cancellation keeps its exact detail"
  pass "coarse cancelled run with no later declaration stays failed with existing detail"
}

# Ordering counterexample: finding a pause anywhere in the append-only log is
# insufficient. A later working event means the historical pause cannot suppress
# the cancelled run that followed it.
test_pause_before_cancelled_outcome_does_not_suppress_failure() {
  reset_fakes
  local d; d=$(new_case pause-before-cancelled)
  make_repo_on_branch "$d/wt" fm/feat-pause-before-cancel
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pause-before-cancel.meta" \
    "window=fm:fm-feat-pause-before-cancel" "worktree=$d/wt" "kind=ship"
  printf 'paused: earlier external wait\nworking: cancelling the obsolete monitor after the wait cleared\n' \
    > "$d/state/feat-pause-before-cancel.status"
  FM_FAKE_AXI_STATUS="$(run_cancelled_outcome fm/feat-pause-before-cancel)"
  local out; out=$(run_crew_state "$d" feat-pause-before-cancel)
  assert_contains "$out" "state: failed" "an earlier pause cannot override a later cancellation"
  assert_contains "$out" "run cancelled" "the ordering counterexample keeps cancelled detail"
  pass "a pause before cancellation does not suppress the failure"
}

# Scope counterexample: a real failed run remains authoritative even when the
# latest status event declares a wait. This repair is cancelled-only.
test_failed_outcome_with_later_declared_pause_remains_failed() {
  reset_fakes
  local d; d=$(new_case failed-then-pause)
  make_repo_on_branch "$d/wt" fm/feat-failed-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-failed-pause.meta" \
    "window=fm:fm-feat-failed-pause" "worktree=$d/wt" "kind=ship"
  printf 'paused: waiting after a genuine pipeline failure\n' \
    > "$d/state/feat-failed-pause.status"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-failed-pause)"
  local out; out=$(run_crew_state "$d" feat-failed-pause)
  assert_contains "$out" "state: failed" "a genuine failed run remains failed behind a pause"
  assert_contains "$out" "run failed" "the genuine failure keeps its existing detail"
  pass "a genuine failed run is unchanged by a later pause"
}

# A passed-with-override outcome is a distinct exceptional result, never
# ordinary green completion: it must read neither as done nor as plain
# unknown, so a human is required to look before any merge decision.
test_terminal_passed_with_override() {
  reset_fakes
  local d; d=$(new_case override)
  make_repo_on_branch "$d/wt" fm/feat-override
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-override.meta" "window=fm:fm-feat-override" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_with_override fm/feat-override)"
  local out; out=$(run_crew_state "$d" feat-override)
  assert_contains "$out" "state: needs-inspection" "passed-with-override -> needs-inspection, not done"
  assert_not_contains "$out" "state: done" "override must never read as done"
  assert_not_contains "$out" "state: unknown" "override must never collapse to plain unknown"
  assert_contains "$out" "source: run-step" "override -> run-step source"
  pass "terminal passed-with-override run reads as needs-inspection, never done"
}

# An outcome word this file's mapping does not recognize (a future no-mistakes
# release, or a typo) still falls to the safe unknown default rather than any
# state that could be mistaken for a green result.
test_terminal_unrecognized_outcome() {
  reset_fakes
  local d; d=$(new_case unrecognized)
  make_repo_on_branch "$d/wt" fm/feat-unrecognized
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-unrecognized.meta" "window=fm:fm-feat-unrecognized" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_unrecognized_outcome fm/feat-unrecognized)"
  local out; out=$(run_crew_state "$d" feat-unrecognized)
  assert_contains "$out" "state: unknown" "unrecognized outcome -> unknown"
  assert_contains "$out" "outcome: zzz-not-a-real-outcome" "unknown detail names the raw outcome"
  pass "terminal run with an unrecognized outcome falls to unknown, not done"
}

# (e) cross-branch attribution: `axi status` returns ANOTHER branch's run (the
# routine case once more than one crew validates the same underlying repo
# concurrently - they share ONE no-mistakes repo registration), so the helper
# falls back to the real top-level `no-mistakes runs` listing to learn whether
# THIS branch has an active run of its own. Regression coverage for the
# 2026-07-02 herdr incident: the old fallback shelled out to `no-mistakes axi`
# (bare) expecting a `runs[N]{...}:` TOON table that the real CLI never emits
# (verified against the installed v1.32.2 - the `axi` surface has no
# runs-listing subcommand at all), so attribution silently failed every time
# the repo-wide answer was not this crew's own branch.
test_cross_branch_attribution_via_runs_list() {
  reset_fakes
  local d short; d=$(new_case crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-f
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f.meta" "window=fm:fm-feat-f" "worktree=$d/wt" "kind=ship"
  # The repo-wide active/most-recent run belongs to a different crew's branch.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  # Real `no-mistakes runs` shape: plain text, newest-first, no run id, no
  # quoting - "<status> <branch> <short-sha> <date> [<pr-url>]".
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-f ${short}  2026-07-02 22:05
EOF
)"
  local out; out=$(run_crew_state "$d" feat-f)
  assert_contains "$out" "state: working" "this branch's own run attributed via the runs list"
  assert_contains "$out" "source: run-step" "runs-list-resolved run -> run-step source"
  pass "cross-branch run is attributed via the real runs list"
}

# The runs list is newest-first; a branch with an OLDER completed run must not
# shadow its own newer active one - the first (topmost) matching row wins.
test_cross_branch_attribution_picks_most_recent_row() {
  reset_fakes
  local d short; d=$(new_case crossbranch-mostrecent)
  make_repo_on_branch "$d/wt" fm/feat-fq
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-fq.meta" "window=fm:fm-feat-fq" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-fq ${short}  2026-07-02 21:50
  completed  fm/feat-fq bbbbbbb  2026-07-02 20:00  https://github.com/o/r/pull/1
EOF
)"
  local out; out=$(run_crew_state "$d" feat-fq)
  assert_contains "$out" "state: working" "most recent (running) row wins over an older completed row"
  assert_contains "$out" "source: run-step" "most-recent-row resolution -> run-step source"
  pass "cross-branch attribution picks the branch's most recent row"
}

test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status() {
  reset_fakes
  local d short; d=$(new_case coarse-ready-other-log)
  make_repo_on_branch "$d/wt" fm/feat-coarseready
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarseready.meta" "window=fm:fm-feat-coarseready" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/4 checks green\n' > "$d/state/feat-coarseready.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-coarseready ${short}  2026-07-02 22:05
EOF
)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-coarseready)
  assert_contains "$out" "state: done" "coarse ready status -> done"
  assert_contains "$out" "source: status-log" "coarse ready status remains status-log sourced"
  assert_not_contains "$out" "state: working" "coarse ready status must not be suppressed by another branch log"
  pass "coarse run does not probe another branch's ci log"
}

# A different-branch run with NO matching runs-list row must NOT be
# misattributed, and must not be treated as a false "working" verdict either.
test_other_branch_run_ignored() {
  reset_fakes
  local d; d=$(new_case otherbranch)
  make_repo_on_branch "$d/wt" fm/feat-g
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-g.meta" "window=fm:fm-feat-g" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'done: implemented, ready to validate\n' > "$d/state/feat-g.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/some-other)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/some-other aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-g
  local out; out=$(run_crew_state "$d" feat-g)
  assert_not_contains "$out" "source: run-step" "another branch's run not misattributed"
  assert_contains "$out" "source: status-log" "no own run -> falls back to status-log"
  assert_contains "$out" "state: done" "falls back to the log verb"
  pass "another branch's run is ignored, falls back"
}

# (f) no run for this crew + a busy pane -> working via pane
test_no_run_busy_pane() {
  reset_fakes
  local d; d=$(new_case busy)
  make_repo_on_branch "$d/wt" fm/feat-h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h.meta" "window=fm:fm-feat-h" "worktree=$d/wt" "kind=ship" "harness=claude"
  # No matching run anywhere. The busy verdict comes from the crew's own
  # semantic lifecycle record (bin/fm-busy-lib.sh), not from rendered text.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-h)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-h busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-h)
  assert_contains "$out" "state: working" "busy record -> working"
  assert_contains "$out" "source: pane" "busy record -> pane source"
  assert_contains "$out" "claude-hook" "the working verdict names its semantic source"
  pass "no run + a busy semantic record reads working, attributed to its source"
}

# A converted adapter must NOT read working from rendered footer text: the
# redesign removed that dependency, so a pane painting "esc to interrupt" with
# no semantic record is unknown, never working and never silently idle.
test_no_run_footer_text_alone_is_not_working() {
  reset_fakes
  local d; d=$(new_case busy-footer-only)
  make_repo_on_branch "$d/wt" fm/feat-h2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h2.meta" "window=fm:fm-feat-h2" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  printf 'done: stale completion event\n' > "$d/state/feat-h2.status"
  local out; out=$(run_crew_state "$d" feat-h2)
  assert_not_contains "$out" "state: working" "a footer alone must not read working for a converted adapter"
  assert_contains "$out" "state: unknown" "no semantic record -> unknown"
  assert_not_contains "$out" "source: status-log" "unknown semantic state must not fall through to a stale log"
  pass "a converted adapter never reads working from rendered footer text"
}

# Grok keeps its isolated temporary rendered-tail fallback until its structured
# lifecycle is live-verified, so a grok crew still reads working from its own
# verified signature.
test_no_run_grok_uses_isolated_fallback() {
  reset_fakes
  local d; d=$(new_case busy-grok)
  make_repo_on_branch "$d/wt" fm/feat-h3
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h3.meta" "window=fm:fm-feat-h3" "worktree=$d/wt" "kind=ship" "harness=grok"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT='Ctrl+c:cancel'
  export FM_FAKE_BUSY_TEXT
  local out; out=$(run_crew_state "$d" feat-h3)
  assert_contains "$out" "state: working" "grok busy tail -> working"
  assert_contains "$out" "grok-regex" "the grok verdict names its isolated fallback source"
  pass "grok still reads working through its isolated rendered-tail fallback"
}

test_no_run_herdr_unknown_uses_backend_capture() {
  command -v jq >/dev/null 2>&1 || { pass "herdr pane fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-busy)
  make_repo_on_branch "$d/wt" fm/feat-herdr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_BUSY=1
  FM_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" feat-herdr)
  assert_contains "$out" "state: working" "herdr native busy -> working"
  assert_contains "$out" "source: pane" "herdr native busy -> pane source"
  assert_contains "$out" "herdr-native" "the herdr verdict names its native source"
  pass "herdr's native busy verdict reads working with no record present"
}

# Regression (2026-07 herdr false-surface incident, now solved semantically):
# herdr's agent.get reports generation state ("working" only while the model is
# actively streaming - docs/herdr-backend.md "Busy state"), not "this crew's
# turn is still in progress". A crew blocked on its own long-running foreground
# `no-mistakes axi run` (no --yes; blocks until a gate or outcome) is not
# generating for that whole span, so agent.get reads idle. The crew's own
# semantic lifecycle record still says busy for the whole turn, and it outranks
# the narrower native verdict - so the crew is no longer misread as not-working.
test_no_run_herdr_idle_agent_status_outranked_by_record() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle corroboration skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-busy-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-idle
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-idle.meta" "window=default:w1:p3" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  # No run attributable (mirrors a no-mistakes run-step lookup that found no
  # matching row within the configured runs-list window): the crew's semantic
  # busy state is the only remaining signal.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-idle)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-idle busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-herdr-idle)
  assert_contains "$out" "state: working" "a busy record with herdr idle agent_status -> working"
  assert_contains "$out" "claude-hook" "the record's source outranks herdr's narrower native verdict"
  pass "a mid-tool-call crew stays working because its record outranks herdr's generation state"
}

# The record must not mask a genuinely idle or human-blocked agent: an idle
# record with idle agent_status still reads not-busy.
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle+idle-record skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-idle-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stopped.meta" "window=default:w1:p4" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-herdr-stopped.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-stopped)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-stopped idle --gen "$gen" \
    --source claude-hook --event stop
  local out; out=$(run_crew_state "$d" feat-herdr-stopped)
  assert_not_contains "$out" "source: pane" "an idle record must not read as busy"
  assert_contains "$out" "source: status-log" "an idle record falls to the status log"
  pass "an idle record with idle agent_status stays not-busy (no regression for a human-blocked agent)"
}

# (g) no run + idle pane -> the status-log verb, as-is
test_no_run_idle_pane_uses_log() {
  reset_fakes
  local d; d=$(new_case idle)
  make_repo_on_branch "$d/wt" fm/feat-i
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-i.meta" "window=fm:fm-feat-i" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: which database?\n' > "$d/state/feat-i.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-i
  local out; out=$(run_crew_state "$d" feat-i)
  assert_contains "$out" "state: parked" "needs-decision log -> parked"
  assert_contains "$out" "source: status-log" "idle pane -> status-log source"
  pass "no run + idle pane uses the status-log verb"
}

test_no_run_idle_pane_uses_keyed_log() {
  reset_fakes
  local d; d=$(new_case keyed-idle)
  make_repo_on_branch "$d/wt" fm/feat-keyed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-keyed.meta" "window=fm:fm-feat-keyed" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision [key=q1]: which database?\n' > "$d/state/feat-keyed.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-keyed
  local out; out=$(run_crew_state "$d" feat-keyed)
  assert_contains "$out" "state: parked" "keyed needs-decision log -> parked"
  assert_contains "$out" "which database?" "key token is excluded from status detail"
  pass "no run + idle pane parses keyed status syntax"
}

# (g') no run + idle pane on a DECLARED external-wait pause -> state: paused, so a
# supervisor reading the crew sees a distinct pause (and its reason) rather than a
# wedge-suspect idle. This is the reader half the watcher/daemon build on.
test_no_run_idle_pane_paused() {
  reset_fakes
  local d; d=$(new_case paused)
  make_repo_on_branch "$d/wt" fm/feat-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pause.meta" "window=fm:fm-feat-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'paused: holding for the upstream tool release\n' > "$d/state/feat-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-pause
  local out; out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "paused log -> paused"
  assert_contains "$out" "source: status-log" "idle pause -> status-log source"
  assert_contains "$out" "holding for the upstream tool release" "the pause reason is carried in the detail"
  pass "no run + idle pane on a paused: status reports state: paused with its reason"
}

test_no_run_idle_pane_custom_paused_verb() {
  reset_fakes
  local d; d=$(new_case custom-paused)
  make_repo_on_branch "$d/wt" fm/feat-custom-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-custom-pause.meta" "window=fm:fm-feat-custom-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'awaiting: vendor maintenance window\n' > "$d/state/feat-custom-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-custom-pause
  local out; out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: paused" "custom paused verb -> paused"
  assert_contains "$out" "source: status-log" "custom paused verb -> status-log source"
  assert_contains "$out" "vendor maintenance window" "custom pause preserves its reason"
  printf 'paused: default verb no longer selected\n' > "$d/state/feat-custom-pause.status"
  out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: unknown" "custom paused verb replaces the default"
  pass "no run + idle pane honors the configured paused verb"
}

# A trailing keyed resolved: event is a decision-CLOSING event, not a run-state
# verb. It must never become the current state or leak its resolution prose as the
# detail: a healthy idle secondmate that just closed a keyed decision falls through
# to the idle default (unknown/none), not `unknown` with the resolution note as its
# `doing`. Regression for the bearings render bug where such a secondmate showed
# state=unknown with resolution prose. The one-owner keyed fold in fm-classify-lib.sh
# is untouched; this only stops the deriver from reading a non-state event as state.
test_no_run_idle_secondmate_resolved_event_not_state() {
  reset_fakes
  local d; d=$(new_case resolved-idle)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "home=$d/wt"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$d/state/mate.status"
  printf 'resolved [key=race]: went with subscribe-before-write\n' >> "$d/state/mate.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "resolved-then-idle secondmate is not a spurious run-state"
  assert_contains "$out" "source: none" "a resolved event is not treated as a status-log state source"
  assert_not_contains "$out" "subscribe-before-write" "resolution prose must not leak into the detail"
  # A bare (non-keyed) resolved: closes the default key and behaves the same.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "source: none" "a bare resolved: is not a state source either"
  assert_not_contains "$out" "infra access granted" "bare resolution prose must not leak into the detail"
  # Control: a genuine trailing state verb still renders from the log.
  printf 'working: reconciling routed items\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: working" "a real trailing state verb still renders"
  assert_contains "$out" "reconciling routed items" "a real state line still carries its detail"
  pass "a trailing resolved: event does not corrupt state render (idle stays idle)"
}

test_dead_window_ignores_stale_status_log() {
  reset_fakes
  local d; d=$(new_case dead-window)
  make_repo_on_branch "$d/wt" fm/feat-dead
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead.meta" "window=fm:fm-feat-dead" "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-dead.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead)
  assert_contains "$out" "state: unknown" "dead window -> unknown"
  assert_contains "$out" "source: none" "dead window -> none source"
  assert_not_contains "$out" "source: status-log" "dead window does not reuse stale log"
  pass "dead window ignores stale status log"
}

# A closed/unreadable pane must NOT mask an authoritative run-step: judge by the
# run-step, not the shell. The common case is a finished crew whose agent has
# exited and closed its window (the normal gap between completion and teardown) -
# it must still report its terminal run-step state (e.g. done), never unknown.
test_dead_window_still_reports_terminal_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-done)
  make_repo_on_branch "$d/wt" fm/feat-dead-done
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-done.meta" "window=fm:fm-feat-dead-done" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/3 checks green\n' > "$d/state/feat-dead-done.status"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-dead-done)"
  FM_FAKE_TMUX_MISSING=1   # the crew's window has closed
  local out; out=$(run_crew_state "$d" feat-dead-done)
  assert_contains "$out" "state: done" "closed pane still reports terminal run-step done"
  assert_contains "$out" "source: run-step" "closed pane does not mask the run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with a run must never be unknown"
  pass "closed pane still reports a terminal run-step"
}

# The same for an active run: an agent pane that crashed mid-validation while the
# daemon-backed run continues must report the live run-step, not unknown.
test_dead_window_still_reports_active_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-active)
  make_repo_on_branch "$d/wt" fm/feat-dead-act
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-act.meta" "window=fm:fm-feat-dead-act" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-dead-act)"
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead-act)
  assert_contains "$out" "state: working" "closed pane still reports active run-step"
  assert_contains "$out" "source: run-step" "closed pane does not mask the active run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with an active run must never be unknown"
  pass "closed pane still reports an active run-step"
}

test_no_timeout_uses_perl_bound() {
  reset_fakes
  local d toolbin out start elapsed calls_file calls
  d=$(new_case no-timeout)
  make_repo_on_branch "$d/wt" fm/feat-timeout
  make_fakebin "$d" >/dev/null
  calls_file="$d/no-mistakes.calls"
  : > "$calls_file"
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_NM_CALLS:-/dev/null}"
while :; do :; done
SH
  chmod +x "$d/fakebin/no-mistakes"
  toolbin=$(make_no_timeout_toolbin "$d")
  fm_write_meta "$d/state/feat-timeout.meta" "window=fm:fm-feat-timeout" "worktree=$d/wt" "kind=ship" \
    "harness=claude"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-timeout)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-timeout busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  start=$SECONDS
  out=$(FM_FAKE_NM_CALLS="$calls_file" PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" feat-timeout)
  elapsed=$((SECONDS - start))
  assert_contains "$out" "state: working" "timed-out no-mistakes falls back to pane"
  assert_contains "$out" "source: pane" "timed-out no-mistakes -> pane source"
  [ "$elapsed" -lt 5 ] || fail "perl timeout did not bound no-mistakes calls (elapsed ${elapsed}s)"
  calls=$(awk 'END { print NR + 0 }' "$calls_file" 2>/dev/null || echo 0)
  [ "$calls" -eq 1 ] || fail "empty no-mistakes status triggered extra lookups ($calls calls)"
  pass "no timeout command uses perl bound"
}

# (i) kind=scout skips the run lookup entirely (its deliverable is a report).
test_scout_skips_run_lookup() {
  reset_fakes
  local d; d=$(new_case scout)
  make_repo_on_branch "$d/wt" fm/scout-j
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/scout-j.meta" "window=fm:fm-scout-j" "worktree=$d/wt" "kind=scout" \
    "harness=claude"
  # Even if a run existed on this branch, a scout must not read it.
  FM_FAKE_AXI_STATUS="$(run_running fm/scout-j)"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" scout-j)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" scout-j busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" scout-j)
  assert_not_contains "$out" "source: run-step" "scout ignores no-mistakes run-step"
  assert_contains "$out" "source: pane" "scout reads its semantic busy state"
  pass "scout skips the run lookup"
}

# (j) torn-down worktree and missing meta are graceful (unknown/none, exit 0)
test_torn_down_worktree() {
  reset_fakes
  local d; d=$(new_case torndown)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/gone-k.meta" "window=fm:fm-gone-k" "worktree=$d/no-such-worktree" "kind=ship"
  local out rc
  out=$(run_crew_state "$d" gone-k); rc=$?
  expect_code 0 "$rc" "torn-down worktree exits 0"
  assert_contains "$out" "state: unknown" "torn-down -> unknown"
  assert_contains "$out" "source: none" "torn-down -> none source"
  pass "torn-down worktree is handled gracefully"
}

# --- remote secondmate arm ---------------------------------------------------
# A meta recording remote_host= must never be read through the local worktree
# probe or a local backend adapter: the recorded worktree and pane live on the
# remote host, and the old local reads misreported a healthy remote mate as
# "worktree gone". These cases drive the real helper over the real fm-on.sh
# route with a stubbed ssh transport (FM_SSH_BIN seam): the stub prints
# FM_FAKE_REMOTE_STATE_OUT as the remote endpoint's recovery-grade state and
# exits FM_FAKE_SSH_RC.

setup_remote_case() {  # <name> -> echoes case dir with remote meta + registry
  local d
  d=$(new_case "$1")
  mkdir -p "$d/data" "$d/fakebin"
  fm_write_meta "$d/state/rsm.meta" \
    "window=remote:rsm" \
    "endpoint_task_id=rsm" \
    "worktree=/remote/home/never-locally-present" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
  cat > "$d/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  cat > "$d/fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
[ -z "${FM_FAKE_REMOTE_STATE_OUT:-}" ] || printf '%s\n' "$FM_FAKE_REMOTE_STATE_OUT"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$d/fakebin/fake-ssh"
  printf '%s\n' "$d"
}

run_remote_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_SSH_BIN="$1/fakebin/fake-ssh" "$CREW_STATE" "$2"
}

test_remote_alive_with_log_uses_status_log() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-alive-log)
  make_fakebin "$d" >/dev/null
  printf 'working: refactoring the quota adapter\n' > "$d/state/rsm.status"
  out=$(FM_FAKE_REMOTE_STATE_OUT=alive FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote alive exits 0"
  assert_contains "$out" "state: working" "alive remote mate with a working log reads working"
  assert_contains "$out" "source: status-log" "alive remote mate reads current activity from the routed log"
  assert_contains "$out" "remote endpoint alive on remote-mac" "the remote liveness read should be visible"
  assert_not_contains "$out" "worktree gone" "a healthy remote mate must never read as torn down"
  pass "fm-crew-state remote: alive endpoint falls through to the routed status log"
}

test_remote_alive_idle_is_healthy_not_gone() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-alive-idle)
  make_fakebin "$d" >/dev/null
  out=$(FM_FAKE_REMOTE_STATE_OUT=alive FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote alive-idle exits 0"
  assert_contains "$out" "source: remote-endpoint" "the remote endpoint is the reported source"
  assert_contains "$out" "alive on remote-mac" "an idle remote mate reads alive"
  assert_not_contains "$out" "worktree gone" "a healthy remote mate must never read as torn down"
  assert_not_contains "$out" "backend target gone" "a healthy remote mate must never read as a dead target"
  pass "fm-crew-state remote: an idle alive endpoint reads alive, never gone or dead"
}

test_remote_unreachable_is_unknown_remote_not_dead() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-unreachable)
  make_fakebin "$d" >/dev/null
  printf 'working: refactoring the quota adapter\n' > "$d/state/rsm.status"
  out=$(FM_FAKE_SSH_RC=255 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "unreachable remote exits 0"
  assert_contains "$out" "unknown-remote" "an unreachable remote must be labeled unknown-remote"
  assert_contains "$out" "not proof of death" "an unreachable remote must not read as dead"
  assert_not_contains "$out" "worktree gone" "an unreachable remote must never read as torn down"
  assert_not_contains "$out" "backend target gone" "an unreachable remote must never read as a dead target"
  pass "fm-crew-state remote: an unreachable host reads unknown-remote, never gone or dead"
}

test_remote_dead_reports_remote_verdict() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-dead)
  make_fakebin "$d" >/dev/null
  out=$(FM_FAKE_REMOTE_STATE_OUT=dead FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote dead exits 0"
  assert_contains "$out" "remote endpoint dead on remote-mac" \
    "a genuinely dead remote endpoint reports the remote host's own verdict"
  pass "fm-crew-state remote: the remote host's own dead verdict is reported truthfully"
}

test_missing_meta() {
  reset_fakes
  local d; d=$(new_case nometa)
  make_fakebin "$d" >/dev/null
  local out rc
  out=$(run_crew_state "$d" ghost-z); rc=$?
  expect_code 0 "$rc" "missing meta exits 0"
  assert_contains "$out" "state: unknown" "missing meta -> unknown"
  assert_contains "$out" "source: none" "missing meta -> none source"
  pass "missing meta is handled gracefully"
}

# (k) crew_is_provably_working end-to-end over the REAL fm-crew-state.sh (not a
# canned fake verdict, unlike tests/fm-watch-triage.test.sh's classifier
# coverage). This is the direct regression pair for the 2026-07-02 herdr
# incident: a validating crew whose bare `axi status` answer belongs to
# another branch must still be absorbed by the watcher via the runs-list
# fallback (working), while a crew with genuinely no run anywhere and an idle
# pane must still surface (the safety property the fix must never widen away).
test_provably_working_via_runs_list_fallback() {
  reset_fakes
  local d short; d=$(new_case provably-working-crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-provable
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-provable.meta" "window=fm:fm-feat-provable" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-provable ${short}  2026-07-02 22:05
EOF
)"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-provable \
    || fail "cross-branch attribution via the runs list was not treated as provably working"
  pass "crew_is_provably_working absorbs a validating crew found only via the runs-list fallback"
}

test_not_provably_working_when_stopped() {
  reset_fakes
  local d; d=$(new_case provably-working-stopped)
  make_repo_on_branch "$d/wt" fm/feat-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-stopped.meta" "window=fm:fm-feat-stopped" "worktree=$d/wt" "kind=ship"
  # Repo-wide run belongs to someone else, and this branch has no row in the
  # runs list either (it never validated, or genuinely finished/stopped) - the
  # only remaining signal is the pane, which is idle.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-stopped \
    && fail "a stopped crew with no run anywhere and an idle pane was treated as provably working"
  pass "crew_is_provably_working still surfaces a genuinely stopped crew (safety property preserved)"
}

# The merge-readiness consumer: crew_absorb_class/crew_is_provably_working is
# the one downstream reader that turns fm-crew-state's raw state token into an
# autonomous absorb-or-surface decision. A passed-with-override run must never
# be absorbed as working (its own case, not the "genuinely stopped" one above)
# - it must surface every time, so a human looks before anything merges.
test_not_provably_working_when_passed_with_override() {
  reset_fakes
  local d; d=$(new_case provably-working-override)
  make_repo_on_branch "$d/wt" fm/feat-override-absorb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-override-absorb.meta" "window=fm:fm-feat-override-absorb" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_with_override fm/feat-override-absorb)"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-override-absorb \
    && fail "a passed-with-override run must never be absorbed as provably working"
  pass "crew_is_provably_working surfaces a passed-with-override run instead of absorbing it"
}

# Usage error (no id) is the one non-zero exit.
test_usage_error() {
  reset_fakes
  local rc
  "$CREW_STATE" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no-arg usage error exits 2"
  pass "usage error exits 2"
}

# Head-binding: same branch name with a rewritten/diverged worktree tip must not
# attribute a historical no-mistakes run (multi-stage branch reuse incident).
test_historical_same_branch_rewritten_head_not_current() {
  reset_fakes
  local d old_head new_head out
  d=$(new_case rewritten-head)
  make_repo_on_branch "$d/wt" fm/todo-flag
  old_head=$(git -C "$d/wt" rev-parse HEAD)
  # Simulate a rebase rewrite: orphan new history on the same branch name.
  git -C "$d/wt" checkout -q --orphan tmp-rewrite
  git -C "$d/wt" commit -q --allow-empty -m 'rewritten tip'
  git -C "$d/wt" branch -q -M fm/todo-flag
  new_head=$(git -C "$d/wt" rev-parse HEAD)
  [ "$old_head" != "$new_head" ] || fail "rewrite did not produce a new head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/wishlist.meta" "window=fm:fm-wishlist" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 setup complete rebased onto merged #76\n' > "$d/state/wishlist.status"
  # Historical run still reports the pre-rewrite head on the reused branch.
  FM_FAKE_RUN_HEAD="$old_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/todo-flag)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" wishlist
  out=$(run_crew_state "$d" wishlist)
  assert_not_contains "$out" "source: run-step" "historical rewritten head must not use run-step"
  assert_not_contains "$out" "parked at" "historical parked run must not mask current state"
  assert_contains "$out" "source: status-log" "falls back to status-log after head mismatch"
  assert_contains "$out" "state: working" "status-log working: remains current"
  pass "historical same-branch rewritten head is not attributed as current"
}

# Head-binding: an active pipeline whose run head is a descendant of the local
# tip (fix commits on the same history) remains current.
test_active_run_descendant_fix_head_remains_current() {
  reset_fakes
  local d base_head fix_head out
  d=$(new_case pipeline-descendant)
  make_repo_on_branch "$d/wt" fm/feat-pipeline
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'pipeline fix commit'
  fix_head=$(git -C "$d/wt" rev-parse HEAD)
  # Worktree still at the pre-fix tip; run reports the pipeline fix head.
  git -C "$d/wt" reset -q --hard "$base_head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/pipe.meta" "window=fm:fm-pipe" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$fix_head"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-pipeline)"
  out=$(run_crew_state "$d" pipe)
  assert_contains "$out" "source: run-step" "descendant pipeline fix head remains run-step"
  assert_contains "$out" "state: working" "active fixing run remains working"
  pass "active run with valid descendant fix head remains current"
}

# Head-binding: local work that advanced past the run head invalidates the run.
test_local_advanced_past_run_head_invalidates() {
  reset_fakes
  local d run_head out
  d=$(new_case local-advanced)
  make_repo_on_branch "$d/wt" fm/feat-adv
  run_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'local stage-2 work after prior run'
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/adv.meta" "window=fm:fm-adv" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 implementation in progress\n' > "$d/state/adv.status"
  FM_FAKE_RUN_HEAD="$run_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-adv)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" adv
  out=$(run_crew_state "$d" adv)
  assert_not_contains "$out" "source: run-step" "local-advanced tip must not use historical run"
  assert_contains "$out" "source: status-log" "falls back after local advanced past run"
  assert_contains "$out" "state: working" "status-log working: is current"
  pass "local work advanced past run head invalidates attribution"
}

# --- Run-attribution precedence for pipeline-owned lane heads ----------------
# A live run whose pipeline OWNS the branch (branch_sync.state=pipeline_owned)
# can report a lane head that is not a git object in the task worktree.
# Every fixture head is deliberately unresolvable so only the top-level
# branch_sync exemption - never an accidental nested-field match - attributes
# the run.
run_running_pipeline_owned() {  # <branch> <head> [<sync-state>]
  cat <<EOF
run:
  id: "01RUNLIVE"
  branch: $1
  status: running
  head: "$2"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
branch_sync:
  state: ${3:-pipeline_owned}
  changed: false
  local:
    branch: $1
    head: "e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5"
    clean: true
  next_action:
    code: continue_active_run
    command: no-mistakes axi status
EOF
}

# T1 direction 1: the daemon-attributed ACTIVE pipeline-owned run binds without
# head equality and wins over the older superseded failed row.
test_pipeline_owned_active_run_beats_superseded_failed_row() {
  reset_fakes
  local d short; d=$(new_case f10-pipeline-owned)
  make_repo_on_branch "$d/wt" fm/feat-f10
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10.meta" "window=fm:fm-feat-f10" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running_pipeline_owned fm/feat-f10 f0f0f0f0)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-f10 f0f0f0f0  2026-08-27 13:53
  failed     fm/feat-f10 ${short}  2026-08-27 12:09
EOF
)"
  local out; out=$(run_crew_state "$d" feat-f10)
  assert_contains "$out" "state: working" "pipeline-owned live run -> working"
  assert_contains "$out" "source: run-step" "pipeline-owned live run -> run-step source"
  assert_not_contains "$out" "state: failed" "superseded failed row must not surface over the live run"
  pass "pipeline-owned active run binds without head equality and beats the failed row"
}

# T1 direction 2: a genuinely-failed run with NO later run on the branch still
# surfaces as failed - hiding real failures is equally wrong.
test_failed_run_with_no_later_run_still_surfaces() {
  reset_fakes
  local d short; d=$(new_case f10-genuine-failure)
  make_repo_on_branch "$d/wt" fm/feat-f10b
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10b.meta" "window=fm:fm-feat-f10b" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-f10b)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-f10b ${short}  2026-08-27 12:09"
  local out; out=$(run_crew_state "$d" feat-f10b)
  assert_contains "$out" "state: failed" "a genuinely failed run with no later run still reports failed"
  assert_contains "$out" "source: run-step" "the genuine failure is run-step sourced"
  pass "a genuinely failed run with no later run is not hidden"
}

# The coarse runs-list rows: the branch's newest row is ACTIVE at an
# unresolvable head and the row immediately before it ended at exactly this
# worktree's head - the ledger proves this is this crew's own pipeline-owned
# fix round (axi status answers another branch here, so attribution can only
# go through the coarse list). The anchored active run answers via the
# run-step, and the older failed row never surfaces.
test_coarse_unresolvable_active_row_never_falls_to_older_row() {
  reset_fakes
  local d short; d=$(new_case f10-coarse-guard)
  make_repo_on_branch "$d/wt" fm/feat-f10c
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10c.meta" "window=fm:fm-feat-f10c" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-27 14:00
  running    fm/feat-f10c f0f0f0f0  2026-08-27 13:53
  failed     fm/feat-f10c ${short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-f10c)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-f10c busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-f10c)
  assert_not_contains "$out" "state: failed" "an unresolvable active row must not fall to the older failed row"
  assert_contains "$out" "source: run-step" "the ledger-anchored continuation binds via the runs list"
  assert_contains "$out" "state: working" "the anchored active fix round reads working"
  assert_contains "$out" "validating (background run)" "coarse resolution keeps coarse run detail"
  pass "coarse scan anchors the unresolvable active row instead of falling to an older one"
}

# Coarse negative control: the anchor must end at EXACTLY this worktree's
# head. The newest same-branch row is active at an unresolvable head, but the
# row immediately before it sits at an OLDER local commit, so the ledger
# proves nothing - unknown attribution stops the scan, never falls to the
# older failed row, and the busy pane answers instead.
test_coarse_mismatched_anchor_falls_to_pane_not_older_row() {
  reset_fakes
  local d old_short; d=$(new_case f10-coarse-no-anchor)
  make_repo_on_branch "$d/wt" fm/feat-f10g
  git -C "$d/wt" commit -q --allow-empty -m 'second local commit'
  old_short=$(git -C "$d/wt" rev-parse --short=8 HEAD~1)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10g.meta" "window=fm:fm-feat-f10g" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-27 14:00
  running    fm/feat-f10g f0f0f0f0  2026-08-27 13:53
  failed     fm/feat-f10g ${old_short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-f10g)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-f10g busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-f10g)
  assert_not_contains "$out" "state: failed" "a mismatched anchor must not fall to the older failed row"
  assert_not_contains "$out" "source: run-step" "unknown attribution must not bind a run"
  assert_contains "$out" "state: working" "the busy crew still reads working through the pane fallback"
  assert_contains "$out" "source: pane" "without an exact anchor the pane answers, not the runs rows"
  pass "coarse scan with a mismatched anchor stays unknown and lets the pane answer"
}

# Negative control: the exemption is gated on pipeline_owned specifically - any
# other branch_sync state keeps the strict head rule.
test_non_pipeline_owned_unresolvable_head_not_attributed() {
  reset_fakes
  local d; d=$(new_case f10-not-owned)
  make_repo_on_branch "$d/wt" fm/feat-f10d
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10d.meta" "window=fm:fm-feat-f10d" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-f10d.status"
  FM_FAKE_AXI_STATUS="$(run_running_pipeline_owned fm/feat-f10d f0f0f0f0 synced)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-f10d
  local out; out=$(run_crew_state "$d" feat-f10d)
  assert_not_contains "$out" "source: run-step" "a non-pipeline-owned unresolvable head must not bind"
  assert_contains "$out" "source: status-log" "falls back to the status log without the exemption"
  pass "the exemption requires branch_sync.state=pipeline_owned"
}

# Negative control: the exemption also requires an ACTIVE run - a terminal run
# released the branch, so an inconsistent pipeline_owned label must not bind a
# terminal run by branch name alone.
test_pipeline_owned_terminal_run_not_exempt() {
  reset_fakes
  local d; d=$(new_case f10-terminal-not-exempt)
  make_repo_on_branch "$d/wt" fm/feat-f10e
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10e.meta" "window=fm:fm-feat-f10e" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 in progress\n' > "$d/state/feat-f10e.status"
  FM_FAKE_AXI_STATUS="$(run_running_pipeline_owned fm/feat-f10e f0f0f0f0)
outcome: failed"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-f10e
  local out; out=$(run_crew_state "$d" feat-f10e)
  assert_not_contains "$out" "source: run-step" "a terminal run must not bind through the exemption"
  assert_contains "$out" "source: status-log" "falls back to the status log for a terminal unresolvable head"
  pass "the exemption never applies to a terminal run"
}

test_missing_run_head_falls_back_to_current_state() {
  reset_fakes
  local d out
  d=$(new_case missing-run-head)
  make_repo_on_branch "$d/wt" fm/feat-no-head
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/no-head.meta" "window=fm:fm-no-head" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: current stage still in progress\n' > "$d/state/no-head.status"
  FM_FAKE_AXI_STATUS=$(run_parked fm/feat-no-head | grep -v '^  head:')
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" no-head
  out=$(run_crew_state "$d" no-head)
  assert_not_contains "$out" "source: run-step" "missing run head must not permit branch-only attribution"
  assert_contains "$out" "source: status-log" "missing run head falls back to current state sources"
  assert_contains "$out" "state: working" "status-log remains current after missing run head"
  pass "missing run head falls back instead of matching by branch"
}

# Mint a descendant of <repo>'s HEAD in a separate clone, echoing its full sha.
# The task copy never receives the new object, which is exactly the incident
# shape: the pipeline committed its fix round in its own checkout, so the run
# head advanced beyond the submitted head while the task copy lacks the commit.
mint_unfetched_fix_head() {  # <worktree>
  local wt=$1 h2
  rm -rf "$wt.pipe"
  git clone -q "$wt" "$wt.pipe"
  git -C "$wt.pipe" commit -q --allow-empty -m 'pipeline fix round commit'
  h2=$(git -C "$wt.pipe" rev-parse HEAD)
  if git -C "$wt" cat-file -e "$h2" 2>/dev/null; then
    fail "fixture broken: fix head object leaked into the task copy"
  fi
  printf '%s' "$h2"
}

# Head-binding regression (model-routing-benchmark-hardening incident): the
# active run's head advanced beyond the submitted head through a pipeline fix
# round whose commit object never reached the task copy. The reader must
# attribute the active run through the pipeline's own ledger - its newest row
# for the branch is active with a locally unverifiable head, and the row
# immediately before it ended at exactly this worktree's head - instead of
# rejecting the active row and letting the older failed row answer.
test_active_fix_round_unfetched_pipeline_head_reports_current() {
  reset_fakes
  local d h1 h2 out
  d=$(new_case unfetched-fix-head)
  make_repo_on_branch "$d/wt" fm/feat-unfetched
  h1=$(git -C "$d/wt" rev-parse HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  [ "$h1" != "$h2" ] || fail "fix head did not advance past the submitted head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unfetched.meta" "window=fm:fm-unfetched" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-unfetched)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other aaaaaaa  2026-07-30 22:10
  running    fm/feat-unfetched $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-unfetched $(git -C "$d/wt" rev-parse --short=7 HEAD)  2026-07-29 20:00
EOF
)"
  out=$(run_crew_state "$d" unfetched)
  assert_contains "$out" "source: run-step" "active run with an unfetched pipeline head still attributes"
  assert_contains "$out" "state: working" "active fix round reads working, not the older failed row"
  assert_contains "$out" "validating (fixing)" "full run detail survives the unfetched pipeline head"
  assert_not_contains "$out" "state: failed" "the older failed row must never answer for the active run"
  pass "active fix round with an unfetched pipeline head reads working"
}

# Negative control for the ledger continuation rule: without the anchor row
# ending at exactly this worktree's head, an active row with an unverifiable
# head is branch-name coincidence and must stay unattributed - the historical
# status-log fallback answers instead, never the runs rows.
test_unanchored_unfetched_active_row_does_not_match() {
  reset_fakes
  local d h2 out
  d=$(new_case unfetched-no-anchor)
  make_repo_on_branch "$d/wt" fm/feat-noanchor
  # A second commit gives the ledger a resolvable anchor row (HEAD~1) that is
  # NOT this worktree's head - the exact-equality anchor must fail on it.
  git -C "$d/wt" commit -q --allow-empty -m 'second local commit'
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/noanchor.meta" "window=fm:fm-noanchor" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'failed: earlier stage run\n' > "$d/state/noanchor.status"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-noanchor)"
  # The row before the active one is an OLDER commit, not this worktree's
  # head: the ledger proves nothing about whose run the active row is.
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other aaaaaaa  2026-07-30 22:10
  running    fm/feat-noanchor $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-noanchor $(git -C "$d/wt" rev-parse --short=7 HEAD~1)  2026-07-29 20:00
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" noanchor
  out=$(run_crew_state "$d" noanchor)
  assert_not_contains "$out" "source: run-step" "an unanchored unverifiable active row must not match"
  assert_contains "$out" "source: status-log" "historical fallback preserved when no active run is proven"
  assert_contains "$out" "state: failed" "status-log answers, not the runs rows"
  pass "unanchored unverifiable active row is never attributed"
}

# Negative control: a TERMINAL row whose commit object is gone from the task
# copy is history even when it is the branch's newest row - an ancient or
# rewritten run whose commit was pruned must never read as current state.
test_unresolved_terminal_row_is_history_not_current() {
  reset_fakes
  local d h_old out
  d=$(new_case unresolved-terminal)
  make_repo_on_branch "$d/wt" fm/feat-hist
  # Mint the historical run head outside the task copy, then orphan-rewrite
  # the worktree tip, so the run head can never resolve locally.
  h_old=$(mint_unfetched_fix_head "$d/wt")
  git -C "$d/wt" checkout -q --orphan tmp-rewrite
  git -C "$d/wt" commit -q --allow-empty -m 'rewritten tip'
  git -C "$d/wt" branch -q -M fm/feat-hist
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/hist.meta" "window=fm:fm-hist" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 in progress\n' > "$d/state/hist.status"
  FM_FAKE_RUN_HEAD="$h_old"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-hist)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/feat-hist $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-01 20:00
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" hist
  out=$(run_crew_state "$d" hist)
  assert_not_contains "$out" "source: run-step" "an unresolvable terminal row is history, not current state"
  assert_contains "$out" "source: status-log" "historical fallback answers after an unresolvable terminal row"
  assert_contains "$out" "state: working" "the rewritten worktree's own log stays current"
  pass "unresolvable terminal row never reads as current"
}

# The same continuation recognition must work when bare `axi status` answers
# with ANOTHER branch's run: this branch's own active run is then visible only
# in the ledger, with coarse (status-word) detail.
test_runs_list_continuation_found_when_axi_answers_other_branch() {
  reset_fakes
  local d h1 h2 out
  d=$(new_case unfetched-coarse)
  make_repo_on_branch "$d/wt" fm/feat-coarsefix
  h1=$(git -C "$d/wt" rev-parse HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/coarsefix.meta" "window=fm:fm-coarsefix" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-30 22:10
  running    fm/feat-coarsefix $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-coarsefix $(git -C "$d/wt" rev-parse --short=7 HEAD)  2026-07-29 20:00
EOF
)"
  out=$(run_crew_state "$d" coarsefix)
  assert_contains "$out" "source: run-step" "ledger continuation attributes via the runs list too"
  assert_contains "$out" "state: working" "coarse continuation reads working"
  assert_contains "$out" "validating (background run)" "coarse resolution keeps coarse detail, not the other branch's run"
  pass "runs-list continuation attribution works when axi answers another branch"
}

# --- Codex attribution and unmapped-terminal-state coverage -----------------
# Advisor finding 13.8-2 (2026-09-08): every Codex lane read `unknown` while an
# explicit run query answered correctly. Two independent mechanisms produced
# that one symptom, and the four cases below are the closure set for both, each
# one on a harness=codex lane so the unverified pane is present exactly as it is
# in production. Codex has no verified semantic busy source on the installed
# codex-cli (docs/verification/supervision.md), so `fm_busy_classify` answers
# `unknown codex-unverified` for all four; a correct classification must
# therefore come from the run record or the status log, never from the pane.

# Closure case 1 of 4: one real running step. The run record is authoritative
# even though the pane cannot be read at all, so an unverified adapter never
# downgrades a lane that is provably mid-run.
test_codex_running_step_beats_unverified_pane() {
  reset_fakes
  local d; d=$(new_case codex-running)
  make_repo_on_branch "$d/wt" fm/feat-cxrun
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cxrun.meta" "window=fm:fm-feat-cxrun" "worktree=$d/wt" \
    "kind=ship" "harness=codex"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-cxrun)"
  local out; out=$(run_crew_state "$d" feat-cxrun)
  assert_contains "$out" "state: working" "codex running step -> working"
  assert_contains "$out" "source: run-step" "codex running step -> run-step source"
  assert_not_contains "$out" "codex-unverified" "a readable run must not mention the pane at all"
  pass "codex lane with a running step reports working from the run, not the pane"
}

# Closure case 2 of 4: one actionable parked gate. The gate and its finding
# count must survive on a Codex lane, because a gate nobody sees is a lane that
# never gets its decision.
test_codex_parked_gate_beats_unverified_pane() {
  reset_fakes
  local d; d=$(new_case codex-parked)
  make_repo_on_branch "$d/wt" fm/feat-cxgate
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cxgate.meta" "window=fm:fm-feat-cxgate" "worktree=$d/wt" \
    "kind=ship" "harness=codex"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-cxgate)"
  local out; out=$(run_crew_state "$d" feat-cxgate)
  assert_contains "$out" "state: parked" "codex parked gate -> parked"
  assert_contains "$out" "source: run-step" "codex parked gate -> run-step source"
  assert_contains "$out" "parked at review" "the gate is named"
  assert_contains "$out" "ask-user" "an ask-user finding is surfaced for the authority decision"
  pass "codex lane parked at a gate reports the actionable gate, not unknown"
}

# Closure case 3 of 4: one finished-but-unmerged run. `ci_monitor_interrupted`
# means the daemon restarted while babysitting an already-created PR: the PR is
# open and intact, but nothing ever reported a check verdict. That is neither
# done nor failed, and it must never read as plain unknown, because unknown is
# what let this condition sit unnoticed on live lanes.
test_ci_monitor_interrupted_outcome_needs_inspection() {
  reset_fakes
  local d; d=$(new_case cimon-outcome)
  make_repo_on_branch "$d/wt" fm/feat-cximon
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cximon.meta" "window=fm:fm-feat-cximon" "worktree=$d/wt" \
    "kind=ship" "harness=codex"
  FM_FAKE_AXI_STATUS="$(run_ci_monitor_interrupted_outcome fm/feat-cximon)"
  local out; out=$(run_crew_state "$d" feat-cximon)
  assert_contains "$out" "state: needs-inspection" "ci-monitor-interrupted outcome -> needs-inspection"
  assert_not_contains "$out" "state: unknown" "the interrupted monitor must not collapse to unknown"
  assert_not_contains "$out" "state: done" "an unverdicted PR must never read as done"
  assert_not_contains "$out" "state: failed" "an intact PR must never read as a pipeline failure"
  assert_contains "$out" "never autonomous" "the detail forbids an autonomous merge"
  pass "ci-monitor-interrupted outcome reads as needs-inspection, never unknown"
}

# The same one condition reaches the reader through the `status:` field alone
# (underscored spelling, no outcome line) whenever the run is read before the
# outcome word is rendered. Same cause, same required verdict.
test_ci_monitor_interrupted_status_needs_inspection() {
  reset_fakes
  local d; d=$(new_case cimon-status)
  make_repo_on_branch "$d/wt" fm/feat-cximon2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cximon2.meta" "window=fm:fm-feat-cximon2" "worktree=$d/wt" \
    "kind=ship" "harness=codex"
  FM_FAKE_AXI_STATUS="$(run_ci_monitor_interrupted_status fm/feat-cximon2)"
  local out; out=$(run_crew_state "$d" feat-cximon2)
  assert_contains "$out" "state: needs-inspection" "ci_monitor_interrupted status -> needs-inspection"
  assert_not_contains "$out" "state: unknown" "the underscored spelling must not collapse to unknown"
  assert_not_contains "$out" "state: working" "a stopped monitor is not an active run"
  pass "ci_monitor_interrupted status reads as needs-inspection, never unknown"
}

# The coarse runs-ledger route carries the same status word for the same cause,
# so the third reader of this one condition must agree with the other two.
test_ci_monitor_interrupted_coarse_needs_inspection() {
  reset_fakes
  local d; d=$(new_case cimon-coarse)
  make_repo_on_branch "$d/wt" fm/feat-cximon3
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cximon3.meta" "window=fm:fm-feat-cximon3" "worktree=$d/wt" \
    "kind=ship" "harness=codex"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-branch)"
  FM_FAKE_RUNS_LIST="ci_monitor_interrupted fm/feat-cximon3 ${FM_FAKE_RUN_HEAD:0:8} 2026-09-09 01:30 https://github.com/o/r/pull/430"
  local out; out=$(run_crew_state "$d" feat-cximon3)
  assert_contains "$out" "state: needs-inspection" "coarse ci_monitor_interrupted -> needs-inspection"
  assert_not_contains "$out" "state: unknown" "the ledger route must not collapse to unknown either"
  pass "ci_monitor_interrupted from the runs ledger reads as needs-inspection"
}

# outcomeForRun's other qualified pass: publication or checks were skipped
# automatically, so the run completed without proving the change shipped and
# passed. It shares passed-with-override's rule - a human looks before merge.
test_passed_with_skips_needs_inspection() {
  reset_fakes
  local d; d=$(new_case passed-skips)
  make_repo_on_branch "$d/wt" fm/feat-skips
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-skips.meta" "window=fm:fm-feat-skips" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_with_skips fm/feat-skips)"
  local out; out=$(run_crew_state "$d" feat-skips)
  assert_contains "$out" "state: needs-inspection" "passed-with-skips -> needs-inspection"
  assert_not_contains "$out" "state: done" "an automatic skip must never read as done"
  assert_not_contains "$out" "state: unknown" "a recognized qualified pass is not unknown"
  pass "passed-with-skips reads as needs-inspection, never done"
}

# Closure case 4 of 4: one retained idle worker. A Codex crew with NO run that
# declared a bounded external wait is holding, not wedged. Before this fix the
# unverified pane verdict terminated the read and answered `unknown`, throwing
# away the crew's own declared reason; the pane cannot prove idleness, but it
# also must not MASK the one source that spoke.
test_codex_unverified_pane_falls_through_to_status_log() {
  reset_fakes
  local d; d=$(new_case codex-idle)
  make_repo_on_branch "$d/wt" fm/feat-cxidle
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cxidle.meta" "window=fm:fm-feat-cxidle" "worktree=$d/wt" \
    "kind=ship" "harness=codex"
  printf 'paused: holding a green PR for the drained validation window\n' \
    > "$d/state/feat-cxidle.status"
  local out; out=$(run_crew_state "$d" feat-cxidle)
  assert_contains "$out" "state: paused" "a declared wait is reported, not unknown"
  assert_contains "$out" "source: status-log" "the log is named as the source that answered"
  assert_contains "$out" "drained validation window" "the crew's own reason survives"
  assert_contains "$out" "codex-unverified" "the unreadable pane is still named, never hidden"
  assert_not_contains "$out" "state: unknown" "an unverified pane must not mask a real signal"
  pass "codex lane with no run reports its declared wait and still names the unread pane"
}

# The same fall-through must NOT invent a state when the log has nothing usable:
# with no run and no mappable log verb, the answer stays unknown and still names
# the unverified adapter as the reason.
test_codex_unverified_pane_with_no_log_stays_unknown() {
  reset_fakes
  local d; d=$(new_case codex-nolog)
  make_repo_on_branch "$d/wt" fm/feat-cxnolog
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cxnolog.meta" "window=fm:fm-feat-cxnolog" "worktree=$d/wt" \
    "kind=ship" "harness=codex"
  local out; out=$(run_crew_state "$d" feat-cxnolog)
  assert_contains "$out" "state: unknown" "no run and no log -> still unknown"
  assert_contains "$out" "source: pane" "the unreadable pane is the reported source"
  assert_contains "$out" "codex-unverified" "the unverified reason is named"
  pass "codex lane with no run and no usable log stays unknown, naming the pane"
}

# The fall-through is scoped to adapters with no verified semantic source AT
# ALL. A BROKEN record on a converted adapter is a wiring defect and must stay
# loud rather than quietly reading the log: fm-busy-lib.sh's contract is
# "malformed, stale, or untrusted records -> unknown, never a fallback".
test_broken_busy_record_still_masks_the_log() {
  reset_fakes
  local d; d=$(new_case broken-record)
  make_repo_on_branch "$d/wt" fm/feat-broken
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-broken.meta" "window=fm:fm-feat-broken" "worktree=$d/wt" \
    "kind=ship" "harness=claude"
  printf 'paused: holding for a window\n' > "$d/state/feat-broken.status"
  # A record with no armed gen: the incarnation cannot be bound, so the
  # classifier answers `unknown malformed` - this crew's own wiring is broken.
  printf 'v1 gen=deadbeef seq=1 state=idle source=claude-hook event=stop ts=1\n' \
    > "$d/state/feat-broken.busy-state"
  local out; out=$(run_crew_state "$d" feat-broken)
  assert_contains "$out" "state: unknown" "a broken busy record stays loud"
  assert_contains "$out" "source: pane" "the broken record is reported as the pane source"
  assert_not_contains "$out" "state: paused" "broken wiring must not be papered over by the log"
  pass "a broken busy record still masks the status log, unlike an unverified adapter"
}

# A converted adapter (claude here) is always armed with a seed record at
# spawn, so a genuinely MISSING record - never armed, or the sidecar lost -
# means the adapter's own wiring is broken, not that the crew is unreadable.
# That is a fact about the wiring rather than about the crew, so it must not
# mask a declared wait either: this is the direct regression for the
# 2026-09-09 finding where four live Claude lanes read unknown/missing and
# their paused: lines were lost, misreading a declared external wait as a
# wedge or an absent agent.
test_claude_missing_busy_record_falls_through_to_status_log() {
  reset_fakes
  local d; d=$(new_case claude-missing)
  make_repo_on_branch "$d/wt" fm/feat-clmissing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-clmissing.meta" "window=fm:fm-feat-clmissing" "worktree=$d/wt" \
    "kind=ship" "harness=claude"
  printf 'paused: holding for the install-window cutoff\n' \
    > "$d/state/feat-clmissing.status"
  # Deliberately no arm_idle_record: no busy-gen and no busy-state file at all,
  # so the classifier answers `unknown missing` rather than a canned verdict.
  local out; out=$(run_crew_state "$d" feat-clmissing)
  assert_contains "$out" "state: paused" "a declared wait is reported, not unknown"
  assert_contains "$out" "source: status-log" "the log is named as the source that answered"
  assert_contains "$out" "install-window cutoff" "the crew's own reason survives"
  assert_contains "$out" "missing" "the missing busy record is still named, never hidden"
  assert_not_contains "$out" "state: unknown" "a missing record must not mask a real signal"
  pass "claude lane with a missing busy record reports its declared wait and still names the gap"
}

# Codex's semantic busy gate itself. fm-spawn refuses to launch Codex busy
# wiring while this gate is shut (bin/fm-spawn.sh), and the classifier's
# `codex-unverified` verdict - which the fall-through above depends on being a
# by-design answer rather than a broken-wiring answer - is only correct while it
# stays shut. Opening it is a change that must land WITH the fm-spawn wiring and
# a refreshed record in docs/verification/supervision.md, never on its own.
test_codex_semantic_gate_is_closed() {
  ( . "$ROOT/bin/fm-busy-lib.sh"
    if fm_busy_codex_semantic_source; then
      fail "codex semantic busy gate is open without verified per-task wiring"
    fi
    if fm_busy_codex_appserver_observable; then
      fail "codex app-server turn lifecycle claims observability it has not proven"
    fi
    if fm_busy_codex_hooks_verified; then
      fail "codex lifecycle hooks claim verification they have not passed"
    fi
    if [ -n "$(fm_busy_sources_for_harness codex)" ]; then
      fail "codex trusts a semantic source while its gate is closed"
    fi
  ) || return 1
  pass "codex semantic busy gate stays closed, so codex-unverified is a by-design verdict"
}

# --- successor and integration-batch branch attribution ---------------------
# The run that belongs to a task is not always on the branch name checked out
# right now. bin/fm-pr-lib.sh's fm_pr_branch_matches_task is the ONE owner of
# the task's branch family, and bin/fm-pr-check.sh --absorbed-by is the ONE
# writer of the integration-batch binding; both are consumed here rather than
# re-derived. The head proof is unchanged in every case below.

# A crew that restarted a review round onto fm/<id>-r2 keeps one identity: the
# run on the successor branch is still this task's run.
test_successor_branch_run_is_attributed() {
  reset_fakes
  local d; d=$(new_case successor-branch)
  # The worktree still sits on the task's base branch while the pipeline's run
  # is on the -r2 successor, so exact branch equality does NOT match and only
  # the task's branch family can bind the run.
  make_repo_on_branch "$d/wt" fm/feat-succ
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-succ.meta" "window=fm:fm-feat-succ" "worktree=$d/wt" \
    "kind=ship" "harness=codex"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-succ-r2)"
  local out; out=$(run_crew_state "$d" feat-succ)
  assert_contains "$out" "state: working" "the -r2 successor run is this task's run"
  assert_contains "$out" "source: run-step" "successor attribution uses the run record"
  pass "a run on the -rN successor branch is attributed to its task"
}

# The integration-batch binding fm-pr-check.sh --absorbed-by records is read as
# written: the combined branch that will actually land this constituent is this
# task's branch for attribution.
test_batch_constituent_branch_run_is_attributed() {
  reset_fakes
  local d; d=$(new_case batch-branch)
  make_repo_on_branch "$d/wt" fm/feat-batch
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-batch.meta" "window=fm:fm-feat-batch" "worktree=$d/wt" \
    "kind=ship" "harness=codex" "batch_role=constituent" \
    "batch_constituent_branch=fm/combined-batch-1"
  FM_FAKE_AXI_STATUS="$(run_running fm/combined-batch-1)"
  local out; out=$(run_crew_state "$d" feat-batch)
  assert_contains "$out" "state: working" "the combined batch run is this constituent's run"
  assert_contains "$out" "source: run-step" "batch attribution uses the run record"
  pass "a run on the recorded integration-batch branch is attributed to its constituent"
}

# The widened branch predicate must not become branch-name coincidence: an
# unrelated branch is still not this task's run, so another crew's validation is
# never reported as this one's.
test_unrelated_branch_run_is_not_attributed() {
  reset_fakes
  local d; d=$(new_case unrelated-branch)
  make_repo_on_branch "$d/wt" fm/feat-mine
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-mine.meta" "window=fm:fm-feat-mine" "worktree=$d/wt" \
    "kind=ship" "harness=codex"
  printf 'paused: holding for a window\n' > "$d/state/feat-mine.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/someone-elses-work)"
  local out; out=$(run_crew_state "$d" feat-mine)
  assert_not_contains "$out" "source: run-step" "another crew's run is never attributed here"
  assert_contains "$out" "state: paused" "this crew falls back to its own declared wait"
  pass "an unrelated branch's run is still not attributed after the predicate widened"
}

# A batch binding must not be honoured unless the task record actually declares
# the constituent role, so a stale or partial field cannot bind a foreign run.
test_batch_branch_without_constituent_role_is_not_attributed() {
  reset_fakes
  local d; d=$(new_case batch-norole)
  make_repo_on_branch "$d/wt" fm/feat-norole
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-norole.meta" "window=fm:fm-feat-norole" "worktree=$d/wt" \
    "kind=ship" "harness=codex" "batch_constituent_branch=fm/combined-batch-9"
  printf 'paused: holding for a window\n' > "$d/state/feat-norole.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/combined-batch-9)"
  local out; out=$(run_crew_state "$d" feat-norole)
  assert_not_contains "$out" "source: run-step" "no constituent role means no batch attribution"
  assert_contains "$out" "state: paused" "the crew falls back to its own declared wait"
  pass "a batch branch without batch_role=constituent is not attributed"
}

test_active_run_is_authoritative
test_stale_needs_decision_superseded
test_stale_blocked_superseded

# --- parked lanes (deliverable B) -------------------------------------------

# Proves: a lane whose agent firstmate deliberately stopped reports parked-exit
# from its own durable record, NOT `unknown`. Before the parked marker existed,
# such a lane read unknown/none - its terminal is alive but holds no agent, and
# its last status line is whatever the worker wrote before exiting - which reads
# as "something is wrong here" about a lane that is exactly where firstmate put
# it. Red before the change (no parked branch existed), green after.
test_a_parked_lane_reports_parked_exit_not_unknown() {
  reset_fakes
  local d; d=$(new_case parked-exit)
  make_repo_on_branch "$d/wt" fm/feat-pk
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pk.meta" "window=fm:fm-feat-pk" "worktree=$d/wt" "kind=ship" \
    "parked=$(( $(date +%s) - 90 ))" "parked_reason=resting while the fleet is over capacity"
  # The real shape: the worker exited without writing a terminal status line.
  printf 'working: mid-refactor\n' > "$d/state/feat-pk.status"
  local out; out=$(run_crew_state "$d" feat-pk)
  assert_contains "$out" "state: parked-exit" "a parked lane should report parked-exit"
  assert_contains "$out" "source: task-record" "a parked lane is answered from the durable record"
  assert_contains "$out" "relaunch to resume" "the report should name the action that resumes it"
  assert_contains "$out" "resting while the fleet is over capacity" "the parked reason should be carried"
  assert_not_contains "$out" "state: unknown" "a parked lane must not read as unknown"
  pass "fm-crew-state: a parked lane reports parked-exit from its durable record"
}

# Proves the two tokens stay distinct. `parked` means a no-mistakes run waiting
# at a gate with findings for a human; `parked-exit` means a stopped agent with
# no gate and nothing to answer. bin/fm-classify-lib.sh's crew_absorb_class
# compares the token directly, so collapsing them would tell every consumer
# something false.
test_gate_parked_and_parked_exit_are_different_states() {
  reset_fakes
  local d; d=$(new_case parked-token-split)
  make_repo_on_branch "$d/wt" fm/feat-pt
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pt.meta" "window=fm:fm-feat-pt" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-pt)"
  local out; out=$(run_crew_state "$d" feat-pt)
  assert_contains "$out" "state: parked" "a gate-parked run should still report parked"
  assert_not_contains "$out" "parked-exit" "a gate-parked run must not report parked-exit"
  assert_contains "$out" "source: run-step" "a gate-parked run is still answered from the run step"
  pass "fm-crew-state: a gate-parked run and a parked lane are different states"
}

# Proves the marker is authoritative over a live pane: a parked lane's terminal
# is deliberately preserved, so a busy-looking pane must not override the record.
test_the_parked_record_wins_over_the_preserved_terminal() {
  reset_fakes
  local d; d=$(new_case parked-over-pane)
  make_repo_on_branch "$d/wt" fm/feat-po
  make_fakebin "$d" >/dev/null
  FM_FAKE_BUSY=1
  fm_write_meta "$d/state/feat-po.meta" "window=fm:fm-feat-po" "worktree=$d/wt" "kind=ship" \
    "parked=$(( $(date +%s) - 10 ))"
  local out; out=$(run_crew_state "$d" feat-po)
  assert_contains "$out" "state: parked-exit" "the durable record should win over the preserved terminal"
  pass "fm-crew-state: the parked record wins over a preserved terminal"
}

# Failure-capable merge regressions for the two no-mistakes reconciliation
# rules restored from upstream: live runs beat terminal corpses, while a
# failed run is reclassified only when CI is its sole failed step and the
# latest CI marker is green.
run_failed_ci_orphan() {  # <branch> [also-fail-lint]
  local lint_status=completed
  [ "${2:-}" = also-fail-lint ] && lint_status=failed
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: failed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/203"
  findings: none
outcome: failed
steps[4]{step,status,findings,duration_ms}:
  review,completed,0,0
  test,completed,0,0
  lint,$lint_status,0,0
  ci,failed,0,76127890
EOF
}

test_terminal_corpse_loses_to_live_run_on_same_branch() {
  reset_fakes
  local d base live short_base short_live out
  d=$(new_case live-beats-corpse)
  make_repo_on_branch "$d/wt" fm/feat-corpse
  base=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'live run advanced the tip'
  live=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" reset -q --hard "$base"
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base")
  short_live=$(git -C "$d/wt" rev-parse --short=7 "$live")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/corpse.meta" "window=fm:fm-corpse" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD=$base
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-corpse)"
  FM_FAKE_RUNS_LIST="  failed fm/feat-corpse $short_base 2026-08-05 11:20
  running fm/feat-corpse $short_live 2026-08-05 10:05"
  out=$(run_crew_state "$d" corpse)
  assert_contains "$out" 'state: working' 'live successor must outrank terminal corpse'
  assert_not_contains "$out" 'state: failed' 'terminal corpse must not mask a live successor'
  pass 'a live no-mistakes successor outranks a terminal corpse on the same branch'
}

test_unfetched_live_sibling_outranks_exact_terminal_anchor() {
  reset_fakes
  local d base short_base out
  d=$(new_case unfetched-live-sibling)
  make_repo_on_branch "$d/wt" fm/feat-unfetched
  base=$(git -C "$d/wt" rev-parse HEAD)
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unfetched.meta" "window=fm:fm-unfetched" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD=$base
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-unfetched)"
  FM_FAKE_RUNS_LIST="  failed fm/feat-unfetched $short_base 2026-08-05 11:20
  running fm/feat-unfetched 0123abc 2026-08-05 10:05"
  out=$(run_crew_state "$d" unfetched)
  assert_contains "$out" 'state: working' 'exact terminal anchor should bind its unfetched live sibling'
  assert_not_contains "$out" 'state: failed' 'unfetched live sibling must outrank the anchor corpse'
  pass 'an exact terminal anchor safely binds an unfetched live sibling'
}

test_terminal_only_rows_keep_newest_precedence() {
  reset_fakes
  local d base short_base out
  d=$(new_case terminal-only-order)
  make_repo_on_branch "$d/wt" fm/feat-terminal-order
  base=$(git -C "$d/wt" rev-parse HEAD)
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/terminal-order.meta" "window=fm:fm-terminal-order" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="  cancelled fm/feat-terminal-order $short_base 2026-08-05 11:20
  completed fm/feat-terminal-order $short_base 2026-08-05 10:05"
  out=$(run_crew_state "$d" terminal-order)
  assert_contains "$out" 'state: failed' 'newest terminal row must retain precedence'
  assert_contains "$out" 'run cancelled' 'newer cancellation must beat older completion'
  pass 'terminal-only run rows retain newest-first precedence'
}

test_green_orphaned_ci_monitor_reads_held_done() {
  reset_fakes
  local d out
  d=$(new_case green-orphaned-ci)
  make_repo_on_branch "$d/wt" fm/feat-green-orphan
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/green-orphan.meta" "window=fm:fm-green-orphan" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_ci_orphan fm/feat-green-orphan)"
  FM_FAKE_CI_LOGS='all CI checks passed - still monitoring until merged or closed'
  out=$(run_crew_state "$d" green-orphan)
  assert_contains "$out" 'state: done' 'green orphaned CI monitor should read held for merge'
  assert_contains "$out" 'PR held for merge' 'detail must distinguish held green from merged'
  assert_not_contains "$out" 'state: failed' 'monitor death is not work failure'
  pass 'a sole failed CI monitor after green reads done and held for merge'
}

test_second_failed_step_prevents_green_reclassification() {
  reset_fakes
  local d out
  d=$(new_case green-ci-second-failure)
  make_repo_on_branch "$d/wt" fm/feat-two-failures
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/two-failures.meta" "window=fm:fm-two-failures" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_ci_orphan fm/feat-two-failures also-fail-lint)"
  FM_FAKE_CI_LOGS='all CI checks passed - still monitoring until merged or closed'
  out=$(run_crew_state "$d" two-failures)
  assert_contains "$out" 'state: failed' 'a substantive failed step must keep failure'
  assert_not_contains "$out" 'state: done' 'green CI cannot erase another failed step'
  pass 'a second failed step prevents orphaned-CI reclassification'
}

test_coarse_failed_ledger_is_unknown_only_while_daemon_down() {
  reset_fakes
  local d short out
  d=$(new_case coarse-daemon-down)
  make_repo_on_branch "$d/wt" fm/feat-coarse-down
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/coarse-down.meta" "window=fm:fm-coarse-down" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="  failed fm/feat-coarse-down $short 2026-09-05 21:00"
  FM_FAKE_DAEMON_DOWN=1
  out=$(run_crew_state "$d" coarse-down)
  assert_contains "$out" 'state: unknown' 'dead instrument makes coarse failure unverified'
  assert_contains "$out" 'daemon unreachable' 'unknown detail must name the failed instrument'
  FM_FAKE_DAEMON_DOWN=0
  out=$(run_crew_state "$d" coarse-down)
  assert_contains "$out" 'state: failed' 'same coarse failure remains failed while daemon is healthy'
  pass 'coarse failed ledger is unknown only when the daemon is provably down'
}

test_terminal_corpse_loses_to_live_run_on_same_branch
test_unfetched_live_sibling_outranks_exact_terminal_anchor
test_terminal_only_rows_keep_newest_precedence
test_green_orphaned_ci_monitor_reads_held_done
test_second_failed_step_prevents_green_reclassification
test_coarse_failed_ledger_is_unknown_only_while_daemon_down

test_genuine_parked_not_superseded
test_scalar_gate_parked_not_superseded
test_gate_block_parked_not_superseded
test_a_parked_lane_reports_parked_exit_not_unknown
test_gate_parked_and_parked_exit_are_different_states
test_the_parked_record_wins_over_the_preserved_terminal
test_ci_ready_done_log_beats_monitoring_run
test_ci_monitoring_checks_green_surfaces_done
test_top_level_ci_checks_green_surfaces_done
test_ci_monitoring_no_checks_terminal_surfaces_done
test_ci_monitoring_green_then_rearm_stays_working
test_ci_monitoring_no_checks_yet_stays_working
test_ci_monitoring_still_waiting_stays_working
test_ci_monitoring_green_then_new_issue_stays_working
test_ci_ready_done_log_relapse_stays_working
test_ci_fixing_after_green_stays_working
test_top_level_fixing_ci_running_after_green_stays_working
test_top_level_fixing_done_log_stays_working
test_terminal_passed
test_terminal_failed
test_cancelled_outcome_then_latest_declared_pause_reads_paused
test_cancelled_status_then_latest_open_green_done_pr_reads_paused
test_cancelled_done_pr_at_a_different_live_head_stays_failed
test_cancelled_done_pr_with_a_non_green_check_stays_failed
test_coarse_cancelled_with_no_later_declaration_stays_failed_with_detail
test_pause_before_cancelled_outcome_does_not_suppress_failure
test_failed_outcome_with_later_declared_pause_remains_failed
test_terminal_passed_with_override
test_terminal_unrecognized_outcome
test_cross_branch_attribution_via_runs_list
test_cross_branch_attribution_picks_most_recent_row
test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status
test_other_branch_run_ignored
test_no_run_busy_pane
test_no_run_footer_text_alone_is_not_working
test_no_run_grok_uses_isolated_fallback
test_no_run_herdr_unknown_uses_backend_capture
test_no_run_herdr_idle_agent_status_outranked_by_record
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle
test_no_run_idle_pane_uses_log
test_no_run_idle_pane_uses_keyed_log
test_no_run_idle_pane_paused
test_no_run_idle_pane_custom_paused_verb
test_no_run_idle_secondmate_resolved_event_not_state
test_dead_window_ignores_stale_status_log
test_dead_window_still_reports_terminal_run_step
test_dead_window_still_reports_active_run_step
test_no_timeout_uses_perl_bound
test_scout_skips_run_lookup
test_torn_down_worktree
test_remote_alive_with_log_uses_status_log
test_remote_alive_idle_is_healthy_not_gone
test_remote_unreachable_is_unknown_remote_not_dead
test_remote_dead_reports_remote_verdict
test_missing_meta
test_provably_working_via_runs_list_fallback
test_not_provably_working_when_stopped
test_not_provably_working_when_passed_with_override
test_usage_error
test_historical_same_branch_rewritten_head_not_current
test_active_run_descendant_fix_head_remains_current
test_local_advanced_past_run_head_invalidates
test_pipeline_owned_active_run_beats_superseded_failed_row
test_failed_run_with_no_later_run_still_surfaces
test_coarse_unresolvable_active_row_never_falls_to_older_row
test_coarse_mismatched_anchor_falls_to_pane_not_older_row
test_non_pipeline_owned_unresolvable_head_not_attributed
test_pipeline_owned_terminal_run_not_exempt
test_missing_run_head_falls_back_to_current_state
test_active_fix_round_unfetched_pipeline_head_reports_current
test_unanchored_unfetched_active_row_does_not_match
test_unresolved_terminal_row_is_history_not_current
test_runs_list_continuation_found_when_axi_answers_other_branch

test_codex_running_step_beats_unverified_pane
test_codex_parked_gate_beats_unverified_pane
test_ci_monitor_interrupted_outcome_needs_inspection
test_ci_monitor_interrupted_status_needs_inspection
test_ci_monitor_interrupted_coarse_needs_inspection
test_passed_with_skips_needs_inspection
test_codex_unverified_pane_falls_through_to_status_log
test_codex_unverified_pane_with_no_log_stays_unknown
test_broken_busy_record_still_masks_the_log
test_claude_missing_busy_record_falls_through_to_status_log
test_codex_semantic_gate_is_closed
test_successor_branch_run_is_attributed
test_batch_constituent_branch_run_is_attributed
test_unrelated_branch_run_is_not_attributed
test_batch_branch_without_constituent_role_is_not_attributed

echo "all fm-crew-state tests passed"
