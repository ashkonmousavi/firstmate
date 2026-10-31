#!/usr/bin/env bash
# fm-lane-release.sh: free the seat of a finished-and-landed worker.
#
# Every case drives the executable (sweep, --audit, arm) against a hermetic home.
# Stubs stand in for crew state, the captain-hold gate, the live endpoint reads
# (FM_LANE_RELEASE_PROBE), and fm-control; the status log, merge record,
# steering inbox, busy record, marker, and ledger are real files.
#
# Test names map to the rows they prove:
#   edge_*  data/kun-adopt/edge-cases.md, A1 list (one per row)
#   stop_*  prep.md "Why a worker stops" table, plus the stuck-composer row
#   extra_* the extra cases revision3.md lists under Tests
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LR="$ROOT/bin/fm-lane-release.sh"
TMP_ROOT=$(fm_test_tmproot fm-lane-release)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT

STUBS="$TMP_ROOT/stubs"
mkdir -p "$STUBS"

# Crew state: state/<id> answer from $FM_T/<id>.crew, default done.
cat > "$STUBS/crew-state" <<'SH'
#!/usr/bin/env bash
s=$(cat "$FM_T/$1.crew" 2>/dev/null || printf done)
printf 'state: %s · source: fake · stub\n' "$s"
SH
# Endpoint reads: $FM_T/<id>.<what>, with live-idle-empty defaults.
cat > "$STUBS/probe" <<'SH'
#!/usr/bin/env bash
what=$1 id=$2
if [ -e "$FM_T/$id.turn-on-$what" ]; then
  rm "$FM_T/$id.turn-on-$what"
  "$FM_TEST_BUSY_EVENT" apply "$FM_HOME/state" "$id" busy --current-gen --source claude-hook --event user-prompt-submit || exit 1
  "$FM_TEST_BUSY_EVENT" apply "$FM_HOME/state" "$id" idle --current-gen --source claude-hook --event stop || exit 1
fi
[ ! -e "$FM_T/$id.$what-hangs" ] || sleep 30
if [ -f "$FM_T/$id.$what" ]; then cat "$FM_T/$id.$what"; exit 0; fi
case "$what" in
  agent) printf 'alive\n' ;;
  busy) printf 'idle claude-hook\n' ;;
  composer) printf 'empty\n' ;;
  doorbell) printf 'no\n' ;;
  seat) printf 'yes\n' ;;
esac
SH
# Captain-hold gate: open exits $FM_T/<id>.held (default 1, not held); verify
# exits $FM_T/<id>.verify (default 0, gate passed).
cat > "$STUBS/hold" <<'SH'
#!/usr/bin/env bash
[ ! -e "$FM_T/$2.hold-hangs" ] || sleep 30
case "$1" in
  open) exit "$(cat "$FM_T/$2.held" 2>/dev/null || printf 1)" ;;
  verify) exit "$(cat "$FM_T/$2.verify" 2>/dev/null || printf 0)" ;;
esac
exit 2
SH
# Control: logs its argv and whether the marker was already written, exits
# $FM_T/<id>.control-rc (default 0); a stop makes the agent dead and the seat
# free unless $FM_T/<id>.keep-seat exists.
cat > "$STUBS/control" <<'SH'
#!/usr/bin/env bash
id=$1
marker="$FM_HOME/state/$id.released"
m=absent
[ -f "$marker" ] && m=$(sed -n 's/^result=//p' "$marker")
printf '%s marker=%s\n' "$*" "$m" >> "$FM_T/control.log"
rc=$(cat "$FM_T/$id.control-rc" 2>/dev/null || printf 0)
if [ "$rc" = 0 ]; then
  printf 'dead\n' > "$FM_T/$id.agent"
  [ -e "$FM_T/$id.keep-seat" ] || printf 'no\n' > "$FM_T/$id.seat"
  printf 'stopped %s\n' "$id"
fi
exit "$rc"
SH
cat > "$STUBS/gh" <<'SH'
#!/usr/bin/env bash
state=$(cat "$FM_T/pr-state" 2>/dev/null || echo open)
[ "$state" != hang ] || sleep 30
[ "$state" != failure ] || exit 1
merged=false
[ "$state" != merged ] || merged=true
case "$state" in open) state=OPEN ;; closed) state=CLOSED ;; merged) state=MERGED ;; esac
printf 'state=%s\nmerged=%s\n' "$state" "$merged"
SH
cat > "$STUBS/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$STUBS/glab" <<'SH'
#!/usr/bin/env bash
state=$(cat "$FM_T/pr-state" 2>/dev/null || echo open)
[ "$state" != open ] || state=opened
printf '{"state":"%s"}\n' "$state"
SH
cat > "$STUBS/tea" <<'SH'
#!/usr/bin/env bash
if [ "$1" = login ]; then
  printf '[{"name":"test","url":"https://forge.example.org"}]\n'
  exit 0
