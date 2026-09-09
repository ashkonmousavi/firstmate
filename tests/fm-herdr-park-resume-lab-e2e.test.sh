#!/usr/bin/env bash
# tests/fm-herdr-park-resume-lab-e2e.test.sh - the park-and-resume journey on
# the REAL herdr backend, inside one isolated named lab session.
#
# The restart and ownership repair on local main was proven end to end on tmux
# only. tmux and herdr are the two backends whose recovery-grade agent-state
# classifier the lifecycle plane is allowed to trust, and herdr is the runtime
# this fleet actually runs on, so the three decisions that repair depends on are
# pinned here against the real binary rather than a stub:
#
#   1. A lane stopped with `bin/fm-control.sh <id> exit` carries `parked=` in
#      its durable record, and after a real herdr session restart supervision
#      still reads it as parked - from the MARKER, while its endpoint
#      independently reads `dead` - so nothing re-surfaces or relaunches it.
#   2. A lane whose agent was alive at the restart comes back agent-free,
#      recovers with ONE `bin/fm-spawn.sh --relaunch` into its own recorded
#      worktree carrying its recorded harness, model, effort and yolo posture,
#      and a second recovery pass changes nothing because the endpoint now
#      reads `alive` and the relaunch refuses.
#   3. A lane whose pane is gone relaunches into a fresh endpoint in the same
#      worktree - including the case herdr makes unavoidable, where closing a
#      workspace's last pane deletes the WORKSPACE too. That case refused before
#      this suite's fix and stranded eleven parked lanes on 2026-09-09.
#
# No model is ever launched. The subject is firstmate's lifecycle decisions, not
# the harness: agent liveness comes from herdr's own registry through
# `pane report-agent` (the same primitive
# tests/fm-backend-herdr-respawn-idem-e2e.test.sh uses), and the recorded
# harness is a verified adapter whose binary is absent on this host, so the
# launch command lands in the pane and resolves to nothing. Every assertion here
# is about the container, the endpoint and the durable record, all of which the
# launch owner resolves and publishes BEFORE it sends that command
# (bin/fm-spawn.sh publishes the replacement record, then sends the launch).
# The harness process actually coming up is a different contract, covered by the
# spawn suites; the fm-control transaction that wraps the launch owner is
# covered hermetically in tests/fm-control-relaunch.test.sh.
#
# Safety (tests/herdr-test-safety.sh, bin/fm-herdr-lab.sh): one named non-default
# lab session, the teardown trap installed BEFORE provisioning, and every
# lifecycle call through the guarded helper. The live `default` session is never
# touched, and the helper's fleet-state tripwire fails the run if it changed.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

# The recorded harness for every lab lane. It must be a verified adapter whose
# binary is ABSENT here: the launch command then lands in the pane and resolves
# to nothing, so no model runs and nothing outside the lab is written. A host
# that has it installed would launch a real agent, which this suite does not
# mean to do, so skip rather than silently change what is being tested.
LAB_HARNESS=opencode
! command -v "$LAB_HARNESS" >/dev/null 2>&1 || {
  echo "skip: $LAB_HARNESS is installed here, so a lab relaunch would start a real agent"
  exit 0
}

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so the herdr pane
# identity inherited from whatever terminal launched it must not follow the
# spawn into that session and be refused there as a cross-session parent
# (tests/herdr-test-safety.sh). Called BEFORE the lab session is exported.
herdr_forget_inherited_pane

SESSION=$("$ROOT/bin/fm-herdr-lab.sh" name fm-park-resume) \
  || fail "could not generate an isolated lab session name"
SCRATCH=
cleanup_all() {
  "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION" >/dev/null 2>&1 || true
  [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"
}
trap cleanup_all EXIT
"$ROOT/bin/fm-herdr-lab.sh" provision "$SESSION" \
  || fail "could not provision the isolated Herdr lab session"
export HERDR_SESSION="$SESSION"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-park-resume.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd -P)
HOME_DIR="$SCRATCH/home"
STATE_DIR="$HOME_DIR/state"
DATA_DIR="$HOME_DIR/data"
mkdir -p "$STATE_DIR" "$DATA_DIR" "$HOME_DIR/config" "$HOME_DIR/projects"

