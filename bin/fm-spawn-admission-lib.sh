#!/usr/bin/env bash
# Shared read-only launch admission, used by spawn and pre-stop relaunch.
# Requires the capacity, backlog-transition and lease libraries.
# Callers supply spawn identity globals (ID, KIND, CONFIG, DATA, STATE,
# RELAUNCH, RELAUNCH_FROM_RELEASED); the released-copy hold exception remains
# owned by spawn. Backlog outputs retain the launch owner's transition context.
# These are observations, not reservations: spawn rechecks after the stop.

fm_spawn_capacity_admit() { # <home> <config> <state> <id> <kind>
  [ "$5" != secondmate ] || return 0
  if ! fm_capacity_read "$1" "$2" "$3" "$4"; then
    echo "deferred: $FM_CAPACITY_ERROR; task $4 stays queued" >&2
    return 75
  fi
}

fm_spawn_backlog_admit() {
  # shellcheck disable=SC2034 # Output context consumed by spawn at publication.
  BACKLOG_TRANSITION=0
  BACKLOG_ROW_STATE=
  if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
    # shellcheck disable=SC2034 # Output context consumed by spawn at publication.
    BACKLOG_TRANSITION=1
    if fm_backlog_row_probe "$DATA" "$ID"; then
      BACKLOG_ROW_STATE=$FM_BACKLOG_ROW_STATE
    elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      echo "error: task $ID has no backlog item in this home, so dispatching it would leave a worker no record owns; add it first (bin/fm-tasks-axi.sh add $ID '<title>' --kind $KIND) and re-run" >&2
      return 1
    else
      echo "error: task $ID's backlog item could not be read before dispatch ($FM_BACKLOG_ROW_ERROR)" >&2
      return 75
    fi
    spawn_preflight_actor=$(fm_lease_actor) || return "$FM_LEASE_REFUSE_EXIT"
    if [ "$RELAUNCH" -ne 1 ] && [ "$spawn_preflight_actor" = branch ] && fm_lease_away_relocated; then
      if [ "$BACKLOG_ROW_STATE" != "queued no no" ]; then
        echo "error: spawn refused - the supervision branch under the away-posture record may dispatch only queued unblocked work (already queued, or filed by the branch from the captain's away words); task $ID has no dispatchable backlog item in this home" >&2
        [ "${BACKLOG_ROW_STATE%% *}" != queued ] || return 75
        return 1
      fi
    elif [ "$RELAUNCH_FROM_RELEASED" = 1 ] && released_backlog_hold_is_teardown_own; then
      # Lifted only at the commit point below, once the worker is launched, so
      # every refusal before then leaves the item held exactly as teardown left it.
      # shellcheck disable=SC2034 # Spawn lifts the released-copy hold at commit.
      RELEASED_LIFT_HOLD=1
    elif ! fm_backlog_row_dispatchable "$BACKLOG_ROW_STATE"; then
      echo "error: this home's backlog item $ID is not dispatchable in state $BACKLOG_ROW_STATE; refusing before creating its endpoint or local copy" >&2
      [ "$RELAUNCH" -ne 0 ] || [ "${BACKLOG_ROW_STATE%% *}" != queued ] || return 75
      return 1
    fi
  else
    BACKLOG_GATE_STATUS=$?
    if [ "$BACKLOG_GATE_STATUS" -eq 2 ]; then
      echo "error: task $ID cannot be dispatched because its backlog data directory is inaccessible: $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      return 1
    fi
  fi
  return 0
}
