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
# `relaunch --note <text>`. The sweep never calls teardown, never deletes a
# task record, and never removes a worktree.
#
# A task is relaunched only when every one of these is true:
#   - the meta basename is a path-safe task id of at most 64 characters, the
#     same acceptance as fm_task_id_creation_valid in bin/fm-pr-lib.sh (that
#     library is not sourced here);
#   - kind is ship or scout (a secondmate is out of scope);
#   - a recorded endpoint target exists (fm_backend_target_of_meta);
#   - fm_backend_agent_state prints dead or missing (alive, ambiguous,
#     unreadable, and unverified are left untouched);
#   - the latest status event is not done, failed, captain-held, or the
#     literal verb paused-by-captain;
#   - the recorded worktree positively shows unlanded work.
# An absent status file does not block. A status symlink, or any status path
# that is not a readable regular file, blocks: the record cannot be trusted.
# Worker paused, needs-decision, blocked, and working stay eligible.
# `failed` is not an in-flight record: a dead failed task whose tree is
# still dirty would otherwise be relaunched on every startup.
# captain-held is the durable hold record. The literal verb
# paused-by-captain is honored as well. There is no status verb spelled
# paused-by-captain in bin/fm-classify-lib.sh.
#
# Unlanded work is local and positive. It is shown when `git status
# --porcelain` is nonempty, or when HEAD is not an ancestor of the resolved
# base ref. The base ref is meta base_branch when refs/heads/<name> or
# refs/remotes/origin/<name> exists, otherwise refs/remotes/origin/HEAD, then
# refs/heads/main, refs/heads/master, refs/remotes/origin/main, and
# refs/remotes/origin/master. A clean tree whose HEAD is contained in that
# base is not unlanded. A clean tree with no resolvable base, an unborn HEAD,
# an unreadable worktree, a relative worktree path, or a symlink worktree is
# not proof, so it does not relaunch. This sweep does not fetch and does not
# ask the forge. A scout report outside the worktree is not unlanded work.
# The complete landed-work test stays in bin/fm-teardown.sh and is not called.
#
# One task failure does not stop the next task, and the sweep itself returns
# 0. Control exit 75 is reported as deferred. A busy per-task lock
# (state/.crew-recovery-<id>.lock) skips that task with a line. Silence means
# nothing qualified. A real attempt prints one CREW_RECOVERY line.
#
# Output:
#   CREW_RECOVERY: relaunched <id> after <dead|missing>
#   CREW_RECOVERY: <id>: relaunch failed after <state>: <first line>
#   CREW_RECOVERY: <id>: relaunch deferred after <state>: <first line>
#   CREW_RECOVERY: <id>: skipped: another recovery already holds this task

# shellcheck disable=SC2034
FM_CREW_RECOVERY_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if ! command -v fm_backend_agent_state >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh disable=SC1091
  . "$FM_CREW_RECOVERY_LIB_DIR/fm-backend.sh"
fi

# Same acceptance as bin/fm-pr-lib.sh fm_task_id_creation_valid.
fm_crew_recovery_id_ok() {  # <id>
  local id=$1
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ]
}

fm_crew_recovery_need_classify() {
  command -v last_status_line >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-classify-lib.sh disable=SC1091
  . "$FM_CREW_RECOVERY_LIB_DIR/fm-classify-lib.sh"
}

fm_crew_recovery_need_locks() {
  command -v fm_lock_try_acquire >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$FM_CREW_RECOVERY_LIB_DIR/fm-wake-lib.sh"
}

# 0 when the latest record blocks relaunch, including an unreadable record.
# 1 when the task stays eligible (including no status file).
fm_crew_recovery_record_blocks() {  # <status-path>
  local status=$1 line verb
  if [ -L "$status" ]; then
    return 0
  fi
  if [ ! -e "$status" ]; then
    return 1
  fi
  if [ ! -f "$status" ] || [ ! -r "$status" ]; then
    return 0
  fi
  fm_crew_recovery_need_classify || return 0
  line=$(last_status_line "$status") || return 0
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|failed|captain-held|paused-by-captain) return 0 ;;
  esac
  return 1
}