fi
state=$(cat "$FM_T/pr-state" 2>/dev/null || echo open)
merged=false
if [ "$state" = merged ]; then state=closed; merged=true; fi
printf '{"state":"%s","merged":%s,"head":{"sha":"aabbcc"}}\n' "$state" "$merged"
SH
cat > "$STUBS/gerrit-axi" <<'SH'
#!/usr/bin/env bash
state=$(cat "$FM_T/pr-state" 2>/dev/null || echo open)
case "$state" in open) state=NEW ;; closed) state=ABANDONED ;; merged) state=MERGED ;; esac
printf '{"ok":true,"changes":[{"change":7,"status":"%s"}]}\n' "$state"
SH
chmod +x "$STUBS"/*

set_mtime() {  # <epoch> <path>
  touch -d "@$1" "$2" 2>/dev/null || touch -t "$(date -r "$1" +%Y%m%d%H%M.%S)" "$2"
}

# new_case <name> [setting]: echoes the case dir (home/ and t/ stub data).
new_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/t"
  : > "$dir/t/control.log"
  [ "${2-on}" = absent ] || printf '%s\n' "${2-on}" > "$dir/home/config/lane-release"
  printf '%s\n' "$dir"
}

# add_task <dir> <id> <kind> [mode]: a meta, a worktree holding an uncommitted
# file, spawn_gen launched at epoch 1000, and (ship) a recorded PR.
add_task() {
  local dir=$1 id=$2 kind=$3 mode=${4-no-mistakes} wt="$1/wt-$2"
  mkdir -p "$wt"
  printf 'uncommitted\n' > "$wt/work.txt"
  {
    echo "window=sess:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "harness=claude"
    echo "kind=$kind"
    echo "spawn_gen=s1000.1.1"
    if [ "$kind" = ship ]; then
      echo "mode=$mode"
      echo "pr=https://github.com/o/r/pull/7"
    fi
  } > "$dir/home/state/$id.meta"
  printf 'gfixture\n' > "$dir/home/state/$id.busy-gen"
  printf 'v1 gen=gfixture seq=7 state=idle source=claude-hook event=stop ts=1900\n' > "$dir/home/state/$id.busy-state"
  if [ "$kind" = scout ]; then
    mkdir -p "$dir/home/data/$id"
    printf '# report\n' > "$dir/home/data/$id/report.md"
  fi
}

status_lines() {  # <dir> <id> <line>...
  local dir=$1 id=$2
  shift 2
  printf '%s\n' "$@" > "$dir/home/state/$id.status"
}

# merged <dir> <id> <epoch>: the merge record fm-pr-merge.sh and the merge poll
# write, confirmed at <epoch>.
merged() {
  local dir=$1 id=$2
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-pr-lib.sh"
    fm_pr_poll_merge_mark_notified "$dir/home/state" "$id" github github.com o/r 7
  ) || fail "could not write the merge record"
  set_mtime "$3" "$dir/home/state/$id.pr-poll-merge-notified"
}

# A finished merged ship: done at 2000, merged at 2100 (anchor 2100).
finished_ship() {  # <dir> <id>
  add_task "$1" "$2" ship
  status_lines "$1" "$2" 'done [at=2000]: PR https://github.com/o/r/pull/7 checks green'
  merged "$1" "$2" 2100
}

# A finished scout: report present, done at 2000, gate passed.
finished_scout() {  # <dir> <id>
  add_task "$1" "$2" scout
  status_lines "$1" "$2" 'done [at=2000]: report ready'
}

stub() {  # <dir> <id> <what> <value>
  printf '%s\n' "$4" > "$1/t/$2.$3"
}

run_lr() {  # <dir> <now> <args...>
  local dir=$1 now=$2
  shift 2
  env PATH="$STUBS:$PATH" FM_HOME="$dir/home" FM_T="$dir/t" FM_LANE_RELEASE_NOW="$now" FM_TEST_BUSY_EVENT="$ROOT/bin/fm-busy-event.sh" \
    FM_LANE_RELEASE_PROBE="$STUBS/probe" FM_LANE_RELEASE_CREW_STATE="$STUBS/crew-state" \
    FM_LANE_RELEASE_CAPTAIN_HOLD="$STUBS/hold" FM_LANE_RELEASE_CONTROL="$STUBS/control" \
    "${FM_LANE_RELEASE_RUNNER:-$LR}" "$@"
}

wait_exit_log() {  # <dir> <id>
  local i=0
  until grep -q '^rc=' "$1/home/state/$2.release.log" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 200 ] || fail "the detached exit for $2 never finished"
    sleep 0.05
  done
}

# cycle <dir> [ids...]: candidate sweep, release sweep, then (for each id that
# started a release) wait for the detached exit and verify on a third sweep.
cycle() {
  local dir=$1 id
  shift
  run_lr "$dir" 2500 sweep > "$dir/sweep1.out"
  run_lr "$dir" 2900 sweep > "$dir/sweep2.out"
  for id in "$@"; do
    [ -f "$dir/home/state/$id.released" ] && wait_exit_log "$dir" "$id"
  done
  run_lr "$dir" 2950 sweep > "$dir/sweep3.out"
}

control_calls() {  # <dir>
  wc -l < "$1/t/control.log" | tr -d ' '
}

assert_released() {  # <dir> <id> <class>
  local dir=$1 id=$2 class=$3
  grep -q "^$id exit --if-idle --expect-spawn-gen s1000.1.1 marker=releasing$" "$dir/t/control.log" \
    || fail "$id was not stopped through the unattended exit after its marker: $(cat "$dir/t/control.log")"
  grep -qx 'result=released' "$dir/home/state/$id.released" \
    || fail "$id's marker does not read released: $(cat "$dir/home/state/$id.released" 2>/dev/null)"
  grep -q "^RELEASED	task=$id	.*	class=$class	.*	verified=yes" "$dir/home/data/lane-release.ledger" \
    || fail "$id has no verified RELEASED ledger row: $(cat "$dir/home/data/lane-release.ledger" 2>/dev/null)"
}

assert_kept() {  # <dir> <id> <reason>
  local dir=$1 id=$2 reason=$3
  grep -q "^$id " "$dir/t/control.log" && fail "$id was stopped although it should keep its seat: $(cat "$dir/t/control.log")"
  [ ! -e "$dir/home/state/$id.released" ] || fail "$id carries a release marker although it was kept"
  grep -q "^$reason [0-9]" "$dir/home/state/lane-release.counters" 2>/dev/null \
    || fail "$id was not kept for '$reason': $(cat "$dir/home/state/lane-release.counters" 2>/dev/null)"
}

# --- edge-cases.md A1 ---------------------------------------------------------

edge_trigger_is_a_confirmed_done_never_an_exited_or_quiet_pane() {
  local dir
  dir=$(new_case edge-trigger)
  finished_scout "$dir" quiet
  stub "$dir" quiet crew unknown
  finished_scout "$dir" exited
  stub "$dir" exited agent dead
  cycle "$dir"
  assert_kept "$dir" quiet crew-state-unknown
  assert_kept "$dir" exited agent-not-live
  pass "A1 trigger: a quiet pane without a confirmed done, and an exited agent, are never released"
}

edge_stopped_but_not_done_never_frees() {
  local dir id
  dir=$(new_case edge-stopped)
  for id in q ask wait blk dialog compact crash quota typed; do finished_scout "$dir" "$id"; done
  status_lines "$dir" q 'needs-decision [at=1990]: which API?' 'done [at=2000]: report ready'
  status_lines "$dir" ask 'needs-decision [at=1990] [key=nm-r1-review]: ask-user findings=f1' 'done [at=2000]: report ready'
  stub "$dir" wait crew paused
  status_lines "$dir" blk 'blocked [at=1990]: daemon socket refused' 'done [at=2000]: report ready'
  stub "$dir" dialog busy 'unknown launch-prompt'
  stub "$dir" compact busy 'busy claude-hook'
  stub "$dir" crash agent dead
  status_lines "$dir" quota 'working [at=1990]: halfway'
  stub "$dir" typed composer pending
  cycle "$dir"
  assert_kept "$dir" q open-decision
  assert_kept "$dir" ask open-decision
  assert_kept "$dir" wait crew-state-paused
  assert_kept "$dir" blk open-decision
  assert_kept "$dir" dialog busy-unreadable
  assert_kept "$dir" compact busy-busy
  assert_kept "$dir" crash agent-not-live
  assert_kept "$dir" quota no-done
  assert_kept "$dir" typed pending-composer
  [ "$(control_calls "$dir")" = 0 ] || fail "a stopped-but-not-done worker was stopped"
  pass "A1 stopped-not-done: question, ask-user, wait, blocker, dialog, compaction, crash, quota, typed reply all keep the seat"
}

edge_done_is_not_landed_the_action_is_exit_only() {
  local dir
  dir=$(new_case edge-exit-only)
  finished_ship "$dir" s1
  cycle "$dir" s1
  assert_released "$dir" s1 merged-ship
  [ "$(control_calls "$dir")" = 1 ] || fail "the release did more than one control action"
  [ -f "$dir/home/state/s1.meta" ] || fail "the release removed the task record"
  [ -f "$dir/wt-s1/work.txt" ] || fail "the release touched the local copy"
  [ -f "$dir/home/state/s1.status" ] || fail "the release removed the status log"
  pass "A1 done-not-landed: the only action is the unattended exit; record, log, and copy stay"
}

edge_worker_needed_again_relaunch_clears_the_marker() {
  local dir
  dir=$(new_case edge-relaunch)
  finished_ship "$dir" s1
  cycle "$dir" s1
  assert_released "$dir" s1 merged-ship
  sed -i.bak 's/^spawn_gen=.*/spawn_gen=s3000.9.9/' "$dir/home/state/s1.meta"
  stub "$dir" s1 agent alive
  stub "$dir" s1 seat yes
  run_lr "$dir" 3100 sweep >/dev/null
  [ ! -e "$dir/home/state/s1.released" ] || fail "a relaunch did not clear the stale marker"
  grep -q '^merged-before-launch [0-9]' "$dir/home/state/lane-release.counters" \
    || fail "the relaunched worker was not kept: $(cat "$dir/home/state/lane-release.counters")"
  [ "$(control_calls "$dir")" = 1 ] || fail "the relaunched worker was stopped again"
  pass "A1 needed again: a relaunch makes the marker stale, it is removed, and the new worker keeps its seat"
}

