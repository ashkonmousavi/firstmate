#!/usr/bin/env bash
# fm-hold-release-lib.sh - structured release conditions on backlog holds.
#
# ONE OWNER of the hold-release contract: the condition syntax, the durable
# per-task record kept beside the hold, the "hold condition met" keyed
# decision, and the bounded evaluation the watcher's check sweep runs.
#
# THE PROBLEM THIS REPAIRS. A hold of kind external carried its release
# condition as free text in the reason ("awaiting merge <url>"), and nothing
# evaluated that text when the named event happened, so holds outlived their
# reason: work sat queued for days on PRs that had already merged. The fix is
# a structured condition stored beside the hold and evaluated on the existing
# watcher check cadence - no new daemon - with a durable keyed decision that
# must be dispositioned.
#
# CONDITION SYNTAX (fm_hold_release_valid owns it):
#   pr:<owner>/<repo>#<number>   a GitHub pull request; met when it is MERGED
#   marker:<absolute-path>       a file path; met when it exists
# Only these two forms exist. The pr form is GitHub-only because the fleet
# forge is GitHub and the evaluation reads it through gh exactly as
# bin/fm-pr-poll.sh does; a closed-not-merged PR is never "met" (re-examine
# such a hold by re-holding it).
#
# STORAGE. tasks-axi holds have no spare structured field, so the condition is
# recorded in this home's state at state/hold-releases/<task-id> (schema
# fm-hold-release.v1: task_id, condition, created_epoch), written by the hold
# wrapper paths at hold time:
#   - bin/fm-tasks-axi.sh hold --release-on <condition>  (any kind)
#   - bin/fm-captain-hold.sh hold --release-on <condition>
# The record is advisory metadata for evaluation; the backlog row remains the
# authority on whether a hold exists. A bare `tasks-axi hold` (bypassing the
# wrapper) writes no record and is therefore never evaluated - that is the
# documented bypass, and bin/fm-tasks-axi.sh refuses an external or kindless hold with
# neither --release-on nor --until precisely so the bypass is a choice.
#
# RECORD LIFECYCLE. The record exists exactly while its hold exists:
#   hold with --release-on      -> record written; a previous still-open
#                                  hold-release decision for the task closes
#                                  ("re-held") because that lifecycle ended
#   hold without --release-on   -> record dropped; open decision closes
#                                  ("re-held without a structured release
#                                  condition")
#   unhold                      -> record dropped; open decision closes
#                                  ("released")
#   task closed while held      -> the next evaluation drops the record and
#                                  closes any open decision ("hold no longer
#                                  active"), so no decision outlives its row
#
# THE KEYED DECISION. When evaluation finds the condition met, it opens ONE
# durable decision on the held task's own status log (state/<id>.status,
# created when absent):
#   blocked [key=hold-release-<id>]: hold-release-met: <condition>
# `hold-release-` is a reserved decision-key namespace in
# bin/fm-classify-lib.sh, so only lines speaking this namespace's vocabulary
# can open or close it; a stray writer cannot take the key over and a bare
# answered note cannot clear it. The decision stays in OPEN DECISIONS
# (bin/fm-wake-drain.sh) until the hold is released or re-held, which is what
# makes the wake persist: the evaluator queues exactly one
#   hold condition met: <id> <condition>
# check wake per episode, and the fold keeps the call visible after that wake
# is drained. Dispositioning is ordinary hold work: unhold the row (resume it)
# or re-hold it with a fresh condition or date; the wrapper closes the
# decision in the same run. fm-send --resolve-key cannot close it - the
# reserved namespace refuses that close on purpose, because answering a
# message never changed a hold.
#
# EVALUATION (fm_hold_release_evaluate): iterates the records, reads each
# task's held state through bin/fm-tasks-axi.sh show (bounded, overridable
# for tests through FM_HOLD_RELEASE_SHOW_CMD), reconciles vanished holds, and
# evaluates conditions. A pr lookup that fails (no gh, no network, bad auth)
# is UNKNOWN, never met: a failed lookup can never release a hold. Each
# newly-met condition commits its check wake before announcing the decision,
# then prints its wake line for the watcher to surface.
#
# Tunables (env):
#   FM_HOLD_RELEASE_GH          gh replacement used for pr lookups (tests)
#   FM_HOLD_RELEASE_SHOW_CMD    prefix command receiving <task-id> that prints
#                               a tasks-axi `show` block (tests)
#   FM_HOLD_RELEASE_NOW         fixed epoch for deterministic tests
#   FM_HOLD_RELEASE_SHOW_BOUND  per-task show and PR bound in seconds (default 10)
#   FM_HOLD_RELEASE_MAX_RECORDS records per evaluation sweep (default 25)
#
# Sourced by bin/fm-tasks-axi.sh, bin/fm-captain-hold.sh,
# bin/fm-backlog-transition-lib.sh, bin/fm-watch.sh, and tests.
# No side effects on source. set -u / set -e safe.