# One real project; each lane gets its own real worktree, because "in its own
# recorded worktree" is one of the things under test.
PROJ="$SCRATCH/proj"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial

run_spawn() {  # <arguments...>
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

run_control() {  # <arguments...>
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.3 FM_CONTROL_EXIT_WAIT=25 FM_CONTROL_LAUNCH_WAIT=6 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

run_crew_state() {  # <task-id>
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    "$ROOT/bin/fm-crew-state.sh" "$1" 2>&1
}

lab() {  # <herdr arguments...>
  "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" "$@"
}

meta_get() {  # <task-id> <key>
  grep -m1 "^$2=" "$STATE_DIR/$1.meta" 2>/dev/null | cut -d= -f2- || true
}

# pane_cwd: the directory a pane was CREATED in, which is the axis the captain
# named as "its intended directory". `pane get`'s .result.pane.cwd is frozen at
# creation time (bin/backends/herdr.sh, fm_backend_herdr_current_path), which is
# exactly what is wanted here: it reports where the replacement was ROOTED, not
# wherever a shell later wandered. Asserting it is what separates a record that
# merely NAMES the recorded worktree from an endpoint actually placed in it.
pane_cwd() {  # <pane-id>
  lab pane get "$1" 2>/dev/null | jq -r '.result.pane.cwd // empty'
}

# make_lane: a real worktree, a real herdr endpoint, and the durable record that
# names both. <container> is "<session>:<workspace_id>"; pass an empty seeded tab
# id when adopting a workspace that already holds a task tab.
make_lane() {  # <task-id> <container> <seeded-default-tab-id>
  local id=$1 container=$2 seeded=$3 wt ids tab pane
  wt="$SCRATCH/wt-$id"
  git -C "$PROJ" worktree add --quiet -b "lane-$id" "$wt" \
    || fail "could not create the lane worktree for $id"
  mkdir -p "$DATA_DIR/$id"
  {
    echo "# Task"
    echo "## Captain's intent"
    echo "Lab lane $id; this brief is never executed."
    echo "## Firstmate spec"
    echo "Nothing to build; the suite asserts on the record, not on a worker."
    echo "# Proof bar"
    echo "Prep: Tier 0 - lab fixture, never executed."
    echo "Resource: none."
    echo "Surface: none: lab fixture."
    echo "Journey: none: lab fixture."
  } > "$DATA_DIR/$id/brief.md"
  ids=$(fm_backend_herdr_create_task "$container" "fm-$id" "$wt" "$seeded") \
    || fail "could not create the herdr endpoint for $id"
  read -r tab pane <<EOF
$ids
EOF
  [ -n "$tab" ] && [ -n "$pane" ] || fail "herdr returned no tab/pane id for $id"
  {
    echo "window=$SESSION:$pane"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$PROJ"
    echo "harness=$LAB_HARNESS"
    echo "kind=ship"
    echo "mode=local-only"
    echo "yolo=on"
    echo "model=lab-model"
    echo "effort=${LANE_EFFORT:-default}"
    echo "backend=herdr"
    echo "herdr_session=$SESSION"
    echo "herdr_workspace_id=${container#*:}"
    echo "herdr_tab_id=$tab"
    echo "herdr_pane_id=$pane"
  } > "$STATE_DIR/$id.meta"
  chmod 0600 "$STATE_DIR/$id.meta"
  printf '%s\n' "$pane"
}

# arm_stoppable_agent: register a real herdr agent on <pane> and make the pane's
# own shell release that registration when it receives ONE line of input. The
# exit verb's postcondition is a recovery-grade `dead` reading, so this is what
# lets a plain shell answer the harness exit command the way a real agent does -
# with no sleep and no polling race, because the shell blocks in `read` until the
# exit command arrives.
arm_stoppable_agent() {  # <pane-id> <marker>
  local pane=$1 marker=$2 attempt=0 out
  lab pane send-text "$pane" \
    "printf '%s\\n' $marker; read -r _fm_lab_line; herdr pane release-agent $pane --source fm-park-resume-lab --agent fm-park-resume-lab-agent --session $SESSION >/dev/null 2>&1" \
    >/dev/null 2>&1 || return 1
  lab pane send-keys "$pane" Enter >/dev/null 2>&1 || return 1
  # The responder is armed only once the marker it printed is on screen; until
  # then the shell has not reached its blocking read.
  while [ "$attempt" -lt 100 ]; do
    out=$(lab pane read "$pane" 2>/dev/null || true)
    case "$out" in *"$marker"*) break ;; esac
    sleep 0.2
    attempt=$((attempt + 1))
  done
  [ "$attempt" -lt 100 ] || return 1
  lab pane report-agent "$pane" --source fm-park-resume-lab \
    --agent fm-park-resume-lab-agent --state idle >/dev/null 2>&1
}

# --- containers -------------------------------------------------------------
# Two workspaces, deliberately different shapes:
#   WS_MAIN keeps several task tabs, so closing one pane leaves the workspace
#           standing - the "gone endpoint, surviving workspace" case.
#   WS_SOLO holds exactly one task tab, so closing its pane deletes the
#           workspace with it - the case that refused before this fix.

RAW=$(fm_backend_herdr_container_ensure "$PROJ") || fail "container_ensure failed"
WS_MAIN_CONTAINER=${RAW%%$'\t'*}
WS_MAIN_SEEDED=${RAW#*$'\t'}
WS_MAIN=${WS_MAIN_CONTAINER#*:}

# --- case 1 and case 2 share ONE real session restart ------------------------

PARK_PANE=$(make_lane parked-lane "$WS_MAIN_CONTAINER" "$WS_MAIN_SEEDED")
ACTIVE_PANE=$(make_lane active-lane "$WS_MAIN_CONTAINER" "")

arm_stoppable_agent "$PARK_PANE" LAB-PARK-READY \
  || fail "could not arm a stoppable registered agent on the parked lane's pane"
[ "$(fm_backend_agent_state herdr "$SESSION:$PARK_PANE")" = alive ] \
  || fail "the parked lane should host a live registered agent before it is stopped"

OUT=$(run_control parked-lane exit --reason "lab park") \
  || fail "fm-control exit should stop the registered agent and park the lane: $OUT"
case "$OUT" in
  "stopped parked-lane "*"parked=yes") : ;;
  *) fail "exit should report a proven stop and a parked lane, got: $OUT" ;;
esac
[ "$(meta_get parked-lane parked)" != "" ] \
  || fail "exit must write parked=<epoch> into the durable record"
[ "$(meta_get parked-lane parked_reason)" = "lab park" ] \
  || fail "exit must record the parked reason it was given"
pass "case 1: fm-control exit stopped a live registered agent on real herdr and marked the lane parked"

lab pane report-agent "$ACTIVE_PANE" --source fm-park-resume-lab \
  --agent fm-park-resume-lab-agent --state idle >/dev/null 2>&1 \
  || fail "could not register a live agent on the active lane"
[ "$(fm_backend_agent_state herdr "$SESSION:$ACTIVE_PANE")" = alive ] \
  || fail "the active lane should read alive before the restart"
fm_task_is_parked "$STATE_DIR" active-lane \
  && fail "the active lane must not be parked before the restart"

PARK_META_BEFORE=$(cat "$STATE_DIR/parked-lane.meta")
ACTIVE_WT=$(meta_get active-lane worktree)

# A real session restart: the same mechanism docs/herdr-backend.md pins - every
# workspace/tab/pane id survives, every harness process and agent registration
# does not.
"$ROOT/bin/fm-herdr-lab.sh" stop "$SESSION" >/dev/null 2>&1 \
  || fail "could not stop the lab session for the restart"
sleep 0.5
fm_backend_herdr_server_ensure "$SESSION" \
  || fail "the lab session did not come back up after the restart"

[ "$(fm_backend_agent_state herdr "$SESSION:$PARK_PANE")" = dead ] \
  || fail "the parked lane's pane should survive the restart agent-free (dead), not gone"
[ "$(fm_backend_agent_state herdr "$SESSION:$ACTIVE_PANE")" = dead ] \
  || fail "the active lane's pane should survive the restart agent-free (dead), not gone"
pass "restart: both panes came back with their ids intact and no registered agent"

# --- case 1: parked stays parked --------------------------------------------

fm_task_is_parked "$STATE_DIR" parked-lane \
  || fail "REGRESSION: the parked marker did not survive the session restart"
OUT=$(run_crew_state parked-lane)
case "$OUT" in
  "state: parked-exit · source: task-record"*) : ;;
  *) fail "supervision should read the restarted lane as parked-exit from its record, got: $OUT" ;;
