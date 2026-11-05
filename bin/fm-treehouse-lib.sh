#!/usr/bin/env bash

FM_TREEHOUSE_VERSION=3.1.8

fm_treehouse_supports_lease() {
  local version major minor patch floor_major floor_minor floor_patch get_help return_help option
  version=$(treehouse --version 2>/dev/null) || return 1
  version=${version#v}
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r major minor patch <<< "$version"
  IFS=. read -r floor_major floor_minor floor_patch <<< "$FM_TREEHOUSE_VERSION"
  if ! (( major > floor_major || (major == floor_major && minor > floor_minor) ||
    (major == floor_major && minor == floor_minor && patch >= floor_patch) )); then
    return 1
  fi
  get_help=$(treehouse get --help 2>/dev/null) || return 1
  return_help=$(treehouse return --help 2>/dev/null) || return 1
  for option in lease lease-holder json; do
    printf '%s\n' "$get_help" | grep -Eq "(^|[^[:alnum:]_-])--$option([^[:alnum:]_-]|$)" || return 1
  done
  for option in if-lease-id if-lease-holder; do
    printf '%s\n' "$return_help" | grep -Eq "(^|[^[:alnum:]_-])--$option([^[:alnum:]_-]|$)" || return 1
  done
}

# A retained meta owns its copy until cleanup releases the record, irrespective
# of status, endpoint liveness or backlog holds. Call under the project lock
# before allocating, adopting, promoting or returning a copy. own_meta may be
# absent for a fresh allocation; another spelling of that same file is allowed.
# Requires fm-wake-lib.sh and fm-secondmate-registry-lib.sh from the caller.
fm_worktree_require_exclusive_record() { # <state> <worktree> <own-meta>
  local state=$1 worktree=$2 own_meta=$3 slot other field path other_slot state_dir count
  [ -d "$worktree" ] || return 0
  slot=$(CDPATH='' cd -- "$worktree" && pwd -P) || return 1
  fm_local_firstmate_state_dirs "$state" || {
    echo "REFUSED: $FM_LOCAL_FIRSTMATE_ERROR; copy ownership is unverified" >&2
    return 1
  }
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for other in "$state_dir"/*.meta; do
      [ -e "$other" ] || [ -L "$other" ] || continue
      [ -f "$other" ] && [ ! -L "$other" ] && [ -r "$other" ] || {
        echo "REFUSED: cannot read task record $other to prove copy ownership" >&2
        return 1
      }
      [ "${other##*/}" = "${own_meta##*/}" ] && [ "$other" -ef "$own_meta" ] && continue
      for field in worktree home; do
        count=$(grep -c "^$field=" "$other" || true)
        if [ "$count" -gt 1 ]; then
          echo "REFUSED: ambiguous $field identity in task record $other; copy ownership is unverified" >&2
          return 1
        fi
        path=$(fm_meta_get "$other" "$field")
        [ -d "$path" ] || continue
        other_slot=$(CDPATH='' cd -- "$path" && pwd -P) || return 1
        [ "$slot" = "$other_slot" ] || continue
        echo "REFUSED: recorded worktree $slot is also task $(basename "$other" .meta)'s recorded $field ($other); nothing was changed" >&2
        return 1
      done
    done
  done
  path=$(fm_meta_get "$own_meta" worktree)
  if [ -d "$path" ] && [ "$path" -ef "$slot" ] &&
    fm_treehouse_pool_slot "$(fm_meta_get "$own_meta" project)" "$slot"; then
    fm_treehouse_slot_owner_state "$slot" "$(basename "$own_meta" .meta)"
    case "$FM_TREEHOUSE_SLOT_OWNER" in
      mine|absent) ;;
      *)
        echo "REFUSED: copy $slot has a foreign or unreadable slot-owner claim; reconcile $own_meta before reuse" >&2
        return 1
        ;;
    esac
  fi
}

