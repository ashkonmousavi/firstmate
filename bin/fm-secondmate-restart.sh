#!/usr/bin/env bash
# Restart second mates onto the current instruction surface and launch-time
# wiring, persisting their open records first.
#
# Usage: fm-secondmate-restart.sh <secondmate-id>... [--help]
#
# This is the executable half of /updatefirstmate's reload step. A running agent
# holds AGENTS.md and every skill it has loaded frozen from launch, and no
# verified harness offers a reload, so a re-read steer cannot replace either -
# it appends a second copy of the mate's own job description with no defined
# precedence. Replacing the agent is the only mechanism that guarantees the new
# bytes are the ones read, and the only one that re-resolves the launch-time
# wiring - harness, model, effort, turn-end hooks, and every other flag a harness
# reads once at startup. That second half is why the update pass sends every live
# mate here, including one already on the target commit: launch-time wiring is
# not derivable from a git diff, so an unchanged tracked surface does not mean
# the running agent is already on the current behavior.
#
# The cost of that guarantee is the conversation, which is why this command runs
# in two phases and why the first one is a GATE, not a courtesy:
#
#   A. PERSIST. Every mate is asked, in one marked request, to durably record the
#      open work it holds only in conversation - a task for each unfiled open
#      record, including a captain call it formed but never registered, and a
#      status correction for each task whose recorded state is now stale. That is
#      the /stow skill's "Open-record persistence" contract and nothing else from
#      it: no memory, learnings, or captain-preference sweep, which would make
#      every instruction update cost far more than the reload it is paying for.
#      All requests go out before any restart, so a slow mate delays only its own
#      restart instead of serializing the fleet behind it.
#   B. RESTART. Only after that mate's own correlated answer lands on the parent
#      channel. The gate is that answer, never a wall clock, so a mate that is
#      mid-turn queues the request behind that turn; the bound below exists to
#      end the wait, not to authorize a restart without the answer. A timeout
#      deliberately leaves that unanswered expectation open: it is a genuine
#      open loop owned by the ordinary pending-reply recovery ladder, not state
#      this restart pass may close.
#
# Background shells. A Claude agent asked to exit while one of its background
# shells runs stops on its "Background work is running" exit picker instead of
# exiting. The persist request therefore also asks the mate to stop its own
# shells, and before the relaunch a Claude mate's screen is read through its
# placement's own route (the backend locally, fm-remote-secondmate-control.sh
# capture remotely) and the restart waits, bounded, while it still reports
# running shells. The wait never blocks the restart: the control plane's exit
# still meets any picker that opens. If a relaunch is nevertheless refused on
# that picker with no confirming Enter sent (a control plane that predates
# answering it), this pass presses one Enter itself, and only when the
# recognised picker lists nothing but background shells
# (bin/fm-composer-lib.sh fm_composer_exit_picker_shells_only); it then
# proves the old agent stopped and relaunches once. Any other picker, any
# other refusal, and a picker that survives that Enter are reported as before.
#
# A mate whose persist answer did not arrive or whose runtime cannot prove a
# restart gets the ordinary re-read nudge and is reported as a nudge, never as a
# clean reload. Once a relaunch is attempted, any failed or ambiguous result is
# reported as unknown rather than attributing it to either incarnation.
#
# Placement changes the transport and nothing else. A local mate is restarted
# with bin/fm-control.sh <id> relaunch, which republishes this home's own
# metadata directly; a remote mate is restarted with
# bin/fm-remote-secondmate-relaunch.sh, which runs that same command on its
# host over bin/fm-on.sh and then republishes this primary's own route
# metadata from the identity the host confirmed, since the host-local verb can
# only rewrite its own endpoint record. The restart decision, the profile, the
# request text, the bound, the failure vocabulary, and this report are all
# computed here in the primary and are identical for both.
#
# Nothing here forces, stashes, or discards anything. bin/fm-control.sh owns the
# restart transaction, its checkpoint, its journal, and its rollback; a refusal
# before the agent is stopped leaves the mate running exactly as it was.
#
# Restart candidacy itself belongs to bin/fm-update.sh, which knows which homes
# the update pass actually left on the target commit; this command re-checks
# capability on its own argv rather than trusting a caller's list.
#
# Environment knobs:
#   FM_SECONDMATE_PERSIST_WAIT  seconds to wait for one mate's persist answer (900)
#   FM_SECONDMATE_PERSIST_POLL  seconds between checks of that answer, and of a
#                               Claude mate's background shells (5)
#   FM_SECONDMATE_BG_SHELL_WAIT seconds to wait for a Claude mate's background
#                               shells to stop before relaunching it anyway (120)
#
# Exit status: 0 every named mate restarted; 3 at least one was nudged or left
# unreached and every mate was still accounted for; 1 the input itself is
# unusable; 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,/^[^#]/{/^#/{s/^# \{0,1\}//;p;};}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-secondmate-restart refuses to resolve second mates without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing; fm-secondmate-restart cannot resolve second mates for FM_HOME '$FM_HOME'" >&2; exit 1; }

# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"
# shellcheck source=bin/fm-secondmate-nudge-lib.sh
. "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"
# shellcheck source=bin/fm-notice-id-lib.sh
. "$SCRIPT_DIR/fm-notice-id-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$SCRIPT_DIR/fm-composer-lib.sh"

PERSIST_WAIT=${FM_SECONDMATE_PERSIST_WAIT:-900}
PERSIST_POLL=${FM_SECONDMATE_PERSIST_POLL:-5}
BG_SHELL_WAIT=${FM_SECONDMATE_BG_SHELL_WAIT:-120}
case "$PERSIST_WAIT" in ''|*[!0-9]*) echo "error: FM_SECONDMATE_PERSIST_WAIT must be a non-negative integer: $PERSIST_WAIT" >&2; exit 2 ;; esac
case "$PERSIST_POLL" in ''|*[!0-9]*|0) echo "error: FM_SECONDMATE_PERSIST_POLL must be a positive integer: $PERSIST_POLL" >&2; exit 2 ;; esac
case "$BG_SHELL_WAIT" in ''|*[!0-9]*) echo "error: FM_SECONDMATE_BG_SHELL_WAIT must be a non-negative integer: $BG_SHELL_WAIT" >&2; exit 2 ;; esac

IDS=()
for arg in "$@"; do
  case "$arg" in
    -*) echo "error: unexpected argument '$arg'" >&2; usage >&2; exit 2 ;;
  esac
  # /updatefirstmate's action line names each mate by its fm-<id> selector; the
  # bare id is equally acceptable so a hand-run stays natural.
  id=${arg#fm-}
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $arg" >&2; exit 2 ;; esac
  case " ${IDS[*]:-} " in
    *" $id "*) continue ;;
  esac
  IDS+=("$id")
done
[ "${#IDS[@]}" -gt 0 ] || { usage >&2; exit 2; }

# Per-mate pass state, kept as parallel indexed arrays so this stays bash-3.2
# safe. PLAN is the phase the mate reached: persist-sent, or fallback with the
# reason already decided.
PLAN=()
REASON=()
CORR=()
DEADLINE=()
PLACEMENT=()
HOST=()
HARNESS=()
RUNNING_HARNESS=()
MODEL=()
EFFORT=()
RESTART_PID=()
RESTART_RESULT=()

restarted_count=0
nudged_count=0
unreached_count=0

# The first line of a command's output that carries anything, flattened to one
# readable line with its "error: " prefix dropped. A refusal's own words are the
# most useful thing this report can carry, and its first line is often blank.
first_reported_line() {  # <text>
  printf '%s\n' "$1" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}'
}

# Send the ordinary re-read steer to a mate this pass will not restart, and say
# plainly which it was. A nudge is a partial reload and is never reported as more.
fall_back_to_nudge() {  # <id> <reason>
  local id=$1 reason=$2 out delivery_id
  delivery_id=$(fm_notice_delivery_id "restart-fallback:$id:$reason:$(date +%s%N):$RANDOM") || return 1
  if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-send.sh" "$id" --fire-and-forget "$delivery_id" "$FM_SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
    nudged_count=$((nudged_count + 1))
    printf 'nudged: %s: %s\n' "$id" "$reason"
  else
    unreached_count=$((unreached_count + 1))
    printf 'unreached: %s: %s; the re-read message could not be delivered either: %s\n' \
      "$id" "$reason" "$(first_reported_line "$out")"
  fi
}

report_unreached() {  # <id> <reason>
  unreached_count=$((unreached_count + 1))
  printf 'unreached: %s: %s\n' "$1" "$2"
}

# The refusal a control plane prints when it met the Claude exit picker and
# typed nothing into it. A control plane that already pressed Enter says the
# Enter did not clear it instead, and any other text earns no press here.
UNANSWERED_PICKER_REFUSAL='is blocked on a prompt: Claude background-task exit picker. Refusing to type Enter into it.'