edge_a_seat_is_not_a_copy() {
  local dir
  dir=$(new_case edge-seat-copy)
  finished_scout "$dir" sc
  cycle "$dir" sc
  assert_released "$dir" sc scout
  [ -d "$dir/wt-sc" ] && [ -f "$dir/wt-sc/work.txt" ] || fail "freeing the seat freed the copy"
  [ -f "$dir/home/data/sc/report.md" ] || fail "freeing the seat removed the scout report"
  pass "A1 seat-not-copy: the seat is freed while the copy and report stay"
}

edge_auto_start_is_out_of_scope() {
  local dir before
  dir=$(new_case edge-no-start)
  finished_ship "$dir" s1
  printf '## Queued\n- [ ] next - Next item (repo: alpha) (kind: ship)\n' > "$dir/home/data/backlog.md"
  before=$(cat "$dir/home/data/backlog.md")
  cycle "$dir" s1
  assert_released "$dir" s1 merged-ship
  [ "$(cat "$dir/home/data/backlog.md")" = "$before" ] || fail "the release changed the backlog"
  [ "$(cut -d' ' -f2 "$dir/t/control.log" | sort -u)" = exit ] || fail "the release did something other than exit"
  pass "A1 auto-start: a release starts nothing and leaves the queue alone"
}

edge_same_worker_or_fresh_continuations_keep_the_seat() {
  local dir
  dir=$(new_case edge-continuation)
  add_task "$dir" openpr ship
  status_lines "$dir" openpr 'done [at=2000]: PR https://github.com/o/r/pull/7 checks green'
  finished_ship "$dir" steered
  mkdir -p "$dir/home/state/steered.inbox"
  printf 'from=firstmate\n--\nmerge base in\n' > "$dir/home/state/steered.inbox/1.msg"
  cycle "$dir"
  assert_kept "$dir" openpr kept-open-pr
  assert_kept "$dir" steered unread-steer
  pass "A1 same worker: an open PR and an unread steer keep the worker that has the context"
}

edge_per_home_only() {
  local a b
  a=$(new_case edge-home-a)
  b=$(new_case edge-home-b)
  finished_ship "$a" s1
  finished_ship "$b" s2
  cycle "$a" s1
  assert_released "$a" s1 merged-ship
  [ ! -e "$b/home/state/s2.release-candidate" ] && [ ! -e "$b/home/state/s2.released" ] \
    || fail "a sweep of one home touched another home"
  [ "$(control_calls "$b")" = 0 ] || fail "a sweep of one home stopped another home's worker"
  pass "A1 per home: a sweep acts only on its own home"
}

edge_harness_agnostic_refusal_keeps_the_seat() {
  local dir
  dir=$(new_case edge-refusal)
  finished_ship "$dir" s1
  stub "$dir" s1 control-rc 1
  cycle "$dir" s1
  [ ! -e "$dir/home/state/s1.released" ] || fail "a refused exit left a release marker"
  grep -q '^exit-refused 1' "$dir/home/state/lane-release.counters" || fail "a refused exit was not counted"
  grep -q '^RELEASED' "$dir/home/data/lane-release.ledger" 2>/dev/null && fail "a refused exit was ledgered as released"
  pass "A1 harness-agnostic: a control refusal (unverified harness, dialog, composer) keeps the seat"
}

edge_remote_and_unreachable_are_unknown_never_free() {
  local dir out rc
  dir=$(new_case edge-unreachable)
  finished_ship "$dir" s1
  stub "$dir" s1 agent unreadable
  add_task "$dir" mate ship
  printf 'remote_host=q-crew\n' >> "$dir/home/state/mate.meta"
  out=$(run_lr "$dir" 9000 --audit); rc=$?
  expect_code 2 "$rc" "an unreadable endpoint must make the audit unknown"$'\n'"$out"
  assert_contains "$out" "unknown s1 (endpoint-unreadable" "the audit should name the unknown worker"
  assert_not_contains "$out" "mate" "a remote record is not read as local"
  cycle "$dir"
  assert_kept "$dir" s1 endpoint-unreadable
  pass "A1 remote: an unreachable endpoint is unknown in the audit and never released"
}

# --- prep.md stop-reason table -----------------------------------------------

stop_finished_done_is_released() {
  local dir
  dir=$(new_case stop-finished)
  finished_ship "$dir" s1
  cycle "$dir" s1
  assert_released "$dir" s1 merged-ship
  [ ! -s "$dir/sweep3.out" ] || fail "a successful release printed a wake: $(cat "$dir/sweep3.out")"
  pass "stop row finished: a done, merged, idle ship is released silently"
}

stop_needs_decision_keeps() {
  local dir
  dir=$(new_case stop-nd)
  finished_scout "$dir" sc
  status_lines "$dir" sc 'needs-decision [at=1990]: pick a shape' 'done [at=2000]: report ready'
  cycle "$dir"
  assert_kept "$dir" sc open-decision
  pass "stop row needs-decision: a question a later done hides still keeps the seat"
}

stop_ask_user_finding_keeps() {
  local dir
  dir=$(new_case stop-ask)
  finished_ship "$dir" s1
  stub "$dir" s1 crew parked
  cycle "$dir"
  assert_kept "$dir" s1 crew-state-parked
  pass "stop row ask-user: a run parked at a gate keeps the seat"
}

stop_question_only_in_chat_keeps() {
  local dir gen
  dir=$(new_case stop-chat)
  finished_scout "$dir" sc
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" sc)
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/home/state" sc idle --gen "$gen" \
    --source claude-hook --event stop >/dev/null
  cycle "$dir"
  assert_kept "$dir" sc turn-since
  pass "stop row chat question: a turn that ended long after the done line keeps the seat"
}

stop_declared_paused_keeps() {
  local dir
  dir=$(new_case stop-paused)
  add_task "$dir" s1 ship
  status_lines "$dir" s1 'paused [at=1900]: waiting on CI'
  merged "$dir" s1 2100
  cycle "$dir"
  assert_kept "$dir" s1 declared-stop
  pass "stop row paused: a declared wait keeps the seat"
}

stop_blocked_keeps() {
  local dir
  dir=$(new_case stop-blocked)
  add_task "$dir" s1 ship
  status_lines "$dir" s1 'blocked [at=1900]: need a credential'
  merged "$dir" s1 2100
  cycle "$dir"
  assert_kept "$dir" s1 open-decision
  pass "stop row blocked: an open blocker keeps the seat"
}