esac
case "$OUT" in
  *"lab park"*) : ;;
  *) fail "the parked current-state should carry the recorded reason, got: $OUT" ;;
esac
pass "case 1: after the restart, supervision reads the parked lane as parked-exit from its durable record"

# The marker is what holds it, not a missing endpoint: the endpoint is present
# and reads exactly the same `dead` as the active lane, which IS relaunched
# below. Same endpoint reading, opposite supervision outcome.
fm_task_is_parked "$STATE_DIR" active-lane \
  && fail "the active lane must not read parked; the two lanes must differ only in the marker"
OUT=$(run_crew_state active-lane)
case "$OUT" in
  "state: parked-exit"*) fail "the unparked active lane must not read parked-exit: $OUT" ;;
esac
pass "case 1: the marker, not the endpoint reading, is what parks the lane - both endpoints read dead, only the marked one is parked"

[ "$(cat "$STATE_DIR/parked-lane.meta")" = "$PARK_META_BEFORE" ] \
  || fail "reading the parked lane's state must not rewrite its durable record"
lab pane get "$PARK_PANE" >/dev/null 2>&1 \
  || fail "the parked lane's endpoint must be preserved, not reclaimed"
[ -d "$SCRATCH/wt-parked-lane" ] \
  || fail "the parked lane's local copy must be preserved"
