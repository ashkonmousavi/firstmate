#!/usr/bin/env bash
# fm-crew-recovery-lib.sh - relaunch dead in-flight ship and scout workers.
#
# bin/fm-bootstrap.sh calls fm_crew_recovery_sweep from its network phase.
# That phase is when the deferred startup pass runs (bin/fm-startup-network.sh
# with FM_BOOTSTRAP_NETWORK=only). The sweep itself does not use the network.
# It is not part of the blocking session-start digest, and the digest's
# endpoint read stays a presence check.
#
# Scope is this home only. The sweep reads regular files in
# ${FM_STATE_OVERRIDE:-$FM_HOME/state} and no other directory. A symlink at
# that state path is not scanned. Meta symlinks are not read. Control is
# invoked with the same FM_HOME, through
# ${FM_CREW_RECOVERY_CONTROL:-<this-dir>/fm-control.sh} as
# `relaunch --note <text> --if-recoverable`. Control rechecks eligibility under
# its lifecycle lock. The sweep never calls teardown, never deletes a
# task record, and never removes a worktree.
#
# A task is relaunched only when every one of these is true:
#   - the meta basename passes fm_task_id_creation_valid (bin/fm-pr-lib.sh);
#   - kind is ship or scout (a secondmate is out of scope);
#   - the task carries no active lane-release marker (bin/fm-lane-release-lib.sh):
#     a released worker stopped on purpose and is left for acceptance or an
#     explicit relaunch;
#   - a recorded endpoint target exists (fm_backend_target_of_meta);
#   - fm_backend_agent_state prints dead or missing (alive, ambiguous,
#     unreadable, and unverified are left untouched);
#   - the task is not captain-held and fm-crew-state.sh attributes no run;
#   - the recorded worktree positively shows unlanded work.
# An absent status file does not block. A status symlink, or any status path
# that is not a readable regular file, blocks: the record cannot be trusted.
# A status event alone does not establish run ownership. Attributed active,
# parked, terminal, or unreadable runs stay with their existing lifecycle.
#
# Unlanded work is local and positive. It is shown when `git status
# --porcelain` is nonempty, or when HEAD is not an ancestor of any available
# ref for the selected base branch. The branch is meta base_branch when a
# local or origin ref exists, otherwise origin/HEAD's branch, then main or
# master. Both refs/heads/<name> and refs/remotes/origin/<name> are checked.
# A clean tree whose HEAD is contained in either ref is not unlanded.
# A clean tree with no resolvable base, an unborn HEAD,
# an unreadable worktree, a relative worktree path, or a symlink worktree is
# not proof, so it does not relaunch. This sweep does not fetch and does not
# ask the forge. A scout report outside the worktree is not unlanded work.
# The complete landed-work test stays in bin/fm-teardown.sh and is not called.
#
# Task attempts are serial. Spawn reads capacity afresh for each launch. The
# first failure or capacity deferral stops the sweep, leaving later tasks for
# the next pass. The sweep returns 0. Control exit 75 is reported as deferred;
# exit 3 silently skips a task that no longer qualifies. Silence means
# nothing qualified. A real attempt prints one CREW_RECOVERY line.
#
# Output:
#   CREW_RECOVERY: relaunched <id> after <dead|missing>
#   CREW_RECOVERY: <id>: relaunch failed after <state>: <first line>
#   CREW_RECOVERY: <id>: relaunch deferred after <state>: <first line>

# shellcheck disable=SC2034
FM_CREW_RECOVERY_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if ! command -v fm_backend_agent_state >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh disable=SC1091
  . "$FM_CREW_RECOVERY_LIB_DIR/fm-backend.sh"
fi

if ! command -v fm_task_id_creation_valid >/dev/null 2>&1; then
  # shellcheck source=bin/fm-pr-lib.sh disable=SC1091
  . "$FM_CREW_RECOVERY_LIB_DIR/fm-pr-lib.sh"
fi

if ! command -v fm_lane_release_marker_active >/dev/null 2>&1; then
  # shellcheck source=bin/fm-lane-release-lib.sh disable=SC1091
  . "$FM_CREW_RECOVERY_LIB_DIR/fm-lane-release-lib.sh"
fi

fm_crew_recovery_need_classify() {
  command -v last_status_line >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-classify-lib.sh disable=SC1091
  . "$FM_CREW_RECOVERY_LIB_DIR/fm-classify-lib.sh"
}

# 0 when the latest record blocks relaunch, including an unreadable record.
# 1 when the task stays eligible (including no status file).
fm_crew_recovery_record_blocks() {  # <state-dir> <id>
  local state=$1 id=$2 status line reconciled
  status="$state/$id.status"
  if [ -L "$status" ]; then
    return 0
  fi
  if [ -e "$status" ]; then
    [ -f "$status" ] && [ -r "$status" ] || return 0
    fm_crew_recovery_need_classify || return 0
    line=$(last_status_line "$status") || return 0
    [ "$(status_line_verb "$line")" != captain-held ] || return 0
  fi
  reconciled=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_KEEP_RUN=1 FM_CREW_STATE_NO_FORGE=1 \
    "$FM_CREW_RECOVERY_LIB_DIR/fm-crew-state.sh" "$id") || return 0
  case "$reconciled" in
    'state: '*' · source: run-step'*) return 0 ;;
    'state: '*' · source: '*) ;;
    *) return 0 ;;
  esac
  return 1
}