stop_usage_limit_mid_task_keeps() {
  local dir
  dir=$(new_case stop-quota)
  finished_scout "$dir" sc
  status_lines "$dir" sc 'working [at=1990]: halfway through'
  cycle "$dir"
  assert_kept "$dir" sc no-done
  pass "stop row usage limit: an idle worker that never wrote done keeps the seat"
}

stop_crash_endpoint_gone_keeps() {
  local dir
  dir=$(new_case stop-crash)
  finished_ship "$dir" s1
  stub "$dir" s1 agent missing
  cycle "$dir"
  assert_kept "$dir" s1 agent-not-live
  pass "stop row crash: a gone endpoint is not acted on (recovery owns it)"
}

stop_trust_dialog_keeps() {
  local dir
  dir=$(new_case stop-dialog)
  finished_ship "$dir" s1
  stub "$dir" s1 busy 'unknown launch-prompt'
  cycle "$dir"
  assert_kept "$dir" s1 busy-unreadable
  pass "stop row dialog: an agent at a launch dialog is not proven idle and keeps the seat"
}

stop_compaction_or_long_think_keeps() {
  local dir
  dir=$(new_case stop-busy)
  finished_ship "$dir" s1
  stub "$dir" s1 busy 'busy claude-hook'
  cycle "$dir"
  assert_kept "$dir" s1 busy-busy
  pass "stop row compaction: a busy agent keeps the seat"
}

stop_looping_keeps() {
  local dir
  dir=$(new_case stop-loop)
  finished_ship "$dir" s1
  stub "$dir" s1 crew working
  cycle "$dir"
  assert_kept "$dir" s1 crew-state-working
  pass "stop row looping: a worker crew state reads working keeps the seat"
}

stop_unsent_composer_text_keeps() {
  local dir
  dir=$(new_case stop-composer)
  finished_ship "$dir" s1
  stub "$dir" s1 composer pending
  cycle "$dir"
  assert_kept "$dir" s1 pending-composer
  pass "stop row unsent text: a pending composer keeps the seat"
}

stop_validation_running_or_green_open_pr_keeps() {
  local dir
  dir=$(new_case stop-nm)
  add_task "$dir" running ship
  status_lines "$dir" running 'done [at=2000]: handed off'
  merged "$dir" running 2100
  stub "$dir" running crew working
  add_task "$dir" green ship
  status_lines "$dir" green 'done [at=2000]: PR https://github.com/o/r/pull/7 checks green'
  cycle "$dir"
  assert_kept "$dir" running crew-state-working
  assert_kept "$dir" green kept-open-pr
  pass "stop row validation: a running pipeline, and a green PR waiting on merge, keep the seat"
}

stop_pr_merged_while_idle_is_released() {
  local dir
  dir=$(new_case stop-merged-idle)
  add_task "$dir" s1 ship
  status_lines "$dir" s1 'working [at=1500]: opening the PR'
  merged "$dir" s1 2100
  stub "$dir" s1 crew unknown
  cycle "$dir" s1
  assert_released "$dir" s1 merged-ship
  grep -q 'anchor=2100' "$dir/home/data/lane-release.ledger" || fail "the merged-while-idle anchor is not the merge record time"
  pass "stop row merged while idle: a merged ship that never wrote done is released on the merge anchor"
}

stop_machine_unreachable_is_unknown() {
  local dir out rc
  dir=$(new_case stop-unreachable)
  finished_scout "$dir" sc
  stub "$dir" sc agent unreadable
  out=$(run_lr "$dir" 9000 --audit); rc=$?
  expect_code 2 "$rc" "an unreadable endpoint makes the audit unknown"$'\n'"$out"
  cycle "$dir"
  assert_kept "$dir" sc endpoint-unreadable
  pass "stop row unreachable: no read means no release and an unknown audit"
}

stop_failed_terminal_keeps() {
  local dir
  dir=$(new_case stop-failed)
  add_task "$dir" s1 ship
  status_lines "$dir" s1 'failed [at=1900]: could not build'
  merged "$dir" s1 2100
  finished_scout "$dir" sc
  status_lines "$dir" sc 'failed [at=1900]: could not reproduce'
  cycle "$dir"
  assert_kept "$dir" s1 declared-stop
  assert_kept "$dir" sc no-done
  pass "stop row failed: a failed worker keeps its seat in A1-core"
}

stop_interrupted_on_purpose_keeps() {
  local dir gen
  dir=$(new_case stop-interrupt)
  finished_scout "$dir" sc
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" sc)
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/home/state" sc idle --gen "$gen" \
    --source fm-interrupt --event escape >/dev/null
  cycle "$dir"
  assert_kept "$dir" sc interrupted
  pass "stop row interrupted: a worker firstmate interrupted keeps the seat"
}

stop_done_with_unread_steer_keeps() {
  local dir
  dir=$(new_case stop-unread)
  finished_scout "$dir" sc
  mkdir -p "$dir/home/state/sc.inbox"
  printf 'from=firstmate\n--\none more thing\n' > "$dir/home/state/sc.inbox/1.msg"
  cycle "$dir"
  assert_kept "$dir" sc unread-steer
  pass "stop row unread steer: a done worker with an unhandled message keeps the seat"
}

stop_scout_done_versus_ship_done() {
  local dir
  dir=$(new_case stop-scout-ship)
  finished_scout "$dir" noreport
  rm -f "$dir/home/data/noreport/report.md"
  finished_scout "$dir" sc
  finished_ship "$dir" s1
  cycle "$dir" sc s1
  assert_kept "$dir" noreport no-report
  assert_released "$dir" sc scout
  assert_released "$dir" s1 merged-ship
  pass "stop row scout vs ship: a scout needs its report and gate; a ship needs its merge"
}

stop_tool_failed_mid_task_keeps() {
  local dir
  dir=$(new_case stop-tool)
  finished_scout "$dir" sc
  status_lines "$dir" sc 'working [at=1990]: ❌ code index down, reading files instead'
  cycle "$dir"
  assert_kept "$dir" sc no-done
  pass "stop row tool failed: a worker that has not finished keeps the seat"
}

stop_away_quiet_and_restart_still_release_once() {
  local dir
  dir=$(new_case stop-away)
  : > "$dir/home/state/.afk"
  finished_ship "$dir" s1
  cycle "$dir" s1
  assert_released "$dir" s1 merged-ship
  run_lr "$dir" 3000 sweep >/dev/null
  run_lr "$dir" 3400 sweep >/dev/null
  [ "$(control_calls "$dir")" = 1 ] || fail "a restart re-acted on a released worker"
  pass "stop row away/restart: the sweep runs in away mode, and a restart is idempotent"
}

stop_owner_typed_in_the_window_keeps() {
  local dir
  dir=$(new_case stop-owner)
  finished_scout "$dir" sc
  stub "$dir" sc composer pending
  cycle "$dir"
  assert_kept "$dir" sc pending-composer
  pass "stop row owner typed: the owner's unsent text keeps the seat"
}

stop_stuck_composer_is_reported_never_released() {
  local dir out
  dir=$(new_case stop-stuck)
  finished_scout "$dir" sc
  mkdir -p "$dir/home/state/sc.inbox"
  printf 'from=firstmate\n--\nsteer\n' > "$dir/home/state/sc.inbox/1.msg"
  stub "$dir" sc composer pending
  stub "$dir" sc doorbell yes
  cycle "$dir"
  assert_kept "$dir" sc stuck-composer
  out=$(run_lr "$dir" 9000 --audit)
  assert_contains "$out" "stuck-composer sc" "the audit should list the stuck composer"
  assert_contains "$out" "stuck-composer=1" "the audit summary should count it"
  pass "stop row stuck composer: our own unsubmitted doorbell is classified and reported, never released"
}