_FM_HOLD_RELEASE_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd 2>/dev/null)" || _FM_HOLD_RELEASE_LIB_DIR="."
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$_FM_HOLD_RELEASE_LIB_DIR/fm-timeout-lib.sh"

FM_HOLD_RELEASE_SCHEMA='fm-hold-release.v1'
FM_HOLD_RELEASE_KEY_PREFIX='hold-release-'
FM_HOLD_RELEASE_MET_PREFIX='hold-release-met: '
FM_HOLD_RELEASE_CLOSED_PREFIX='hold-release-closed: '
FM_HOLD_RELEASE_WAKE_PREFIX='hold condition met: '

fm_hold_release_now() {
  if [ -n "${FM_HOLD_RELEASE_NOW:-}" ]; then
    printf '%s' "$FM_HOLD_RELEASE_NOW"
    return 0
  fi
  date +%s
}

# Validate one condition; print the normalized form on stdout when valid.
# Return 0 valid, 1 invalid. The pr form reuses the owner/repo/number classes
# bin/fm-pr-lib.sh enforces for GitHub pull URLs, so an accepted condition can
# always be rebuilt into the URL the evaluation reads.
fm_hold_release_valid() {  # <condition>
  local condition=${1-} owner repo number
  local LC_ALL=C
  case "$condition" in
    pr:*)
      condition=${condition#pr:}
      case "$condition" in
        */*#*) ;;
        *) return 1 ;;
      esac
      owner=${condition%%/*}
      repo=${condition#*/}
      repo=${repo%%#*}
      number=${condition#*#}
      [ -n "$owner" ] && [ "${#owner}" -le 39 ] || return 1
      case "$owner" in
        *[!A-Za-z0-9-]*|-*|*-|*--*) return 1 ;;
      esac
      [ -n "$repo" ] && [ "${#repo}" -le 100 ] || return 1
      case "$repo" in
        .|..|*[!A-Za-z0-9._-]*) return 1 ;;
      esac
      case "$number" in
        ''|0*|*[!0-9]*) return 1 ;;
      esac
      printf 'pr:%s/%s#%s' "$owner" "$repo" "$number"
      ;;
    marker:/*)
      condition=${condition#marker:}
      [ -n "$condition" ] || return 1
      case "$condition" in
        *[![:print:]]*|*$'\t'*|*$'\n'*) return 1 ;;
      esac
      printf 'marker:%s' "$condition"
      ;;
    *)
      return 1
      ;;
  esac
}

# The canonical GitHub pull URL for a pr: condition (data for humans and logs;
# the evaluation reads state through gh with this URL, exactly as
# bin/fm-pr-poll.sh does).
fm_hold_release_pr_url() {  # <pr-condition>
  local condition=${1-}
  case "$condition" in
    pr:*) ;;
    *) return 1 ;;
  esac
  condition=${condition#pr:}
  printf 'https://github.com/%s/pull/%s' "${condition%#*}" "${condition#*#}"
}

fm_hold_release_dir() {  # <state-dir>
  printf '%s/hold-releases' "$1"
}

fm_hold_release_record_path() {  # <state-dir> <task-id>
  printf '%s/%s' "$(fm_hold_release_dir "$1")" "$2"
}

fm_hold_release_decision_key() {  # <task-id>
  printf '%s%s' "$FM_HOLD_RELEASE_KEY_PREFIX" "$1"
}

# Read one record. Sets FM_HOLD_RELEASE_CONDITION and FM_HOLD_RELEASE_TASK_ID;
# returns 0 present, 1 absent, 2 present but unusable.
fm_hold_release_record_read() {  # <state-dir> <task-id>
  local state=$1 id=$2 rec line key value
  FM_HOLD_RELEASE_CONDITION=
  FM_HOLD_RELEASE_TASK_ID=
  rec=$(fm_hold_release_record_path "$state" "$id")
  [ -e "$rec" ] || [ -L "$rec" ] || return 1
  [ -f "$rec" ] && [ ! -L "$rec" ] && [ -r "$rec" ] || return 2
  local schema='' condition=''
  while IFS= read -r line; do
    key=${line%%=*}
    value=${line#*=}
    case "$key=$value" in
      "$line") ;;
      *) continue ;;
    esac
    case "$key" in
      schema) schema=$value ;;
      condition) condition=$value ;;
    esac
  done < "$rec"
  [ "$schema" = "$FM_HOLD_RELEASE_SCHEMA" ] || return 2
  [ -n "$condition" ] || return 2
  [ -n "$(fm_hold_release_valid "$condition")" ] || return 2
  FM_HOLD_RELEASE_CONDITION=$condition
  # shellcheck disable=SC2034  # Output global, read by the sourcing caller.
  FM_HOLD_RELEASE_TASK_ID=$id
  return 0
}

fm_hold_release_status_path() {  # <state-dir> <task-id>
  printf '%s/%s.status' "$1" "$2"
}

# 0 when the hold-release decision for <task-id> is still open in its status
# log; 1 when it is not (closed or never opened).
fm_hold_release_decision_open_p() {  # <state-dir> <task-id>
  local state=$1 id=$2 status_file key
  status_file=$(fm_hold_release_status_path "$state" "$id")
  key=$(fm_hold_release_decision_key "$id")
  # shellcheck source=bin/fm-classify-lib.sh
  # shellcheck disable=SC1091
  . "$_FM_HOLD_RELEASE_LIB_DIR/fm-classify-lib.sh"
  case $'\n'"$(status_open_decisions "$status_file")" in
    *$'\n'"$key"$'\t'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Open the "condition met" decision on the held task's status log. Idempotent:
# returns 0 when the wake was committed and the line newly appended,
# 1 when the decision is already open (no wake), 2 when the append failed.
# The append is the home's own bookkeeping and goes through the guarded
# self-announced writer (bin/fm-wake-lib.sh), so opening the decision does not
# itself mint a separate signal wake on machines where the writer can commit
# its owned range; where it cannot, the watcher surfacing the line once is the
# safe direction.
fm_hold_release_decision_open() {  # <state-dir> <task-id> <condition>
  local state=$1 id=$2 condition=$3 status_file key line
  status_file=$(fm_hold_release_status_path "$state" "$id")
  key=$(fm_hold_release_decision_key "$id")
  fm_hold_release_decision_open_p "$state" "$id" && return 1
  # A missing status log is created empty so the self-announced writer can
  # record the whole appended range as home-owned from byte 0.
  if [ ! -e "$status_file" ]; then
    mkdir -p "$state" || return 2
    (umask 077; : > "$status_file") || return 2
  fi
  line="blocked [key=$key]: $FM_HOLD_RELEASE_MET_PREFIX$condition"
  fm_hold_release_wake_lib "$state"
  STATE="$state" FM_WAKE_QUEUE="$state/.wake-queue" FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock" \
    fm_wake_append check "hold-release:$id" \
    "check: hold-release: $FM_HOLD_RELEASE_WAKE_PREFIX$id $condition" || return $?
  fm_wake_status_append_self_announced "$state" "$status_file" "$line" || true
  fm_hold_release_decision_open_p "$state" "$id" || return 2
  return 0
}

# Close an open hold-release decision, if one is open. Best effort by design:
# the hold itself already changed, and the next evaluation reconciles any
# close that failed. Returns 0 whenever nothing is left open.
fm_hold_release_decision_close() {  # <state-dir> <task-id> <how>
  local state=$1 id=$2 how=$3 status_file key line
  status_file=$(fm_hold_release_status_path "$state" "$id")
  key=$(fm_hold_release_decision_key "$id")
  fm_hold_release_decision_open_p "$state" "$id" || return 0
  [ -f "$status_file" ] || return 0
  line="resolved [key=$key]: $FM_HOLD_RELEASE_CLOSED_PREFIX$how"
  fm_hold_release_wake_lib "$state"
  fm_wake_status_append_self_announced "$state" "$status_file" "$line" || true
  ! fm_hold_release_decision_open_p "$state" "$id"
}

# Source bin/fm-wake-lib.sh for the guarded self-announced append, with this
# function's own localized copies of the globals that library derives from
# STATE at source time (bin/fm-pending-reply-lib.sh uses the same shape), so
# sourcing here can neither read an unbound STATE nor clobber the caller's.
# Idempotent: a second call is a no-op shell re-parse, not a redefinition risk.
fm_hold_release_wake_lib() {  # <state-dir>
  # shellcheck disable=SC2034  # Locals consumed by the sourced library.
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  STATE=$1
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$_FM_HOLD_RELEASE_LIB_DIR/fm-wake-lib.sh"
}

fm_hold_release_with_lock() {
  local state=$1 id=$2
  shift 2
  case "$id" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  if [ "${_FM_HOLD_RELEASE_LOCK:-}" = "$state/.hold-release-$id.lock" ]; then
    "$@"
    return $?
  fi
  local _FM_HOLD_RELEASE_LOCK="$state/.hold-release-$id.lock" STATE=$state rc=0
  fm_hold_release_wake_lib "$state"
  fm_checkpoint_lock "$_FM_HOLD_RELEASE_LOCK" || return $?
  "$@" || rc=$?
  fm_lock_release "$_FM_HOLD_RELEASE_LOCK" || rc=1
  return "$rc"
}

# Write (or rewrite) the record for a hold that carries --release-on, closing
# any still-open hold-release decision for the task: that lifecycle ended.
fm_hold_release_record_write() {
  fm_hold_release_with_lock "$1" "$2" _fm_hold_release_record_write "$@"
}

_fm_hold_release_record_write() {  # <state-dir> <task-id> <condition>
  local state=$1 id=$2 condition=$3 dir rec tmp
  condition=$(fm_hold_release_valid "$condition") || return 1
  dir=$(fm_hold_release_dir "$state")
  rec=$(fm_hold_release_record_path "$state" "$id")
  mkdir -p "$dir" || return 1
  [ ! -L "$rec" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.record.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n' \
      "schema=$FM_HOLD_RELEASE_SCHEMA" \
      "task_id=$id" \
      "condition=$condition" \
      "created_epoch=$(fm_hold_release_now)" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_hold_release_decision_close "$state" "$id" "re-held with release condition $condition" \
    || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$rec" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# Drop the record and close any open decision: the hold ended or was re-held
# without a structured condition.
fm_hold_release_record_drop() {
  fm_hold_release_with_lock "$1" "$2" _fm_hold_release_record_drop "$@"
}

_fm_hold_release_record_drop() {  # <state-dir> <task-id> <how>
  local state=$1 id=$2 how=$3 rec
  rec=$(fm_hold_release_record_path "$state" "$id")
  fm_hold_release_decision_close "$state" "$id" "$how" || return 1
  rm -f -- "$rec" || return 1
  return 0
}

# Evaluate one condition. Returns 0 met, 1 not met, 2 unknown (a failed
# lookup is never met). The pr leg reads the pull state through gh with the
# canonical URL, mirroring bin/fm-pr-poll.sh; every failure path - missing gh,
# nonzero exit, unparsable output - is unknown.
fm_hold_release_condition_met() {  # <condition>
  local condition=${1-} gh state url marker bound
  case "$condition" in
    pr:*)
      gh=${FM_HOLD_RELEASE_GH:-gh}
      command -v "$gh" >/dev/null 2>&1 || return 2
      url=$(fm_hold_release_pr_url "$condition") || return 2
      bound=${FM_HOLD_RELEASE_SHOW_BOUND:-10}
      case "$bound" in ''|*[!0-9]*) bound=10 ;; esac
      [ "$bound" -gt 0 ] 2>/dev/null || bound=10
      bound=$(fm_checkpoint_budget "$bound") || return 2
      state=$(fm_run_timed "$bound" "$gh" pr view "$url" --json state -q .state 2>/dev/null) || return 2
      case "$state" in
        MERGED) return 0 ;;
        OPEN|CLOSED) return 1 ;;
        *) return 2 ;;
      esac
      ;;
    marker:*)
      marker=${condition#marker:}
      if [ -e "$marker" ] || [ -L "$marker" ]; then
        return 0
      fi
      return 1
      ;;
    *)
      return 2
      ;;
  esac
}

# Read one task's hold state through the tasks-axi wrapper (bounded). Sets
# FM_HOLD_RELEASE_SHOW_STATE and FM_HOLD_RELEASE_SHOW_HELD; returns 0 read,
# 1 task not found, 2 unreadable.
_fm_hold_release_show() {  # <task-id>
  local id=$1 out rc bound
  FM_HOLD_RELEASE_SHOW_STATE=
  FM_HOLD_RELEASE_SHOW_HELD=
  bound=${FM_HOLD_RELEASE_SHOW_BOUND:-10}
  case "$bound" in ''|*[!0-9]*) bound=10 ;; esac
  [ "$bound" -gt 0 ] 2>/dev/null || bound=10
  bound=$(fm_checkpoint_budget "$bound") || return 2
  if [ -n "${FM_HOLD_RELEASE_SHOW_CMD:-}" ]; then
    # shellcheck disable=SC2086  # a test-supplied prefix command
    out=$(fm_run_timed "$bound" $FM_HOLD_RELEASE_SHOW_CMD "$id" 2>&1) || rc=$?
  else
    out=$(fm_run_timed "$bound" "$_FM_HOLD_RELEASE_LIB_DIR/fm-tasks-axi.sh" show "$id" 2>&1) || rc=$?
  fi
  case "${rc:-0}" in
    0) ;;
    *)
      case "$out" in
        *'code: NOT_FOUND'*) return 1 ;;
        *) return 2 ;;
      esac
      ;;
  esac
  FM_HOLD_RELEASE_SHOW_STATE=$(printf '%s\n' "$out" | sed -n 's/^  state: //p' | head -1)
  FM_HOLD_RELEASE_SHOW_HELD=$(printf '%s\n' "$out" | sed -n 's/^  held: //p' | head -1)
  [ -n "$FM_HOLD_RELEASE_SHOW_STATE" ] || return 2
  return 0
}

# One evaluation sweep over the records. Prints one
#   hold condition met: <task-id> <condition>
# line per newly-met condition after its check wake is durably queued.
# Diagnostics go to stderr. Returns 0 unless the sweep itself could not run.
fm_hold_release_evaluate() {
  local state=$1 dir rec id rc=0 seen=0 max pass cursor='' cursor_file slice=30 remaining
  local LC_ALL=C FM_CHECKPOINT_DEADLINE=${FM_CHECKPOINT_DEADLINE:-}
  fm_checkpoint_clock
  if [ -n "$FM_CHECKPOINT_DEADLINE" ]; then
    remaining=$((FM_CHECKPOINT_DEADLINE - FM_CHECKPOINT_NOW))
    [ "$remaining" -gt 1 ] || return 124
    [ "$((remaining / 2))" -ge "$slice" ] || slice=$((remaining / 2))
  fi
  FM_CHECKPOINT_DEADLINE=$((FM_CHECKPOINT_NOW + slice))
  dir=$(fm_hold_release_dir "$state")
  cursor_file="$state/.hold-release-cursor"
  max=${FM_HOLD_RELEASE_MAX_RECORDS:-25}
  case "$max" in ''|*[!0-9]*) max=25 ;; esac
  [ "$max" -gt 0 ] 2>/dev/null || max=25
  [ -d "$dir" ] || return 0
  [ ! -f "$cursor_file" ] || IFS= read -r cursor < "$cursor_file" || true
  for pass in after before; do
    [ "$pass" != before ] || [ -n "$cursor" ] || break
    for rec in "$dir"/*; do
      [ -f "$rec" ] && [ ! -L "$rec" ] || continue
      id=${rec##*/}
      if [ -n "$cursor" ]; then
        if [ "$pass" = after ]; then [[ "$id" > "$cursor" ]] || continue
        else [[ "$id" > "$cursor" ]] && continue; fi
      fi
      [ "$seen" -lt "$max" ] || return "$rc"
      fm_checkpoint_expired && return 124
      printf '%s\n' "$id" > "$cursor_file" || return 1
      seen=$((seen + 1))
      _fm_hold_release_evaluate_one "$state" "$id" || rc=$?
      [ "$rc" -ne 124 ] || return "$rc"
    done
  done
  return "$rc"
}