# The mate's current screen, read through the route its placement uses for
# everything else: the viewport locally, so nothing scrolled away is read as
# the live screen, and the host's bounded capture remotely. Returns 1 when it
# cannot be read.
mate_screen() {  # <array-index>
  local i=$1 id
  id=${IDS[$i]}
  if [ "${PLACEMENT[i]}" = remote ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-on.sh" "$id" \
      fm-remote-secondmate-control.sh capture "$id" 60 < /dev/null 2>/dev/null
    return
  fi
  fm_backend_validate_task_endpoint "$STATE/$id.meta" "$id" 2>/dev/null || return 1
  fm_backend_visible_capture "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET" "fm-$id" 2>/dev/null
}

# The mate's recovery-grade agent state, through the same route.
mate_agent_state() {  # <array-index>
  local i=$1 id
  id=${IDS[$i]}
  if [ "${PLACEMENT[i]}" = remote ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-on.sh" "$id" \
      fm-remote-secondmate-control.sh state "$id" < /dev/null 2>/dev/null | tail -1
    return
  fi
  fm_backend_validate_task_endpoint "$STATE/$id.meta" "$id" 2>/dev/null || { printf 'unreadable'; return; }
  fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET" 2>/dev/null
}

# Wait, bounded, while a Claude mate's screen still reports running background
# shells. Prints `running` when they outlast the bound and nothing otherwise;
# an unreadable screen ends the wait without a verdict. The relaunch follows
# either way, because the control plane's exit still meets any picker.
wait_out_background_shells() {  # <array-index>
  local i=$1 deadline screen
  [ "${RUNNING_HARNESS[i]}" = claude ] || return 0
  deadline=$(($(date +%s) + BG_SHELL_WAIT))
  while screen=$(mate_screen "$i") \
    && fm_composer_claude_background_shells "$screen" >/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf 'running'
      return 0
    fi
    sleep "$PERSIST_POLL"
  done
}

# A relaunch refused on the Claude exit picker with no Enter typed into it:
# press one Enter only when the recognised picker lists nothing but background
# shells, then wait for the old agent to read dead. Returns 0 only with that
# proof; prints why it did not act otherwise.
answer_shells_only_picker() {  # <array-index> <relaunch-output>
  local i=$1 out=$2 id screen deadline state send_out
  id=${IDS[$i]}
  case "$out" in *"$UNANSWERED_PICKER_REFUSAL"*) ;; *) return 1 ;; esac
  screen=$(mate_screen "$i") || { printf 'its screen could not be read to check the exit picker'; return 1; }
  if ! fm_composer_exit_picker_shells_only "$screen"; then
    printf 'its exit picker is not shown with only background shells listed, so it was left unanswered'
    return 1
  fi
  if ! send_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-send.sh" "$id" --key Enter < /dev/null 2>&1); then
    printf 'the Enter for its shells-only exit picker could not be delivered: %s' "$(first_reported_line "$send_out")"
    return 1
  fi
  deadline=$(($(date +%s) + BG_SHELL_WAIT))
  while state=$(mate_agent_state "$i") && [ "$state" != dead ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf 'one Enter was pressed on its shells-only exit picker, but the agent still reads %s; nothing more was typed' "${state:-unreadable}"
      return 1
    fi
    sleep "$PERSIST_POLL"
  done
  [ "$state" = dead ] && return 0
  printf 'one Enter was pressed on its shells-only exit picker, but its agent state could not be read; nothing more was typed'
  return 1
}

run_relaunch() {  # <array-index>; sets restart_out and restart_rc
  local i=$1 id
  id=${IDS[$i]}
  if [ "${PLACEMENT[i]}" = remote ]; then
    restart_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-remote-secondmate-relaunch.sh" \
      "$id" "${HARNESS[i]}" "${MODEL[i]:-default}" "${EFFORT[i]:-default}" < /dev/null 2>&1)
    restart_rc=$?
  else
    restart_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-control.sh" "$id" relaunch 2>&1)
    restart_rc=$?
  fi
}

restart_mate() {  # <array-index>
  local i=$1 id restart_out restart_rc restart_reason ran_on shells note picker_reason
  id=${IDS[$i]}
  note=
  shells=$(wait_out_background_shells "$i")
  [ "$shells" != running ] \
    || note="; its background shells were still running after ${BG_SHELL_WAIT}s, so they stopped with the old agent"
  run_relaunch "$i"
  if [ "$restart_rc" -ne 0 ] && [ "${RUNNING_HARNESS[i]}" = claude ]; then
    if picker_reason=$(answer_shells_only_picker "$i" "$restart_out"); then
      note="; its exit picker listed only its own background shells, so this restart confirmed it once"
      run_relaunch "$i"
    elif [ -n "$picker_reason" ]; then
      restart_out="$(first_reported_line "$restart_out"); $picker_reason"
    fi
  fi
  if [ "$restart_rc" -eq 0 ]; then
    ran_on=$(printf '%s\n' "$restart_out" | sed -n 's/^relaunched .* harness=\([^ ]*\).*/\1/p' | tail -1)
    [ -n "$ran_on" ] || ran_on=${HARNESS[i]}
    if [ "${PLACEMENT[i]}" = remote ]; then
      printf 'restarted: %s on %s (%s)%s\n' "$id" "${HOST[i]}" "$ran_on" "$note"
    else
      printf 'restarted: %s (%s)%s\n' "$id" "$ran_on" "$note"
    fi
    return
  fi

  restart_reason=$(first_reported_line "$restart_out")
  [ -n "$restart_reason" ] || restart_reason="the restart failed without a reported reason"
  report_unreached "$id" "the restart outcome is unknown: $restart_reason"
}

launch_restart() {  # <array-index>
  local i=$1 result tmp
  result="$RESULT_DIR/$i.result"
  tmp="$result.tmp"
  ( trap - EXIT; restart_mate "$i" > "$tmp"; mv -f "$tmp" "$result" ) &
  RESTART_PID[i]=$!
  RESTART_RESULT[i]=$result
  PLAN[i]=restarting
  restart_active_count=$((restart_active_count + 1))
}

harvest_restarts() {
  local i out worker_state
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" != restarting ]; then
      i=$((i + 1))
      continue
    fi
    if [ -f "${RESTART_RESULT[i]}" ]; then
      wait "${RESTART_PID[i]}" 2>/dev/null || true
      out=$(cat "${RESTART_RESULT[i]}")
    else
      if kill -0 "${RESTART_PID[i]}" 2>/dev/null; then
        worker_state=$(ps -p "${RESTART_PID[i]}" -o stat= 2>/dev/null || true)
        case "$worker_state" in
          Z*) ;;
          *)
            i=$((i + 1))
            continue
            ;;
        esac
      fi
      wait "${RESTART_PID[i]}" 2>/dev/null || true
      if [ -f "${RESTART_RESULT[i]}" ]; then
        out=$(cat "${RESTART_RESULT[i]}")
      else
        out="unreached: ${IDS[$i]}: the restart worker exited before publishing an outcome"
      fi
    fi
    printf '%s\n' "$out"
    case "$out" in
      restarted:*) restarted_count=$((restarted_count + 1)) ;;
      nudged:*) nudged_count=$((nudged_count + 1)) ;;
      *) unreached_count=$((unreached_count + 1)) ;;
    esac
    PLAN[i]="done"
    restart_active_count=$((restart_active_count - 1))
    i=$((i + 1))
  done
}