# --- revision3.md extra cases --------------------------------------------------

extra_done_then_question_is_not_released() {
  local dir gen
  dir=$(new_case extra-done-then)
  finished_scout "$dir" steer
  mkdir -p "$dir/home/state/steer.inbox/handled"
  printf 'from=firstmate\n--\nanswered\n' > "$dir/home/state/steer.inbox/handled/1.msg"
  finished_scout "$dir" relaunched
  sed -i.bak 's/^spawn_gen=.*/spawn_gen=s2050.1.1/' "$dir/home/state/relaunched.meta"
  finished_scout "$dir" typed
  stub "$dir" typed composer pending
  finished_scout "$dir" chat
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" chat)
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/home/state" chat idle --gen "$gen" \
    --source claude-hook --event stop >/dev/null
  cycle "$dir"
  assert_kept "$dir" steer steer-since
  assert_kept "$dir" relaunched done-before-launch
  assert_kept "$dir" typed pending-composer
  assert_kept "$dir" chat turn-since
  pass "extra done-then-question: a steer, relaunch, typed text, or chat turn after done keeps the seat"
}

extra_closed_unmerged_is_not_released() {
  local dir
  dir=$(new_case extra-closed)
  add_task "$dir" s1 ship
  status_lines "$dir" s1 'done [at=2000]: PR https://github.com/o/r/pull/7 closed'
  cycle "$dir"
  assert_kept "$dir" s1 kept-open-pr
  pass "extra closed-unmerged: no merge record, no release"
}

extra_scout_awaiting_promotion_is_not_released() {
  local dir
  dir=$(new_case extra-promotion)
  finished_scout "$dir" held
  stub "$dir" held held 0
  finished_scout "$dir" promoting
  printf 'ship contract\n' > "$dir/home/data/promoting/ship-instructions.md"
  finished_scout "$dir" board
  mkdir -p "$dir/home/state/procevent"
  printf 'adapter=lavish\nkind=task-owned\nowner_task=board\n' > "$dir/home/state/procevent/lavish-x.source"
  finished_scout "$dir" gate
  stub "$dir" gate verify 1
  cycle "$dir"
  assert_kept "$dir" held held-for-captain
  assert_kept "$dir" promoting promotion-pending
  assert_kept "$dir" board board-pending
  assert_kept "$dir" gate completion-gate-not-passed
  pass "extra scout awaiting promotion: a held, promoting, board-hosting, or ungated scout keeps the seat"
}

extra_open_pr_ship_is_kept_and_measured() {
  local dir out rc
  dir=$(new_case extra-open-pr)
  add_task "$dir" s1 ship
  status_lines "$dir" s1 'done [at=2000]: PR https://github.com/o/r/pull/7 checks green'
  cycle "$dir"
  assert_kept "$dir" s1 kept-open-pr
  out=$(run_lr "$dir" $((2000 + 3 * 3600)) --audit); rc=$?
  expect_code 0 "$rc" "a kept open-PR ship is not an audit miss"$'\n'"$out"
  assert_contains "$out" "kept-open-pr s1 idle-since-done=3h" "the audit should measure the open-PR seat"
  assert_contains "$out" "kept-open-pr seat-hours=3" "the audit summary should total open-PR seat-hours"
  pass "extra open-PR ship: kept, and reported as phase-2 seat-hours, never as a miss"
}

extra_two_done_lines_at_once_do_not_double_act() {
  local dir
  dir=$(new_case extra-two)
  finished_ship "$dir" a1
  finished_scout "$dir" b2
  cycle "$dir" a1 b2
  assert_released "$dir" a1 merged-ship
  assert_released "$dir" b2 scout
  run_lr "$dir" 3500 sweep >/dev/null
  run_lr "$dir" 3900 sweep >/dev/null
  [ "$(control_calls "$dir")" = 2 ] || fail "two finished workers drew more than one exit each: $(cat "$dir/t/control.log")"
  [ "$(grep -c '^RELEASED' "$dir/home/data/lane-release.ledger")" = 2 ] || fail "a release was ledgered twice"
  pass "extra two at once: each finished worker is stopped once and ledgered once"
}

extra_release_cap_per_sweep() {
  local dir
  dir=$(new_case extra-cap)
  finished_ship "$dir" c1
  finished_ship "$dir" c2
  finished_ship "$dir" c3
  run_lr "$dir" 2500 sweep >/dev/null
  run_lr "$dir" 2900 sweep >/dev/null
  [ "$(find "$dir/home/state" -maxdepth 1 -name '*.released' | wc -l | tr -d ' ')" = 2 ] \
    || fail "one sweep started more than two releases"
  pass "extra budget: one sweep starts at most two releases"
}

extra_release_verified_or_incomplete() {
  local dir out rc
  dir=$(new_case extra-incomplete)
  finished_ship "$dir" s1
  : > "$dir/t/s1.keep-seat"
  cycle "$dir" s1
  grep -qx 'result=releasing' "$dir/home/state/s1.released" || fail "one held-seat sweep already concluded"
  [ ! -s "$dir/sweep3.out" ] || fail "the first held-seat sweep woke"
  run_lr "$dir" 3300 sweep > "$dir/sweep4.out"
  assert_contains "$(cat "$dir/sweep4.out")" "RELEASE_INCOMPLETE s1" "a seat still held after two sweeps should wake"
  grep -q '^RELEASE_INCOMPLETE	task=s1	.*verified=no' "$dir/home/data/lane-release.ledger" || fail "no RELEASE_INCOMPLETE row"
  run_lr "$dir" 3700 sweep > "$dir/sweep5.out"
  [ ! -s "$dir/sweep5.out" ] || fail "RELEASE_INCOMPLETE woke twice"
  out=$(run_lr "$dir" $((3300 + 2000)) --audit); rc=$?
  expect_code 1 "$rc" "an incomplete release older than the bound is an audit miss"$'\n'"$out"
  stub "$dir" s1 seat no
  run_lr "$dir" 5400 sweep >/dev/null
  grep -qx 'result=released' "$dir/home/state/s1.released" || fail "a later free seat did not conclude the release"
  pass "extra verification: RELEASED only on a free seat; a held one is RELEASE_INCOMPLETE, woken once, still counted"
}

extra_switched_off_does_nothing_and_prints_nothing() {
  local dir out setting
  for setting in absent off; do
    dir=$(new_case "extra-off-$setting" "$setting")
    finished_ship "$dir" s1
    out=$(run_lr "$dir" 2500 sweep; run_lr "$dir" 2900 sweep)
    [ -z "$out" ] || fail "a switched-off sweep printed: $out"
    [ "$(control_calls "$dir")" = 0 ] || fail "a switched-off sweep stopped a worker"
    [ -z "$(find "$dir/home/state" -name '*release*' -o -name '.lane-release*')" ] \
      || fail "a switched-off sweep wrote state: $(find "$dir/home/state" -name '*release*')"
    [ ! -e "$dir/home/data/lane-release.ledger" ] || fail "a switched-off sweep wrote the ledger"
  done
  pass "extra switched off: absent or off, a sweep writes nothing, stops nothing, prints nothing"
}