# Nothing auto-relaunches an ordinary direct report: bin/fm-spawn.sh --relaunch
# is the only launch owner, and no supervision path calls it. What the parked
# marker changes is the SURFACING, and those consumers are pinned by their own
# suites: bin/fm-watch.sh's handle_parked_stale absorbs a parked lane with no
# re-surface at all (tests/fm-classify-parked.test.sh), and
# bin/fm-inactive-reconcile.sh leaves parked work its existing semantics.
pass "case 1: the parked lane kept its endpoint, its local copy and its record untouched"

# --- case 2: active recovers exactly once ------------------------------------

OUT=$(run_spawn active-lane --relaunch) \
  || fail "the active lane should recover with one relaunch after the restart: $OUT"
[ "$(meta_get active-lane worktree)" = "$ACTIVE_WT" ] \
  || fail "recovery must reuse the recorded worktree, never acquire a second copy"
[ "$(meta_get active-lane harness)" = "$LAB_HARNESS" ] \
  || fail "recovery must carry the recorded harness"
[ "$(meta_get active-lane yolo)" = on ] \
  || fail "recovery must carry the recorded yolo posture"
[ "$(meta_get active-lane mode)" = local-only ] \
  || fail "recovery must carry the recorded delivery mode"
[ "$(meta_get active-lane herdr_pane_id)" = "$ACTIVE_PANE" ] \
  || fail "a dead-but-present endpoint must be ADOPTED, not replaced"
[ "$(pane_cwd "$ACTIVE_PANE")" = "$ACTIVE_WT" ] \
  || fail "the recovered lane's endpoint must sit in the recorded local copy on the backend, not only in the record"
[ "$(meta_get active-lane parked)" = "" ] \
  || fail "a relaunch must not leave a parked marker on a running lane"
pass "case 2: the active lane recovered once, in its own worktree, with its recorded harness, mode and yolo posture"