# --- phase A: persist ------------------------------------------------------
# Every request goes out before any restart, so the fleet persists concurrently
# and one busy mate delays only itself.

i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  id=${IDS[$i]}
  PLAN[i]="fallback"
  REASON[i]=""
  CORR[i]=""
  DEADLINE[i]=""
  PLACEMENT[i]=""
  HOST[i]=""
  HARNESS[i]=""
  RUNNING_HARNESS[i]=""
  MODEL[i]=""
  EFFORT[i]=""
  if ! fm_secondmate_restart_capable "$STATE/$id.meta"; then
    REASON[i]=$FM_SECONDMATE_RESTART_REASON
    i=$((i + 1))
    continue
  fi
  PLACEMENT[i]=$FM_SECONDMATE_RESTART_PLACEMENT
  HOST[i]=$FM_SECONDMATE_RESTART_HOST
  HARNESS[i]=$FM_SECONDMATE_RESTART_HARNESS
  RUNNING_HARNESS[i]=$FM_SECONDMATE_RESTART_HARNESS
  if [ "${PLACEMENT[i]}" = remote ]; then
    # A local relaunch re-resolves this home's durable secondmate pin on its own,
    # which is the one owner of that resolution. A remote one cannot: it runs in
    # a home whose config/secondmate-harness is deliberately NOT inherited, so
    # the file on that host belongs to a different home and re-resolving there
    # would silently move the mate onto another runtime. Resolve the pin here and
    # pass it explicitly, so both placements land on the same decision.
    HARNESS[i]=$("$SCRIPT_DIR/fm-harness.sh" secondmate 2>/dev/null || true)
    [ -n "${HARNESS[i]}" ] || HARNESS[i]=$FM_SECONDMATE_RESTART_HARNESS
    MODEL[i]=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model 2>/dev/null || true)
    EFFORT[i]=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort 2>/dev/null || true)
    case "${EFFORT[i]}" in
      ''|low|medium|high|xhigh|max|ultra) ;;
      *) EFFORT[i]="" ;;
    esac
    if [ "${EFFORT[i]}" = ultra ] && ! "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "${HARNESS[i]}" "${MODEL[i]}" "${EFFORT[i]}"; then
      REASON[i]="the configured Ultra profile does not select native Codex through Pi"
      i=$((i + 1))
      continue
    fi
  fi

  if ! corr=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$id" \
    "$FM_SECONDMATE_PERSIST_REQUEST"); then
    REASON[i]="its answer about the open work cannot be tracked, so a clean reload could not be proven"
    i=$((i + 1))
    continue
  fi
  if ! send_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SCRIPT_DIR/fm-send.sh" "$id" "$FM_SECONDMATE_PERSIST_REQUEST" 2>&1); then
    fm_pending_reply_discard_undelivered "$STATE" "$corr" >/dev/null 2>&1 || true
    REASON[i]="the request to write down its open work could not be delivered: $(first_reported_line "$send_out")"
    i=$((i + 1))
    continue
  fi
  CORR[i]=$corr
  DEADLINE[i]=$(($(date +%s) + PERSIST_WAIT))
  PLAN[i]="persisted-pending"
  i=$((i + 1))