extra_audit_setting_only_ledgers() {
  local dir
  dir=$(new_case extra-audit audit)
  finished_ship "$dir" s1
  cycle "$dir"
  run_lr "$dir" 3300 sweep >/dev/null
  [ "$(control_calls "$dir")" = 0 ] || fail "the audit setting stopped a worker"
  [ "$(grep -c '^WOULD_RELEASE	task=s1' "$dir/home/data/lane-release.ledger")" = 1 ] \
    || fail "the audit setting did not ledger exactly one WOULD_RELEASE"
  pass "extra audit setting: a would-release is ledgered once and nothing is stopped"
}

extra_invalid_setting_reports_once() {
  local dir out
  dir=$(new_case extra-invalid maybe)
  finished_ship "$dir" s1
  out=$(run_lr "$dir" 2500 sweep)
  assert_contains "$out" "holds 'maybe'" "an invalid setting should be reported"
  out=$(run_lr "$dir" 2900 sweep)
  [ -z "$out" ] || fail "an invalid setting was reported twice"
  [ "$(control_calls "$dir")" = 0 ] || fail "an invalid setting released a worker"
  pass "extra invalid setting: reported once, nothing released"
}

extra_debounce_needs_two_sweeps_a_grace_apart() {
  local dir gen
  dir=$(new_case extra-debounce)
  finished_ship "$dir" s1
  run_lr "$dir" 2500 sweep >/dev/null
  run_lr "$dir" 2600 sweep >/dev/null
  [ "$(control_calls "$dir")" = 0 ] || fail "a release started inside the grace"
  [ ! -e "$dir/home/state/s1.released" ] || fail "a marker was written inside the grace"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" s1)
  printf 'v1 gen=%s seq=7 state=idle source=claude-hook event=stop ts=2100\n' "$gen" > "$dir/home/state/s1.busy-state"
  run_lr "$dir" 2900 sweep >/dev/null
  [ "$(control_calls "$dir")" = 0 ] || fail "a moved busy seq did not restart the debounce"
  pass "extra debounce: one sweep never releases, and a turn between sweeps restarts the wait"
}

extra_deferred_exit_retries_without_spinning() {
  local dir
  dir=$(new_case extra-deferred)
  finished_ship "$dir" s1
  stub "$dir" s1 control-rc 75
  cycle "$dir" s1
  [ ! -e "$dir/home/state/s1.released" ] || fail "a deferred exit left a marker"
  grep -q '^exit-deferred 1' "$dir/home/state/lane-release.counters" || fail "a deferred exit was not counted"
  [ "$(control_calls "$dir")" = 1 ] || fail "a deferred exit was retried inside one sweep"
  rm -f "$dir/t/s1.control-rc"
  run_lr "$dir" 3300 sweep >/dev/null
  run_lr "$dir" 3700 sweep >/dev/null
  wait_exit_log "$dir" s1
  run_lr "$dir" 3750 sweep >/dev/null
  assert_released "$dir" s1 merged-ship
  pass "extra deferred: a 75 from control removes the marker and the task is retried on later sweeps"
}

extra_held_control_lock_skips() {
  local dir
  dir=$(new_case extra-lock)
  finished_ship "$dir" s1
  mkdir -p "$dir/home/state/.control-s1.lock"
  printf '%s\n' "$$" > "$dir/home/state/.control-s1.lock/pid"
  run_lr "$dir" 2500 sweep >/dev/null
  run_lr "$dir" 2900 sweep >/dev/null
  [ ! -e "$dir/home/state/s1.released" ] || fail "a release began under a held lifecycle lock"
  grep -q '^lock-busy 1' "$dir/home/state/lane-release.counters" || fail "a held lock was not counted"
  [ "$(control_calls "$dir")" = 0 ] || fail "a held lock still reached control"
  pass "extra lock: a held lifecycle lock skips the task for a later sweep"
}

extra_slow_gate_read_is_bounded_by_the_sweep_budget() {
  local dir start took
  dir=$(new_case extra-slow-gate)
  finished_scout "$dir" sc
  : > "$dir/t/sc.hold-hangs"
  start=$(date +%s)
  FM_LANE_RELEASE_BUDGET=2 run_lr "$dir" 2500 sweep >/dev/null
  took=$(( $(date +%s) - start ))
  [ "$took" -lt 10 ] || fail "a hanging gate read held the sweep for ${took}s"
  assert_kept "$dir" sc hold-unreadable
  pass "extra budget: a gate read that hangs is cut off inside the sweep budget and keeps the seat"
}

extra_local_only_ship_is_kept() {
  local dir
  dir=$(new_case extra-local)
  add_task "$dir" s1 ship local-only
  status_lines "$dir" s1 'done [at=2000]: ready branch'
  merged "$dir" s1 2100
  cycle "$dir"
  assert_kept "$dir" s1 local-only-unproven
  pass "extra local-only: no per-task landed record exists, so the ship keeps its seat"
}

extra_audit_exit_codes() {
  local dir out rc
  dir=$(new_case extra-audit-codes)
  finished_ship "$dir" s1
  out=$(run_lr "$dir" 2500 --audit); rc=$?
  expect_code 0 "$rc" "a fresh holder is not a miss"$'\n'"$out"
  assert_contains "$out" "setting=on" "the audit names the setting"
  assert_contains "$out" "holder s1 class=merged-ship age=400s" "the audit lists the holder"
  out=$(run_lr "$dir" 4000 --audit); rc=$?
  expect_code 1 "$rc" "a holder older than 30 minutes is a miss"$'\n'"$out"
  [ ! -e "$dir/home/state/s1.release-candidate" ] || fail "the audit wrote state"
  [ "$(control_calls "$dir")" = 0 ] || fail "the audit stopped a worker"
  dir=$(new_case extra-audit-off absent)
  finished_ship "$dir" s1
  out=$(run_lr "$dir" 4000 --audit); rc=$?
  expect_code 1 "$rc" "the audit reads a switched-off home too"$'\n'"$out"
  assert_contains "$out" "setting=off" "the audit names the off setting"
  pass "extra audit: read-only, 0 clean, 1 on a holder past 30 minutes, any setting"
}

extra_arm_registers_a_thin_check() {
  local dir out
  dir=$(new_case extra-arm)
  out=$(FM_HOME="$dir/home" "$LR" arm)
  assert_contains "$out" "armed: state/lane-release.check.sh" "arm should report the shim"
  [ -x "$dir/home/state/lane-release.check.sh" ] || fail "the shim is not executable"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-pr-lib.sh"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-check-lib.sh"
    fm_custom_check_registered "$dir/home/state" lane-release
  ) || fail "the shim is not registered with the watcher"
  finished_ship "$dir" s1
  FM_LANE_RELEASE_RUNNER="$dir/home/state/lane-release.check.sh" run_lr "$dir" 2500 >/dev/null
  [ "$(control_calls "$dir")" = 0 ] || fail "the registered check skipped the grace"
  FM_LANE_RELEASE_RUNNER="$dir/home/state/lane-release.check.sh" run_lr "$dir" 2900 >/dev/null
  wait_exit_log "$dir" s1
  FM_LANE_RELEASE_RUNNER="$dir/home/state/lane-release.check.sh" run_lr "$dir" 2950 >/dev/null
  assert_released "$dir" s1 merged-ship
  FM_HOME="$dir/home" "$LR" disarm >/dev/null
  [ ! -e "$dir/home/state/lane-release.check.sh" ] || fail "disarm left the shim"
  pass "extra carrier: arm writes and registers a thin check shim; disarm removes it"
}