# The replacement worker is now what occupies the endpoint. A second recovery
# pass must change nothing, and the reason it changes nothing is the same
# positive proof the first pass relied on: an endpoint with an agent in it is
# not agent-free, so the relaunch refuses instead of putting a second agent there.
lab pane report-agent "$ACTIVE_PANE" --source fm-park-resume-lab \
  --agent fm-park-resume-lab-agent --state idle >/dev/null 2>&1 \
  || fail "could not register the replacement agent on the recovered endpoint"
ACTIVE_META_AFTER=$(cat "$STATE_DIR/active-lane.meta")
if OUT=$(run_spawn active-lane --relaunch); then
  fail "a second recovery pass must refuse an endpoint that already hosts an agent: $OUT"
fi
case "$OUT" in
  *"requires a positively agent-free endpoint"*) : ;;
  *) fail "the second-pass refusal should name the live endpoint, got: $OUT" ;;
esac
[ "$(cat "$STATE_DIR/active-lane.meta")" = "$ACTIVE_META_AFTER" ] \
  || fail "a refused second recovery pass must leave the durable record byte-identical"
pass "case 2: a second recovery pass changes nothing - it refuses the live endpoint and leaves the record byte-identical"

lab pane release-agent "$ACTIVE_PANE" --source fm-park-resume-lab --agent fm-park-resume-lab-agent >/dev/null 2>&1 || true

# The recorded MODEL and EFFORT are resolved by the control plane, not by the
# launch owner: bin/fm-spawn.sh --relaunch re-reads harness, kind, mode, yolo and
# worktree from the record, while bin/fm-control.sh's relaunch profile is what
# re-reads the recorded model and effort and passes them down. So the axes the
# captain named are only proven end to end through the verb he actually uses.
#
# This lab deliberately records a harness with no binary on this host, so the one
# thing that cannot complete is the final postcondition - the replacement agent
# coming up. That failure is expected and asserted exactly, and it is also the
# documented boundary: the launch owner publishes the replacement record BEFORE
# it sends the launch command, so an unconfirmed agent keeps the new record
# (docs/agent-control.md, "Failure and rollback").
if OUT=$(run_control active-lane relaunch --note "lab recovery note"); then
  fail "the lab records a harness with no binary here, so the replacement agent cannot come up: $OUT"
fi
case "$OUT" in
  *"did not come up within"*) : ;;
  *) fail "the only expected relaunch failure is the agent-liveness postcondition, got: $OUT" ;;
esac
[ "$(meta_get active-lane model)" = lab-model ] \
  || fail "the control plane must carry the RECORDED model into the replacement record"
[ "$(meta_get active-lane effort)" = default ] \
  || fail "the control plane must carry the RECORDED effort into the replacement record"
[ "$(meta_get active-lane harness)" = "$LAB_HARNESS" ] \
  || fail "the control plane must carry the recorded harness into the replacement record"
[ "$(meta_get active-lane yolo)" = on ] \
  || fail "the control plane must preserve the recorded yolo posture"
[ "$(meta_get active-lane worktree)" = "$ACTIVE_WT" ] \
  || fail "the control plane must keep the replacement in the recorded worktree"
[ -d "$ACTIVE_WT" ] \
  || fail "an unconfirmed replacement must leave the local copy and its work untouched"
pass "case 2: relaunched through the control plane, the replacement record carries the recorded harness, model, effort and yolo posture in the recorded worktree"

# The recorded EFFORT is carried into the launch resolution, not quietly dropped.
# The lab's recorded harness has no reasoning-effort flag, so a lane recorded
# with one is exactly where a silent downgrade would be invisible: the relaunch
# must refuse and name the unsupported effort instead of relaunching the lane at
# the adapter default. No valid record can reach this state - a fresh spawn is
# stopped by the same gate - so the refusal is a proof, not a new obstacle.
LANE_EFFORT=high make_lane effort-lane "$WS_MAIN_CONTAINER" "" >/dev/null
[ "$(meta_get effort-lane effort)" = high ] || fail "the effort lane should record effort=high"
EFFORT_META_BEFORE=$(cat "$STATE_DIR/effort-lane.meta")
if OUT=$(run_spawn effort-lane --relaunch); then
  fail "a relaunch must not silently drop a recorded effort the harness cannot honour: $OUT"