fm_crew_recovery_base_ref() {  # <worktree> <base-branch-name>
  local wt=$1 name=$2 ref
  case "$name" in
    ''|-*|*..*|*[[:space:]]*|*:*) name='' ;;
  esac
  if [ -n "$name" ]; then
    if git -C "$wt" show-ref --verify --quiet "refs/heads/$name" >/dev/null 2>&1; then
      printf '%s\n' "refs/heads/$name"
      return 0
    fi
    if git -C "$wt" show-ref --verify --quiet "refs/remotes/origin/$name" >/dev/null 2>&1; then
      printf '%s\n' "refs/remotes/origin/$name"
      return 0
    fi
  fi
  if git -C "$wt" rev-parse --verify --quiet refs/remotes/origin/HEAD >/dev/null 2>&1; then
    printf '%s\n' refs/remotes/origin/HEAD
    return 0
  fi
  for ref in refs/heads/main refs/heads/master refs/remotes/origin/main refs/remotes/origin/master; do
    if git -C "$wt" show-ref --verify --quiet "$ref" >/dev/null 2>&1; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  return 1
}

# 0 when this worktree positively shows unlanded work.
fm_crew_recovery_unlanded_proven() {  # <worktree> <base-branch-name>
  local wt=$1 base_name=$2 top top_p wt_p porcelain base rc
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
  base=$(fm_crew_recovery_base_ref "$wt" "$base_name") || return 1
  [ -n "$base" ] || return 1
  rc=0
  git -C "$wt" merge-base --is-ancestor HEAD "$base" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 1 ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
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

fm_crew_recovery_one() {  # <state-dir> <id> <agent-state>
  local state=$1 id=$2 agent_state=$3 control lock note out rc detail
  lock="$state/.crew-recovery-$id.lock"
  fm_crew_recovery_need_locks || {
    printf 'CREW_RECOVERY: %s: relaunch failed after %s: recovery lock helpers are unavailable\n' \
      "$id" "$agent_state"
    return 0
  }
  if ! fm_lock_try_acquire "$lock"; then
    printf 'CREW_RECOVERY: %s: skipped: another recovery already holds this task\n' "$id"
    return 0
  fi
  control=${FM_CREW_RECOVERY_CONTROL:-$FM_CREW_RECOVERY_LIB_DIR/fm-control.sh}
  if [ ! -x "$control" ]; then
    printf 'CREW_RECOVERY: %s: relaunch failed after %s: control program is not executable\n' \
      "$id" "$agent_state"
    fm_lock_release "$lock" 2>/dev/null || true
    return 0
  fi
  note="Startup recovery relaunched this task because its agent was dead (endpoint state: ${agent_state}) and the recorded local copy still holds unlanded work. Continue from that copy. Nothing was torn down or discarded."
  out=$(FM_HOME="$FM_HOME" "$control" "$id" relaunch --note "$note" 2>&1) && rc=0 || rc=$?
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
  fm_lock_release "$lock" 2>/dev/null || true
  return 0
}

fm_crew_recovery_sweep() {
  local home state meta id kind target backend agent_state wt base_name
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
    fm_crew_recovery_id_ok "$id" || continue
    kind=$(fm_meta_get "$meta" kind)
    case "$kind" in
      ship|scout) ;;
      *) continue ;;
    esac
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    agent_state=$(fm_backend_agent_state "$backend" "$target") || agent_state=unreadable
    case "$agent_state" in
      dead|missing) ;;
      *) continue ;;
    esac
    fm_crew_recovery_record_blocks "$state/$id.status" && continue
    wt=$(fm_meta_get "$meta" worktree)
    base_name=$(fm_meta_get "$meta" base_branch)
    fm_crew_recovery_unlanded_proven "$wt" "$base_name" || continue
    fm_crew_recovery_one "$state" "$id" "$agent_state"
  done
  return 0
}