fm_crew_recovery_base_refs() {  # <worktree> <base-branch-name>
  local wt=$1 name=$2 ref found=0
  case "$name" in
    ''|-*|*..*|*[[:space:]]*|*:*) name='' ;;
  esac
  if [ -n "$name" ]; then
    if ! git -C "$wt" show-ref --verify --quiet "refs/heads/$name" >/dev/null 2>&1 \
      && ! git -C "$wt" show-ref --verify --quiet "refs/remotes/origin/$name" >/dev/null 2>&1; then
      name=''
    fi
  fi
  if [ -z "$name" ] && git -C "$wt" rev-parse --verify --quiet refs/remotes/origin/HEAD >/dev/null 2>&1; then
    ref=$(git -C "$wt" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) || ref=''
    case "$ref" in
      refs/remotes/origin/*) name=${ref#refs/remotes/origin/} ;;
      *) printf '%s\n' refs/remotes/origin/HEAD; return 0 ;;
    esac
  fi
  if [ -z "$name" ]; then
    for name in main master; do
      if git -C "$wt" show-ref --verify --quiet "refs/heads/$name" >/dev/null 2>&1 \
        || git -C "$wt" show-ref --verify --quiet "refs/remotes/origin/$name" >/dev/null 2>&1; then
        break
      fi
    done
  fi
  for ref in "refs/heads/$name" "refs/remotes/origin/$name"; do
    if git -C "$wt" show-ref --verify --quiet "$ref" >/dev/null 2>&1; then
      printf '%s\n' "$ref"
      found=1
    fi
  done
  [ "$found" -eq 1 ]
}

# 0 when this worktree positively shows unlanded work.
fm_crew_recovery_unlanded_proven() {  # <worktree> <base-branch-name>
  local wt=$1 base_name=$2 top top_p wt_p porcelain bases base rc
  case "$wt" in
    /*) ;;
    *) return 1 ;;
  esac
  if [ -L "$wt" ] || [ ! -d "$wt" ]; then
    return 1
  fi
  top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || return 1
  top_p=$(cd -- "$top" && pwd -P) || return 1
  wt_p=$(cd -- "$wt" && pwd -P) || return 1
  [ "$top_p" = "$wt_p" ] || return 1
  porcelain=$(git -C "$wt" status --porcelain 2>/dev/null) || return 1
  if [ -n "$porcelain" ]; then
    return 0
  fi
  git -C "$wt" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || return 1
  bases=$(fm_crew_recovery_base_refs "$wt" "$base_name") || return 1
  [ -n "$bases" ] || return 1
  while IFS= read -r base; do
    rc=0
    git -C "$wt" merge-base --is-ancestor HEAD "$base" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      1) ;;
      *) return 1 ;;
    esac
  done <<< "$bases"
  return 0
}

fm_crew_recovery_detail() {  # <output> <fallback>
  local line
  line=$(printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p')
  [ -n "$line" ] || line=$2
  if [ "${#line}" -gt 240 ]; then
    line=${line:0:240}
  fi
  printf '%s' "$line"
}

fm_crew_recovery_one() {  # <id> <agent-state>
  local id=$1 agent_state=$2 control note out rc detail
  control=${FM_CREW_RECOVERY_CONTROL:-$FM_CREW_RECOVERY_LIB_DIR/fm-control.sh}
  if [ ! -x "$control" ]; then
    printf 'CREW_RECOVERY: %s: relaunch failed after %s: control program is not executable\n' \
      "$id" "$agent_state"
    return 1
  fi
  note="Startup recovery relaunched this task because its agent was dead (endpoint state: ${agent_state}) and the recorded local copy still holds unlanded work. Continue from that copy. Nothing was torn down or discarded."
  out=$(FM_HOME="$FM_HOME" "$control" "$id" relaunch --note "$note" --if-recoverable 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 3 ] || return 0
  if [ "$rc" -eq 0 ]; then
    printf 'CREW_RECOVERY: relaunched %s after %s\n' "$id" "$agent_state"
  else
    detail=$(fm_crew_recovery_detail "$out" "exit $rc")
    if [ "$rc" -eq 75 ]; then
      printf 'CREW_RECOVERY: %s: relaunch deferred after %s: %s\n' "$id" "$agent_state" "$detail"
    else
      printf 'CREW_RECOVERY: %s: relaunch failed after %s: %s\n' "$id" "$agent_state" "$detail"
    fi
  fi
  return "$rc"
}

fm_crew_recovery_agent_state() {
  local state=$1 id=$2 meta kind target backend agent_state wt base_name
  [ ! -L "$state" ] && [ -d "$state" ] || return 1
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  kind=$(fm_meta_get "$meta" kind)
  case "$kind" in
    ship|scout) ;;
    *) return 1 ;;
  esac
  fm_lane_release_marker_active "$state" "$id" && return 1
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 1
  backend=$(fm_backend_of_meta "$meta")
  agent_state=$(fm_backend_agent_state "$backend" "$target") || agent_state=unreadable
  case "$agent_state" in
    dead|missing) ;;
    *) return 1 ;;
  esac
  fm_crew_recovery_record_blocks "$state" "$id" && return 1
  wt=$(fm_meta_get "$meta" worktree)
  base_name=$(fm_meta_get "$meta" base_branch)
  fm_crew_recovery_unlanded_proven "$wt" "$base_name" || return 1
  printf '%s\n' "$agent_state"
}

fm_crew_recovery_sweep() {
  local home state meta id agent_state
  home=${FM_HOME:-}
  [ -n "$home" ] || return 0
  state=${FM_STATE_OVERRIDE:-$home/state}
  if [ -L "$state" ] || [ ! -d "$state" ]; then
    return 0
  fi
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    [ -L "$meta" ] && continue
    id=$(basename -- "$meta" .meta)
    fm_task_id_creation_valid "$id" || continue
    agent_state=$(fm_crew_recovery_agent_state "$state" "$id") || continue
    fm_crew_recovery_one "$id" "$agent_state" || break
  done
  return 0
}