# Legacy scouts have no branch contract. A recorded branch must match exactly,
# including refusal of a detached HEAD; --force never authorizes another branch.
fm_worktree_require_recorded_branch() { # <meta> <worktree>
  local meta=$1 worktree=$2 branch actual
  branch=$(fm_meta_get "$meta" branch)
  [ -n "$branch" ] && [ -d "$worktree" ] || return 0
  actual=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null) || actual=HEAD
  [ "$actual" = "$branch" ] && return 0
  echo "REFUSED: $worktree is on $actual, not task $(basename "$meta" .meta)'s recorded branch $branch; preserving the copy and task record, even with --force" >&2
  return 1
}

# Upgrade a process reservation to Treehouse's state-only durable lease. Unlike
# interactive get, it survives shell exit without detaching/resetting the copy.
# Existing durable leases are already protective and are never replaced.
# The check mode runs every refusal up to the lease without taking it.
fm_treehouse_hold_recorded_copy() { # <project> <worktree> <task-id> [check]
  local project=$1 worktree=$2 id=$3 mode=${4:-} slot pool root entry status leased lease
  FM_TREEHOUSE_NEW_LEASE_ID=
  fm_treehouse_pool_slot "$project" "$worktree" || return 0
  slot=$(CDPATH='' cd -- "$worktree" && pwd -P) || return 1
  pool=$(dirname "$(dirname "$slot")")
  # --root is the parent of .treehouse; Treehouse appends that component.
  root=$(dirname "$(dirname "$pool")")
  status=$(cd "$project" && treehouse --root "$root" status --json) || return 1
  entry=$(printf '%s\n' "$status" | jq -ce --arg path "$slot" '
    [.[] | select(.path == $path)] |
    if length == 1 then .[0] else error("slot identity unavailable") end') || return 1
  leased=$(printf '%s\n' "$entry" | jq -er '
    (.status == "leased" or (.lease_id // "") != "" or .leased_at != null) | tostring') || return 1
  [ "$leased" != true ] || return 0
  fm_treehouse_supports_lease || {
    echo "REFUSED: Treehouse v$FM_TREEHOUSE_VERSION with durable leases is required" >&2
    return 1
  }
  [ "$mode" != check ] || return 0
  lease=$(cd "$project" && treehouse --root "$root" lease "$(basename "$(dirname "$slot")")" --lease-holder "$id" --json) || return 1
  [ "$(printf '%s\n' "$lease" | jq -er '.path')" = "$slot" ] || return 1
  # shellcheck disable=SC2034 # The allocating caller owns conditional rollback.
  FM_TREEHOUSE_NEW_LEASE_ID=$(printf '%s\n' "$lease" | jq -er '.lease_id | strings | select(length > 0)')
}

# Protect old process-only records BEFORE get can reset/reuse their slots.
# The project lock serializes Firstmate allocation, promotion and cleanup.
# No status word exempts a retained meta. Collisions refuse for reconciliation.
# The check mode runs the same refusals without holding any copy.
fm_treehouse_protect_recorded_copies() { # <state> <project> [check]
  local state=$1 project=$2 mode=${3:-} state_dir meta path
  local -a states
  fm_local_firstmate_state_dirs "$state" || {
    echo "REFUSED: $FM_LOCAL_FIRSTMATE_ERROR; cannot protect retained copies" >&2
    return 1
  }
  states=("${FM_LOCAL_FIRSTMATE_STATES[@]}")
  for state_dir in "${states[@]}"; do
    for meta in "$state_dir"/*.meta; do
      [ -e "$meta" ] || [ -L "$meta" ] || continue
      [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || {
        echo "REFUSED: cannot read retained task record $meta" >&2
        return 1
      }
      # Remote routes describe another machine, never this machine's pool.
      [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
      path=$(fm_meta_get "$meta" worktree)
      fm_treehouse_pool_slot "$project" "$path" || continue
      fm_worktree_require_exclusive_record "$state" "$path" "$meta" || return 1
      fm_treehouse_hold_recorded_copy "$project" "$path" "$(basename "$meta" .meta)" "$mode" || {
        echo "REFUSED: cannot durably protect retained copy $path ($meta); no new copy was acquired" >&2
        return 1
      }
    done
  done
}