extra_audit_marker_occupancy_and_unknown_reads() {
  local dir result out rc what
  for result in releasing release-incomplete released; do
    dir=$(new_case "audit-marker-$result")
    finished_ship "$dir" s1
    printf 'fm-lane-release-v1\ntask=s1\nspawn_gen=s1000.1.1\nreleased_at=3900\nanchor=2100\nclass=merged-ship\nresult=%s\n' "$result" > "$dir/home/state/s1.released"
    out=$(run_lr "$dir" 4000 --audit); rc=$?
    expect_code 1 "$rc" "an occupied marker uses the finished anchor, even if release was recent"$'\n'"$out"
    assert_contains "$out" "holder s1 class=merged-ship age=1900s state=$result" "the marker cannot hide an overdue seat"
    stub "$dir" s1 seat unknown
    out=$(run_lr "$dir" 4000 --audit); rc=$?
    expect_code 2 "$rc" "unreadable marker occupancy must be unknown"$'\n'"$out"
    stub "$dir" s1 seat no
    out=$(run_lr "$dir" 4000 --audit); rc=$?
    expect_code 0 "$rc" "a proven free marker holds no seat"$'\n'"$out"
  done
  for what in composer busy malformed; do
    dir=$(new_case "audit-unknown-$what")
    finished_ship "$dir" s1
    case "$what" in
      malformed) printf 'invalid\n' > "$dir/home/state/s1.busy-state" ;;
      *) stub "$dir" s1 "$what" unknown ;;
    esac
    out=$(run_lr "$dir" 4000 --audit); rc=$?
    expect_code 2 "$rc" "unreadable $what evidence must make the audit unknown"$'\n'"$out"
    finished_ship "$dir" s2
    out=$(run_lr "$dir" 4000 --audit); rc=$?
    expect_code 2 "$rc" "unknown evidence takes precedence over another overdue holder"$'\n'"$out"
  done
  pass "audit counts occupied markers from the anchor and propagates unknown evidence"
}

extra_all_external_reads_share_the_sweep_deadline() {
  local dir what start took i
  for what in agent busy composer doorbell seat; do
    dir=$(new_case "budget-$what")
    finished_ship "$dir" s1
    : > "$dir/t/s1.$what-hangs"
    case "$what" in
      doorbell)
        (
          . "$ROOT/bin/fm-task-inbox-lib.sh"
          fm_task_inbox_write "$dir/home/state" s1 continuation >/dev/null
        ) || fail "could not enqueue the steer"
        ;;
      seat)
        for i in 1 2 3; do
          finished_ship "$dir" "m$i"
          printf 'fm-lane-release-v1\ntask=m%s\nspawn_gen=s1000.1.1\nreleased_at=2200\nanchor=2100\nclass=merged-ship\nresult=release-incomplete\n' "$i" > "$dir/home/state/m$i.released"
          : > "$dir/t/m$i.seat-hangs"
        done
        ;;
    esac
    start=$(date +%s)
    FM_LANE_RELEASE_BUDGET=2 run_lr "$dir" 2500 sweep >/dev/null
    took=$(( $(date +%s) - start ))
    [ "$took" -le 3 ] || fail "$what reads exceeded the shared 2s budget: ${took}s"
    [ "$(control_calls "$dir")" = 0 ] || fail "a timed-out read still released a worker"
  done
  pass "agent, busy, composer, doorbell and marker seat reads stop at the sweep deadline"
}

extra_shared_seat_rule_preserves_uncertainty() {
  local dir
  dir=$(new_case seat-evidence)
  (
    . "$ROOT/bin/fm-project-capacity-lib.sh"
    fm_backend_agent_state() { printf '%s\n' "$agent"; }
    local agent=alive raw rc
    raw="window=example
worktree=$dir/absent"
    rc=0
    fm_task_record_holds_seat "$dir/home/state/s1.meta" "$raw" "$dir/home/state" || rc=$?
    expect_code 0 "$rc" "a live agent still holds a seat"
    [ "$FM_TASK_RECORD_SEAT_KNOWN" = 1 ] || fail "live occupancy was marked unknown"
    agent=dead
    fm_task_record_holds_seat "$dir/home/state/s1.meta" "$raw" "$dir/home/state" || fail "uncertainty must retain the capacity seat"
    [ "$FM_TASK_RECORD_SEAT_KNOWN" = 0 ] || fail "an unreadable worktree was presented as proven occupancy"
    raw="window=example
worktree=$dir/home/state/s1.released-copy"
    rc=0
    fm_task_record_holds_seat "$dir/home/state/s1.meta" "$raw" "$dir/home/state" || rc=$?
    expect_code 1 "$rc" "a stopped released-copy record holds no seat"
    [ "$FM_TASK_RECORD_SEAT_KNOWN" = 1 ] || fail "a proven free seat was marked unknown"
  ) || fail "the shared seat evidence contract failed"
  pass "shared capacity keeps uncertain seats occupied while exposing uncertainty to audit"
}

extra_turns_during_external_reads_keep_the_seat() {
  local dir what
  for what in agent busy composer; do
    dir=$(new_case "turn-during-$what")
    finished_ship "$dir" s1
    : > "$dir/t/s1.turn-on-$what"
    cycle "$dir"
    assert_kept "$dir" s1 turn-since
    grep -q 'seq=9 ' "$dir/home/state/s1.busy-state" || fail "the intervening turn did not complete"
  done
  dir=$(new_case no-monotonic-record)
  finished_ship "$dir" s1
  rm "$dir/home/state/s1.busy-state" "$dir/home/state/s1.busy-gen"
  cycle "$dir"
  assert_kept "$dir" s1 busy-record-unreadable
  pass "a complete turn during any live read, or absent turn history, prevents release"
}