done

# --- phase B: restart ------------------------------------------------------

RESULT_DIR=$(mktemp -d "$STATE/.secondmate-restart.XXXXXX") || {
  echo "error: could not create restart result directory under $STATE" >&2
  exit 1
}
trap 'rm -rf -- "$RESULT_DIR"' EXIT
pending_count=0
restart_active_count=0
i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  if [ "${PLAN[i]}" = persisted-pending ]; then
    pending_count=$((pending_count + 1))
  else
    fall_back_to_nudge "${IDS[$i]}" "${REASON[i]}"
    PLAN[i]="done"
  fi
  i=$((i + 1))
done

while [ "$((pending_count + restart_active_count))" -gt 0 ]; do
  now=$(date +%s)
  next_wait=$PERSIST_POLL
  # Resolve every arrived answer before processing any timeout. Delivery of a
  # later fleet request can outlast an earlier mate's deadline under load; that
  # expired mate must not hold an already-confirmed mate behind its fallback.
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" = persisted-pending ] \
      && fm_pending_reply_try_resolve "$STATE" "${CORR[i]}"; then
      pending_count=$((pending_count - 1))
      launch_restart "$i"
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" != persisted-pending ]; then
      i=$((i + 1))
      continue
    fi
    if [ "$now" -ge "${DEADLINE[i]}" ]; then
      # A reply can land after the fleet-wide resolution pass. Recheck at the
      # timeout decision so an answer already on disk wins over the fallback.
      if fm_pending_reply_try_resolve "$STATE" "${CORR[i]}"; then
        pending_count=$((pending_count - 1))
        launch_restart "$i"
      else
        fall_back_to_nudge "${IDS[$i]}" \
          "it did not confirm within ${PERSIST_WAIT}s that its open work is written down, so its conversation was not spent"
        PLAN[i]="done"
        pending_count=$((pending_count - 1))
      fi
    else
      remaining=$((DEADLINE[i] - now))
      [ "$remaining" -ge "$next_wait" ] || next_wait=$remaining
    fi
    i=$((i + 1))
  done
  harvest_restarts
  [ "$((pending_count + restart_active_count))" -eq 0 ] || sleep "$next_wait"
done

# --- summary ---------------------------------------------------------------

printf 'summary: %d of %d restarted, %d nudged, %d unreached\n' \
  "$restarted_count" "${#IDS[@]}" "$nudged_count" "$unreached_count"
[ "$((nudged_count + unreached_count))" -eq 0 ] || exit 3
exit 0