fi
case "$OUT" in
  *"does not support requested effort high"*) : ;;
  *) fail "the refusal should name the recorded effort it carried, got: $OUT" ;;
esac
[ "$(cat "$STATE_DIR/effort-lane.meta")" = "$EFFORT_META_BEFORE" ] \
  || fail "a refused relaunch must leave the durable record byte-identical"
pass "case 2: a recorded effort is carried into the relaunch - an effort the harness cannot honour refuses instead of downgrading the lane silently"

# --- case 3a: gone endpoint, surviving workspace -----------------------------

GONE_PANE=$(make_lane gone-pane-lane "$WS_MAIN_CONTAINER" "")
GONE_WT=$(meta_get gone-pane-lane worktree)
lab pane close "$GONE_PANE" >/dev/null 2>&1 \
  || fail "could not close the lane's pane"
[ "$(fm_backend_agent_state herdr "$SESSION:$GONE_PANE")" = missing ] \
  || fail "a closed pane should classify as missing"
[ "$(fm_backend_herdr_workspace_presence_state "$SESSION" "$WS_MAIN")" = present ] \
  || fail "closing one pane of a multi-tab workspace must leave the workspace standing"

OUT=$(run_spawn gone-pane-lane --relaunch) \
  || fail "a lane whose pane is gone should relaunch into a fresh endpoint: $OUT"
NEW_PANE=$(meta_get gone-pane-lane herdr_pane_id)
[ -n "$NEW_PANE" ] && [ "$NEW_PANE" != "$GONE_PANE" ] \
  || fail "the replacement must be a NEW pane, not the closed one"
lab pane get "$NEW_PANE" >/dev/null 2>&1 \
  || fail "the replacement pane should exist"
[ "$(pane_cwd "$NEW_PANE")" = "$GONE_WT" ] \
  || fail "the fresh endpoint must be rooted in the recorded local copy on the backend"
[ "$(meta_get gone-pane-lane herdr_workspace_id)" = "$WS_MAIN" ] \
  || fail "the replacement must stay in the recorded workspace while that workspace exists"
[ "$(meta_get gone-pane-lane worktree)" = "$GONE_WT" ] \
  || fail "the replacement must be rooted in the SAME recorded worktree"
[ "$(meta_get gone-pane-lane window)" = "$SESSION:$NEW_PANE" ] \
  || fail "the record must be republished with the new endpoint"
pass "case 3a: a gone pane relaunches into a fresh endpoint in the same workspace and the same worktree"

# --- case 3b: gone endpoint AND gone workspace (the 2026-09-09 defect) -------
# herdr deletes a workspace whose last pane closes, so a solo lane loses both at
# once. Before the fix this refused with "no longer exists; refusing to relaunch
# into a different workspace" and the lane stayed stopped.

SOLO_RAW=$(fm_backend_herdr_cli "$SESSION" workspace create --cwd "$PROJ" \
  --label fm-park-resume-solo --no-focus 2>/dev/null) \
  || fail "could not create the solo lab workspace"
WS_SOLO=$(printf '%s' "$SOLO_RAW" | jq -r '.result.workspace.workspace_id // empty')
WS_SOLO_SEEDED=$(printf '%s' "$SOLO_RAW" | jq -r '.result.tab.tab_id // empty')
[ -n "$WS_SOLO" ] || fail "the solo workspace returned no workspace id"

SOLO_PANE=$(make_lane solo-lane "$SESSION:$WS_SOLO" "$WS_SOLO_SEEDED")
SOLO_WT=$(meta_get solo-lane worktree)
lab pane close "$SOLO_PANE" >/dev/null 2>&1 \
  || fail "could not close the solo lane's only pane"