extra_open_pr_audit_requires_readable_positive_evidence() {
  local dir provider state out rc url fault start took
  for provider in github gitlab forgejo gerrit; do
    case "$provider" in
      github) url=https://github.com/o/r/pull/7 ;;
      gitlab) url=https://gitlab.example.org/o/r/-/merge_requests/7 ;;
      forgejo) url=https://forge.example.org/o/r/pulls/7 ;;
      gerrit) url=https://review.example.org/c/o/r/+/7 ;;
    esac
    for state in open closed merged unknown; do
      dir=$(new_case "audit-$provider-$state")
      add_task "$dir" s1 ship
      printf 'pr=%s\n' "$url" >> "$dir/home/state/s1.meta"
      status_lines "$dir" s1 'done [at=2000]: ready'
      printf '%s\n' "$state" > "$dir/t/pr-state"
      out=$(run_lr "$dir" 12800 --audit); rc=$?
      case "$state" in
        open)
          expect_code 0 "$rc" "$provider OPEN is readable"$'\n'"$out"
          assert_contains "$out" 'kept-open-pr seat-hours=3' "$provider OPEN contributes exactly three hours"
          ;;
        closed|merged)
          expect_code 0 "$rc" "$provider terminal state is readable"$'\n'"$out"
          assert_contains "$out" 'kept-open-pr seat-hours=0' "a terminal PR is never counted as OPEN"
          ;;
        *) expect_code 2 "$rc" "an unrecognized provider record must be unknown"$'\n'"$out" ;;
      esac
    done
  done
  for fault in endpoint status inbox message failure hang; do
    dir=$(new_case "audit-open-$fault")
    add_task "$dir" s1 ship
    status_lines "$dir" s1 'done [at=2000]: ready'
    case "$fault" in
      endpoint) stub "$dir" s1 agent unknown ;;
      status) rm "$dir/home/state/s1.status"; mkdir "$dir/home/state/s1.status" ;;
      inbox) printf 'unreadable inbox shape\n' > "$dir/home/state/s1.inbox" ;;
      message) mkdir -p "$dir/home/state/s1.inbox/000001.msg" ;;
      failure|hang) printf '%s\n' "$fault" > "$dir/t/pr-state" ;;
    esac
    start=$(date +%s)
    out=$(run_lr "$dir" 12800 --audit); rc=$?
    took=$(( $(date +%s) - start ))
    expect_code 2 "$rc" "unreadable $fault evidence makes open-PR metrics unknown"$'\n'"$out"
    assert_contains "$out" 'kept-open-pr seat-hours=0' "unknown evidence cannot contribute seat-hours"
    [ "$took" -lt 15 ] || fail "the provider read exceeded its 10s bound: ${took}s"
    [ "$(control_calls "$dir")" = 0 ] || fail "the audit stopped a worker"
  done
  pass "open-PR metrics require positive OPEN evidence on every provider and propagate all read failures"
}

extra_marker_verification_rotates_with_candidates() {
  local dir id i start took
  dir=$(new_case rotating-verification)
  for id in a b; do
    finished_ship "$dir" "$id"
    printf 'fm-lane-release-v1\ntask=%s\nspawn_gen=s1000.1.1\nreleased_at=2200\nanchor=2100\nclass=merged-ship\nresult=release-incomplete\n' "$id" > "$dir/home/state/$id.released"
    : > "$dir/t/$id.seat-hangs"
  done
  finished_ship "$dir" z
  for i in 0 1 2 3 4 5; do
    start=$(date +%s)
    FM_LANE_RELEASE_BUDGET=2 run_lr "$dir" "$((2500 + 400 * i))" sweep >/dev/null
    took=$(( $(date +%s) - start ))
    [ "$took" -le 3 ] || fail "a rotating sweep exceeded its 2s budget: ${took}s"
  done
  wait_exit_log "$dir" z
  [ "$(control_calls "$dir")" = 1 ] || fail "slow markers starved the eligible candidate"
  pass "verification and candidate work share the durable cursor without starvation"
}

extra_herdr_checks_release_guard_at_each_transport() {
  local dir action mode out rc
  dir=$(new_case herdr-release-guard)
  cat > "$dir/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_GUARD_LOG"
[ "${FM_GUARD_MODE:-}" != retry ] || { echo protocol_mismatch >&2; exit 1; }
SH
  chmod +x "$dir/herdr"
  for mode in allow refuse retry; do
    for action in send-text send-keys; do
      : > "$dir/t/transport"
      out=$(
        export PATH="$dir:$PATH" FM_GUARD_LOG="$dir/t/transport" FM_GUARD_MODE="$mode"
        . "$ROOT/bin/backends/herdr.sh"
        fm_control_lane_release_guard() { [ "$FM_GUARD_MODE" != refuse ] && [ ! -e "$dir/t/reselected" ]; }
        fm_backend_herdr_client_select() { : > "$dir/t/reselected"; }
        fm_backend_herdr_bin() { printf '%s\n' "$dir/compatible-herdr"; }
        fm_backend_herdr_cli test pane "$action" p1 payload
      ); rc=$?
      case "$mode" in
        allow)
          expect_code 0 "$rc" "an unchanged guard permits Herdr transport"$'\n'"$out"
          [ "$(wc -l < "$dir/t/transport")" -eq 1 ] || fail "the ordinary transport was not sent once"
          ;;
        refuse)
          expect_code 75 "$rc" "a changed guard must defer Herdr transport"$'\n'"$out"
          [ ! -s "$dir/t/transport" ] || fail "Herdr sent input despite refusal"
          ;;
        retry)
          expect_code 75 "$rc" "a guard changed during client selection must defer the retry"$'\n'"$out"
          [ "$(wc -l < "$dir/t/transport")" -eq 1 ] || fail "Herdr retried after the guard changed"
          ;;
      esac
      rm -f "$dir/t/reselected"
    done
  done
  pass "Herdr rechecks the release guard before each literal, key and protocol retry"
}

edge_trigger_is_a_confirmed_done_never_an_exited_or_quiet_pane
edge_stopped_but_not_done_never_frees
edge_done_is_not_landed_the_action_is_exit_only
edge_worker_needed_again_relaunch_clears_the_marker
edge_a_seat_is_not_a_copy
edge_auto_start_is_out_of_scope
edge_same_worker_or_fresh_continuations_keep_the_seat
edge_per_home_only
edge_harness_agnostic_refusal_keeps_the_seat
edge_remote_and_unreachable_are_unknown_never_free
stop_finished_done_is_released
stop_needs_decision_keeps
stop_ask_user_finding_keeps
stop_question_only_in_chat_keeps
stop_declared_paused_keeps
stop_blocked_keeps
stop_usage_limit_mid_task_keeps
stop_crash_endpoint_gone_keeps
stop_trust_dialog_keeps
stop_compaction_or_long_think_keeps
stop_looping_keeps
stop_unsent_composer_text_keeps
stop_validation_running_or_green_open_pr_keeps
stop_pr_merged_while_idle_is_released
stop_machine_unreachable_is_unknown
stop_failed_terminal_keeps
stop_interrupted_on_purpose_keeps
stop_done_with_unread_steer_keeps
stop_scout_done_versus_ship_done
stop_tool_failed_mid_task_keeps
stop_away_quiet_and_restart_still_release_once
stop_owner_typed_in_the_window_keeps
stop_stuck_composer_is_reported_never_released
extra_done_then_question_is_not_released
extra_closed_unmerged_is_not_released
extra_scout_awaiting_promotion_is_not_released
extra_open_pr_ship_is_kept_and_measured
extra_two_done_lines_at_once_do_not_double_act
extra_release_cap_per_sweep
extra_release_verified_or_incomplete
extra_switched_off_does_nothing_and_prints_nothing
extra_audit_setting_only_ledgers
extra_invalid_setting_reports_once
extra_debounce_needs_two_sweeps_a_grace_apart
extra_deferred_exit_retries_without_spinning
extra_held_control_lock_skips
extra_slow_gate_read_is_bounded_by_the_sweep_budget
extra_local_only_ship_is_kept
extra_audit_exit_codes
extra_arm_registers_a_thin_check

extra_audit_marker_occupancy_and_unknown_reads
extra_all_external_reads_share_the_sweep_deadline

extra_shared_seat_rule_preserves_uncertainty

extra_turns_during_external_reads_keep_the_seat
extra_open_pr_audit_requires_readable_positive_evidence
extra_marker_verification_rotates_with_candidates

extra_herdr_checks_release_guard_at_each_transport