_fm_hold_release_evaluate_one() {
  fm_hold_release_with_lock "$1" "$2" _fm_hold_release_evaluate_one_locked "$@"
}

_fm_hold_release_evaluate_one_locked() {
  local state=$1 id=$2 condition show_rc=0
  fm_hold_release_record_read "$state" "$id" || {
    printf 'fm-hold-release: unusable release record for %s, dropping it\n' "$id" >&2
    fm_hold_release_record_drop "$state" "$id" "release record unreadable"
    return 0
  }
  condition=$FM_HOLD_RELEASE_CONDITION
  _fm_hold_release_show "$id" || show_rc=$?
  case "$show_rc" in
    1)
      fm_hold_release_record_drop "$state" "$id" "task no longer exists"
      return 0
      ;;
    2) return 0 ;;
  esac
  [ "$FM_HOLD_RELEASE_SHOW_HELD" = yes ] || {
    fm_hold_release_record_drop "$state" "$id" \
      "hold no longer active (task ${FM_HOLD_RELEASE_SHOW_STATE:-unknown})"
    return 0
  }
  if ! fm_hold_release_condition_met "$condition"; then
    return 0
  fi
  local open_rc=0
  fm_hold_release_decision_open "$state" "$id" "$condition" || open_rc=$?
  case "$open_rc" in
    124) return 124 ;;
    0) printf '%s%s %s\n' "$FM_HOLD_RELEASE_WAKE_PREFIX" "$id" "$condition" ;;
    1) return 0 ;;
    *) printf 'fm-hold-release: could not record the met condition for %s\n' "$id" >&2; return 1 ;;
  esac
  return 0
}