[ "$(fm_backend_agent_state herdr "$SESSION:$SOLO_PANE")" = missing ] \
  || fail "the closed solo pane should classify as missing"
[ "$(fm_backend_herdr_workspace_presence_state "$SESSION" "$WS_SOLO")" = dead ] \
  || fail "repro is wrong: closing a workspace's last pane should have deleted the workspace"
pass "case 3b repro: closing a solo lane's only pane took its endpoint AND its workspace"

OUT=$(run_spawn solo-lane --relaunch) \
  || fail "REGRESSION: a lane whose workspace was deleted with its last pane must still relaunch, not be stranded: $OUT"
SOLO_NEW_WS=$(meta_get solo-lane herdr_workspace_id)
SOLO_NEW_PANE=$(meta_get solo-lane herdr_pane_id)
[ -n "$SOLO_NEW_WS" ] && [ "$SOLO_NEW_WS" != "$WS_SOLO" ] \
  || fail "the replacement must land in a workspace that actually exists, not the deleted one"
[ "$(fm_backend_herdr_workspace_presence_state "$SESSION" "$SOLO_NEW_WS")" = present ] \
  || fail "the replacement workspace must exist in the recorded session"
[ "$(meta_get solo-lane herdr_session)" = "$SESSION" ] \
  || fail "the replacement must stay in the RECORDED session"
[ "$(meta_get solo-lane worktree)" = "$SOLO_WT" ] \
  || fail "the replacement must be rooted in the same recorded worktree"
lab pane get "$SOLO_NEW_PANE" >/dev/null 2>&1 \
  || fail "the replacement pane must exist"
[ "$(pane_cwd "$SOLO_NEW_PANE")" = "$SOLO_WT" ] \
  || fail "the replacement in the FRESH workspace must still be rooted in the recorded local copy on the backend"
[ "$(meta_get solo-lane window)" = "$SESSION:$SOLO_NEW_PANE" ] \
  || fail "the record must be republished with the new endpoint"
[ "$(meta_get solo-lane harness)" = "$LAB_HARNESS" ] \
  || fail "the replacement must keep the recorded harness"
[ "$(meta_get solo-lane yolo)" = on ] \
  || fail "the replacement must keep the recorded yolo posture"
pass "case 3b: a lane whose workspace was deleted with its last pane relaunches into a fresh workspace in the SAME session and the same worktree"

# --- case 3c: the refusals the fix must NOT relax ----------------------------
# Absence has to be PROVEN. A workspace whose presence cannot be read - which is
# what a stopped or unreachable session looks like - is `unknown`, and the
# relaunch refuses on it rather than guessing a container.
[ "$(fm_backend_herdr_workspace_presence_state fm-lab-no-such-session-here w1)" = unknown ] \
  || fail "an unreadable session must classify as unknown, never as a confirmed-gone workspace"
pass "case 3c: an unreadable workspace list reads unknown, which is what keeps the relaunch refusing instead of guessing"

# A missing local copy still refuses outright: the endpoint is replaceable, the
# work is not.
STRAND_PANE=$(make_lane stranded-lane "$WS_MAIN_CONTAINER" "")
lab pane close "$STRAND_PANE" >/dev/null 2>&1 || true
mv "$SCRATCH/wt-stranded-lane" "$SCRATCH/wt-stranded-lane.moved" \
  || fail "could not move the lane's local copy aside"
STRAND_META_BEFORE=$(cat "$STATE_DIR/stranded-lane.meta")
if OUT=$(run_spawn stranded-lane --relaunch); then
  fail "a relaunch must refuse when the recorded local copy is gone: $OUT"
fi
case "$OUT" in
  *"refusing to relaunch without the local copy"*) : ;;
  *) fail "the refusal should name the missing local copy, got: $OUT" ;;
esac
[ "$(cat "$STATE_DIR/stranded-lane.meta")" = "$STRAND_META_BEFORE" ] \
  || fail "a refused relaunch must leave the durable record byte-identical"
pass "case 3c: a relaunch whose recorded local copy is gone still refuses, and changes nothing"

cleanup_all
trap - EXIT
