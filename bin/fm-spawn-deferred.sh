#!/usr/bin/env bash
# fm-spawn-deferred.sh - retry a spawn deferred because the machine has no free lane.
#
# Usage:
#   fm-spawn-deferred.sh record <task-id> -- <spawn-program> <task-id> [args...]
#   fm-spawn-deferred.sh sweep
#
# bin/fm-spawn.sh calls record only when machine admission refuses a fresh ship
# or scout with FM_CAPACITY_REASON=full (exit 75, "no free machine lane").
# Relaunches, other machine-admission refusals, project-capacity deferral, and
# project-lock contention are not recorded here. Persistent secondmate startup
# is exempt from machine admission and is never recorded.
#
# One record per task lives under state/spawn-deferred/queue, named only by the
# zero-padded order in which it was first deferred. The body is schema
# fm-deferred-spawn.v1: task, order, cwd, argv_sha256, failures, reported,
# pending, then one arg= line per base64-encoded argument. The checksum covers
# the raw arguments joined by trailing NULs. A later deferral of the same task
# keeps that order and clears a previous hard failure. State files are mode 600
# and the directory is mode 700.
#
# sweep runs from the supervision check sweep (bin/fm-watch.sh), whose default
# period is five minutes. Its detached retry worker asks bin/fm-capacity.sh
# for free_lanes once. Each
# claim already running prevents another launch, and only a successful launch
# spends a free lane. The oldest eligible queued request in this home starts first.
# Ordering is per home; there is no machine-wide sequencing or shared queue.
# Eligible means the backlog row is exactly queued, not held and not blocked,
# when the backlog gate applies (bin/fm-backlog-transition-lib.sh), and the task
# record does not already hold a machine seat (bin/fm-project-capacity-lib.sh).
# When the gate does not apply, a row with no held seat is eligible. A held or
# blocked row stays queued and does not block a younger request. A row that is
# in flight, done, cancelled, or missing is removed without a launch.
#
# The recorded program is executed with the recorded arguments and working
# directory. The environment is the sweep's environment, not a snapshot from
# the deferral. A record whose checksum, task identity, program, or working
# directory no longer matches is removed and reported as stale; it is not
# started. Exit 0 removes the record. Exit 75, including the record() call the
# retried spawn makes, returns the request to the queue at its original order.
# Any other exit is reported once and is not launched again until a new
# deferral rewrites the record or the row leaves the queue.
#
# A claim directory entry is the in-progress mark, taken while the sweep lock
# state/.spawn-deferred.lock is held. The spawn itself runs after that lock is
# released, so a retried spawn can record another deferral without deadlocking
# the detached retry worker. sweep returns without waiting for a spawn and
# publishes completed retry outcomes on a later sweep.
# Tests set FM_SPAWN_DEFERRED_CAPACITY_BIN to replace the capacity
# command. This hook applies only when FM_TEST_SEAM=1.
# sweep prints nothing and exits 0 when there is nothing to report, the lock
# is busy, or the machine is full.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG"

case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit 0
    ;;
esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

STORE="$STATE/spawn-deferred"
QUEUE="$STORE/queue"
CLAIM="$STORE/claim"
LOCK="$STATE/.spawn-deferred.lock"
RETRY_LOG="$STORE/retry.log"
REPORT="$STORE/report"
DEFERRED_SCHEMA=fm-deferred-spawn.v1

deferred_task_id_valid() { # <id> - same character rule as fm_pr_task_id_valid
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ]
}

deferred_is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
}

deferred_ensure_dirs() {
  mkdir -p -- "$QUEUE" "$CLAIM" || return 1
  chmod 700 "$STORE" "$QUEUE" "$CLAIM" || return 1
}

deferred_lock_pid() {
  local owner="" pid=""
  if [ -L "$LOCK" ]; then
    owner=$(readlink -- "$LOCK" 2>/dev/null || true)
    [ -n "$owner" ] || return 0
    case "$owner" in
      /*) ;;
      *) owner="$(dirname -- "$LOCK")/$owner" ;;
    esac
    pid=$(cat -- "$owner/pid" 2>/dev/null || true)
  elif [ -d "$LOCK" ]; then
    pid=$(cat -- "$LOCK/pid" 2>/dev/null || true)
  fi
  printf '%s' "$pid"
}

deferred_release_if_held() {
  [ "$(deferred_lock_pid)" = "$$" ] || return 0
  fm_lock_release "$LOCK" || true
}

trap deferred_release_if_held EXIT

deferred_order_name() { # <decimal>
  printf '%020d' "$1"
}

deferred_hash_args() { # <args...> prints 64 hex
  local tmp arg hash
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-deferred-hash.XXXXXX") || return 1
  : > "$tmp"
  for arg in "$@"; do
    printf '%s\0' "$arg" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  done
  if command -v sha256sum >/dev/null 2>&1; then
    hash=$(sha256sum -- "$tmp" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    hash=$(shasum -a 256 -- "$tmp" | awk '{print $1}')
  else
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$hash"
}

deferred_b64_encode() { # <string> prints one line
  printf '%s' "$1" | base64 | tr -d '\n'
}

deferred_b64_decode() { # <encoded> prints raw bytes
  local enc=$1 tmp content
  if [ -z "$enc" ]; then
    return 0
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-deferred-b64.XXXXXX") || return 1
  if ! printf '%s' "$enc" | base64 --decode > "$tmp" 2>/dev/null; then
    if ! printf '%s' "$enc" | base64 -D > "$tmp" 2>/dev/null; then
      rm -f -- "$tmp"
      return 1
    fi
  fi
  content=$(cat -- "$tmp"; printf x)
  rm -f -- "$tmp"
  content=${content%x}
  printf '%s' "$content"
}

deferred_write() { # <dest> <task> <order> <cwd> <sha> <failures> <reported> <pending> <args...>
  local dest=$1 task=$2 order=$3 cwd=$4 sha=$5 failures=$6 reported=$7 pending=$8
  shift 8
  local tmp side arg enc old status=0
  old=$(umask)
  umask 077
  tmp=$(mktemp "$STORE/.tmp.XXXXXX") || { umask "$old"; return 1; }
  side=$(mktemp "$STORE/.args.XXXXXX") || { rm -f -- "$tmp"; umask "$old"; return 1; }
  for arg in "$@"; do
    enc=$(deferred_b64_encode "$arg") || status=1
    [ "$status" -eq 0 ] || break
    printf 'arg=%s\n' "$enc" >> "$side" || status=1
    [ "$status" -eq 0 ] || break
  done
  if [ "$status" -eq 0 ]; then
    {
      printf 'schema=%s\n' "$DEFERRED_SCHEMA"
      printf 'task=%s\n' "$task"
      printf 'order=%s\n' "$order"
      printf 'cwd=%s\n' "$cwd"
      printf 'argv_sha256=%s\n' "$sha"
      printf 'failures=%s\n' "$failures"
      printf 'reported=%s\n' "$reported"
      printf 'pending=%s\n' "$pending"
      cat -- "$side"
    } > "$tmp" || status=1
  fi
  rm -f -- "$side"
  if [ "$status" -ne 0 ]; then
    rm -f -- "$tmp"
    umask "$old"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; umask "$old"; return 1; }
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; umask "$old"; return 1; }
  umask "$old"
}

deferred_load() { # <file>
  local file=$1 line key
  DEFERRED_SCHEMA_VALUE=
  DEFERRED_TASK=
  DEFERRED_ORDER=
  DEFERRED_CWD=
  DEFERRED_SHA=
  DEFERRED_FAILURES=
  DEFERRED_REPORTED=
  DEFERRED_PENDING=
  DEFERRED_ARG_ENC=()
  DEFERRED_SEEN_SCHEMA=0
  DEFERRED_SEEN_TASK=0
  DEFERRED_SEEN_ORDER=0
  DEFERRED_SEEN_CWD=0
  DEFERRED_SEEN_SHA=0
  DEFERRED_SEEN_FAILURES=0
  DEFERRED_SEEN_REPORTED=0
  DEFERRED_SEEN_PENDING=0
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*|task=*|order=*|cwd=*|argv_sha256=*|failures=*|reported=*|pending=*|arg=*) ;;
      *) return 1 ;;
    esac
    key=${line%%=*}
    case "$key" in
      schema)
        [ "$DEFERRED_SEEN_SCHEMA" -eq 0 ] || return 1
        DEFERRED_SEEN_SCHEMA=1
        DEFERRED_SCHEMA_VALUE=${line#schema=}
        ;;
      task)
        [ "$DEFERRED_SEEN_TASK" -eq 0 ] || return 1
        DEFERRED_SEEN_TASK=1
        DEFERRED_TASK=${line#task=}
        ;;
      order)
        [ "$DEFERRED_SEEN_ORDER" -eq 0 ] || return 1
        DEFERRED_SEEN_ORDER=1
        DEFERRED_ORDER=${line#order=}
        ;;
      cwd)
        [ "$DEFERRED_SEEN_CWD" -eq 0 ] || return 1
        DEFERRED_SEEN_CWD=1
        DEFERRED_CWD=${line#cwd=}
        ;;
      argv_sha256)
        [ "$DEFERRED_SEEN_SHA" -eq 0 ] || return 1
        DEFERRED_SEEN_SHA=1
        DEFERRED_SHA=${line#argv_sha256=}
        ;;
      failures)
        [ "$DEFERRED_SEEN_FAILURES" -eq 0 ] || return 1
        DEFERRED_SEEN_FAILURES=1
        DEFERRED_FAILURES=${line#failures=}
        ;;
      reported)
        [ "$DEFERRED_SEEN_REPORTED" -eq 0 ] || return 1
        DEFERRED_SEEN_REPORTED=1
        DEFERRED_REPORTED=${line#reported=}
        ;;
      pending)
        [ "$DEFERRED_SEEN_PENDING" -eq 0 ] || return 1
        DEFERRED_SEEN_PENDING=1
        DEFERRED_PENDING=${line#pending=}
        ;;
      arg)
        DEFERRED_ARG_ENC+=("${line#arg=}")
        ;;
    esac
  done < "$file"
  [ "$DEFERRED_SEEN_SCHEMA" -eq 1 ] && [ "$DEFERRED_SEEN_TASK" -eq 1 ] \
    && [ "$DEFERRED_SEEN_ORDER" -eq 1 ] && [ "$DEFERRED_SEEN_CWD" -eq 1 ] \
    && [ "$DEFERRED_SEEN_SHA" -eq 1 ] && [ "$DEFERRED_SEEN_FAILURES" -eq 1 ] \
    && [ "$DEFERRED_SEEN_REPORTED" -eq 1 ] && [ "$DEFERRED_SEEN_PENDING" -eq 1 ] \
    || return 1
  [ "$DEFERRED_SCHEMA_VALUE" = "$DEFERRED_SCHEMA" ] || return 1
  deferred_task_id_valid "$DEFERRED_TASK" || return 1
  deferred_is_uint "$DEFERRED_ORDER" || return 1
  deferred_is_uint "$DEFERRED_FAILURES" || return 1
  deferred_is_uint "$DEFERRED_REPORTED" || return 1
}

deferred_decode_args() {
  local enc raw
  DECODED=()
  [ "${#DEFERRED_ARG_ENC[@]}" -ge 2 ] || return 1
  for enc in "${DEFERRED_ARG_ENC[@]}"; do
    raw=$(deferred_b64_decode "$enc" && printf x) || return 1
    DECODED+=("${raw%x}")
  done
}

deferred_validate() { # <file> sets STALE_REASON when stale; 0 means usable
  local file=$1 base numeric got
  STALE_REASON=
  if ! deferred_load "$file"; then
    STALE_REASON="record is unreadable"
    return 1
  fi
  base=$(basename -- "$file")
  numeric=$((10#$base))
  [ "$DEFERRED_ORDER" -eq "$numeric" ] || {
    STALE_REASON="record is unreadable"
    return 1
  }
  if ! deferred_decode_args; then
    STALE_REASON="record is unreadable"
    return 1
  fi
  got=$(deferred_hash_args "${DECODED[@]}") || {
    STALE_REASON="record is unreadable"
    return 1
  }
  [ "$got" = "$DEFERRED_SHA" ] || {
    STALE_REASON="arguments changed"
    return 1
  }
  [ "${DECODED[1]}" = "$DEFERRED_TASK" ] || {
    STALE_REASON="arguments are not a spawn of $DEFERRED_TASK"
    return 1
  }
  if [ ! -f "${DECODED[0]}" ] || [ -L "${DECODED[0]}" ]; then
    STALE_REASON="spawn program is missing"
    return 1
  fi
  [ -d "$DEFERRED_CWD" ] || {
    STALE_REASON="working directory is gone"
    return 1
  }
  return 0
}

deferred_each_order_file() { # <dir>
  local dir=$1 f base
  for f in "$dir"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    base=$(basename -- "$f")
    case "$base" in
      *[!0-9]*) continue ;;
    esac
    printf '%s\n' "$f"
  done
}

deferred_remove_task() { # <id>
  local id=$1 f task
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    task=$(sed -n 's/^task=//p' "$f" | head -1)
    [ "$task" = "$id" ] || continue
    rm -f -- "$f" "${f}.pid" "${f}.rc"
  done <<EOF
$(deferred_each_order_file "$QUEUE")
$(deferred_each_order_file "$CLAIM")
EOF
}

deferred_seat_held() { # <id> 0 when the task record holds a machine seat
  local id=$1 meta raw
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  raw=$(cat -- "$meta" 2>/dev/null) || return 0
  fm_task_record_holds_seat "$meta" "$raw" "$STATE"
}

deferred_eligibility() { # <id> sets ELIG to start, skip, drop, or error
  local id=$1 applies
  ELIG=error
  ELIG_REASON=
  fm_backlog_transition_applies "$CONFIG" "$DATA" ship
  applies=$?
  if [ "$applies" -eq 2 ]; then
    ELIG=error
    ELIG_REASON=${FM_BACKLOG_TRANSITION_ERROR:-backlog gate unreadable}
    return 0
  fi
  if [ "$applies" -eq 0 ]; then
    if ! fm_backlog_row_probe "$DATA" "$id"; then
      if [ "${FM_BACKLOG_ROW_RESULT:-}" = not_found ]; then
        ELIG=drop
        return 0
      fi
      ELIG=error
      ELIG_REASON=${FM_BACKLOG_ROW_ERROR:-backlog row unreadable}
      return 0
    fi
    case "$FM_BACKLOG_ROW_STATE" in
      "queued no no") ;;
      queued\ yes\ *|queued\ no\ yes)
        ELIG=skip
        return 0
        ;;
      *)
        ELIG=drop
        return 0
        ;;
    esac
  fi
  if deferred_seat_held "$id"; then
    ELIG=skip
    return 0
  fi
  ELIG=start
}

deferred_next_order() {
  local next
  next=$(cat -- "$STORE/seq" 2>/dev/null || true)
  deferred_is_uint "$next" || next=0
  next=$((next + 1))
  printf '%s\n' "$next" > "$STORE/seq" || return 1
  chmod 600 "$STORE/seq" || return 1
  printf '%s' "$next"
}

deferred_record() { # <id> -- <argv...>
  local id=${1:-} cwd sha order dest f base task best best_order numeric
  shift || return 1
  [ "${1:-}" = -- ] || return 1
  shift
  deferred_task_id_valid "$id" || return 1
  [ "$#" -ge 2 ] || return 1
  [ "$2" = "$id" ] || return 1
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  cwd=$(pwd -P) || return 1
  [ -d "$cwd" ] || return 1
  case "$cwd" in
    *$'\n'*) return 1 ;;
  esac
  deferred_ensure_dirs || return 1
  sha=$(deferred_hash_args "$@") || return 1
  best=
  best_order=
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    task=$(sed -n 's/^task=//p' "$f" | head -1)
    [ "$task" = "$id" ] || continue
    base=$(basename -- "$f")
    numeric=$((10#$base))
    if [ -z "$best" ] || [ "$numeric" -lt "$best_order" ]; then
      if [ -n "$best" ]; then
        rm -f -- "$best" "${best}.pid" "${best}.rc"
      fi
      best=$f
      best_order=$numeric
    else
      rm -f -- "$f" "${f}.pid" "${f}.rc"
    fi
  done <<EOF
$(deferred_each_order_file "$QUEUE")
$(deferred_each_order_file "$CLAIM")
EOF
  if [ -n "$best" ]; then
    order=$best_order
    dest=$best
  else
    order=$(deferred_next_order) || return 1
    dest="$QUEUE/$(deferred_order_name "$order")"
  fi
  deferred_write "$dest" "$id" "$order" "$cwd" "$sha" 0 0 "" "$@"
}

deferred_report_stale() { # <file>
  local file=$1 task
  task=$(sed -n 's/^task=//p' "$file" | head -1)
  deferred_task_id_valid "$task" || task=unknown
  if [ -z "${STALE_REASON:-}" ]; then
    STALE_REASON="record is unreadable"
  fi
  printf 'stale %s %s\n' "$task" "$STALE_REASON"
  if [ "$task" != unknown ]; then
    deferred_remove_task "$task"
  else
    rm -f -- "$file" "${file}.pid" "${file}.rc"
  fi
}

deferred_note_failure() { # <file> <rc> <sync|async>
  local file=$1 rc=$2 mode=$3 dest base pending reported
  dest="$QUEUE/$(basename -- "$file")"
  pending=$DEFERRED_PENDING
  reported=$DEFERRED_REPORTED
  if [ "$reported" != 1 ]; then
    pending="failed $DEFERRED_TASK exit $rc"
    if [ "$mode" = sync ]; then
      printf '%s\n' "$pending"
      reported=1
      pending=
    fi
  fi
  base=$((DEFERRED_FAILURES + 1))
  deferred_write "$dest" "$DEFERRED_TASK" "$DEFERRED_ORDER" "$DEFERRED_CWD" "$DEFERRED_SHA" \
    "$base" "$reported" "$pending" "${DECODED[@]}" || return 1
  [ "$dest" = "$file" ] || rm -f -- "$file"
  rm -f -- "${file}.pid" "${file}.rc" "${dest}.pid" "${dest}.rc"
}

deferred_finish_claim() { # <claim> <rc> <sync|async>
  local claim=$1 rc=$2 mode=$3 id
  [ -f "$claim" ] || return 0
  id=$(sed -n 's/^task=//p' "$claim" | head -1)
  if [ "$rc" -eq 0 ]; then
    if deferred_task_id_valid "$id"; then
      deferred_remove_task "$id"
      printf 'started %s\n' "$id"
    else
      rm -f -- "$claim" "${claim}.pid" "${claim}.rc"
    fi
    return 0
  fi
  if [ "$rc" -eq 75 ]; then
    mv -f -- "$claim" "$QUEUE/$(basename -- "$claim")"
    rm -f -- "${claim}.pid" "${claim}.rc"
    return 0
  fi
  if ! deferred_validate "$claim"; then
    deferred_report_stale "$claim"
    return 0
  fi
  deferred_note_failure "$claim" "$rc" "$mode"
}

deferred_reap() {
  local f pid now mtime age rc
  IN_PROGRESS=0
  now=$(date +%s)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    pid=
    if [ -f "${f}.pid" ]; then
      pid=$(tr -d '[:space:]' < "${f}.pid" 2>/dev/null || true)
    fi
    if deferred_is_uint "$pid" && fm_pid_alive "$pid"; then
      IN_PROGRESS=$((IN_PROGRESS + 1))
      continue
    fi
    if [ -z "$pid" ]; then
      mtime=$(stat -c %Y -- "$f" 2>/dev/null || echo 0)
      deferred_is_uint "$mtime" || mtime=0
      age=$((now - mtime))
      if [ "$age" -lt 5 ]; then
        IN_PROGRESS=$((IN_PROGRESS + 1))
        continue
      fi
    fi
    if [ -f "${f}.rc" ]; then
      rc=$(tr -d '[:space:]' < "${f}.rc" 2>/dev/null || true)
      deferred_is_uint "$rc" || rc=1
      deferred_finish_claim "$f" "$rc" async
      continue
    fi
    if ! deferred_load "$f"; then
      STALE_REASON="record is unreadable"
      deferred_report_stale "$f"
      continue
    fi
    deferred_eligibility "$DEFERRED_TASK"
    case "$ELIG" in
      drop) deferred_remove_task "$DEFERRED_TASK" ;;
      error) ;;
      *)
        mv -f -- "$f" "$QUEUE/$(basename -- "$f")"
        rm -f -- "${f}.pid" "${f}.rc"
        ;;
    esac
  done <<EOF
$(deferred_each_order_file "$CLAIM")
EOF
}

deferred_run_claim() { # <claim>
  local claim=$1 rc=0
  printf '%s\n' "$$" > "${claim}.pid" || return 1
  fm_lock_release "$LOCK" || true
  set +e
  (cd -- "$DEFERRED_CWD" && "${DECODED[@]}") >> "$RETRY_LOG" 2>&1 </dev/null
  rc=$?
  DEFERRED_LAUNCH_RC=$rc
  set +e
  printf '%s\n' "$rc" > "${claim}.rc" || return 1
  fm_lock_acquire_wait "$LOCK" || return 1
  if [ -f "$claim" ]; then
    deferred_finish_claim "$claim" "$rc" sync || return 1
  fi
  rm -f -- "${claim}.pid"
}

deferred_publish_pending() { # <file>
  [ -n "$DEFERRED_PENDING" ] || return 0
  [ "$DEFERRED_REPORTED" = 1 ] && return 0
  printf '%s\n' "$DEFERRED_PENDING"
  deferred_write "$1" "$DEFERRED_TASK" "$DEFERRED_ORDER" "$DEFERRED_CWD" "$DEFERRED_SHA" \
    "$DEFERRED_FAILURES" 1 "" "${DECODED[@]}" || return 1
  DEFERRED_REPORTED=1
  DEFERRED_PENDING=
}

deferred_capacity_free() { # prints free_lanes or fails
  local bin line token free
  bin="$SCRIPT_DIR/fm-capacity.sh"
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_SPAWN_DEFERRED_CAPACITY_BIN:-}" ]; then
    bin=$FM_SPAWN_DEFERRED_CAPACITY_BIN
  fi
  [ -x "$bin" ] || return 1
  line=$("$bin" 2>/dev/null) || return 1
  line=${line%%$'\n'*}
  case "$line" in
    capacity:\ *) ;;
    *) return 1 ;;
  esac
  free=
  for token in $line; do
    case "$token" in
      free_lanes=*)
        free=${token#free_lanes=}
        ;;
    esac
  done
  deferred_is_uint "$free" || return 1
  printf '%s' "$free"
}

deferred_retry() {
  local f claim budget free
  fm_lock_acquire_wait "$LOCK" || return 1
  deferred_ensure_dirs || return 1
  deferred_reap || return 1
  if ! deferred_each_order_file "$QUEUE" | grep -q .; then
    return 0
  fi
  free=$(deferred_capacity_free) || return 0
  if [ "$IN_PROGRESS" -eq 0 ]; then
    budget=$free
  else
    budget=0
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    if ! deferred_validate "$f"; then
      deferred_report_stale "$f"
      continue
    fi
    deferred_publish_pending "$f" || return 1
    [ "$DEFERRED_FAILURES" -eq 0 ] || continue
    deferred_eligibility "$DEFERRED_TASK"
    case "$ELIG" in
      drop)
        deferred_remove_task "$DEFERRED_TASK"
        continue
        ;;
      skip) continue ;;
      error)
        printf 'unreadable %s %s\n' "$DEFERRED_TASK" "$ELIG_REASON"
        continue
        ;;
      start) ;;
      *) continue ;;
    esac
    [ "$budget" -ge 1 ] || continue
    claim="$CLAIM/$(basename -- "$f")"
    mv -f -- "$f" "$claim" || continue
    deferred_run_claim "$claim" || return 1
    if [ "$DEFERRED_LAUNCH_RC" -eq 0 ]; then
      budget=$((budget - 1))
    fi
  done <<EOF
$(deferred_each_order_file "$QUEUE")
EOF
}

deferred_sweep() {
  fm_lock_try_acquire "$LOCK" || return 0
  deferred_ensure_dirs || return 1
  if [ -s "$REPORT" ]; then
    cat -- "$REPORT" || return 1
    : > "$REPORT" || return 1
  fi
  deferred_reap || return 1
  [ "$IN_PROGRESS" -eq 0 ] || return 0
  deferred_each_order_file "$QUEUE" | grep -q . || return 0
  fm_lock_release "$LOCK" || return 1
  umask 077
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$0" retry >> "$REPORT" 2>> "$RETRY_LOG" </dev/null &
  else
    nohup "$0" retry >> "$REPORT" 2>> "$RETRY_LOG" </dev/null &
  fi
}

case "${1:-}" in
  record)
    shift
    deferred_ensure_dirs || exit 1
    fm_lock_acquire_wait "$LOCK" || exit 1
    deferred_record "$@" || exit 1
    fm_lock_release "$LOCK" || true
    ;;
  sweep)
    deferred_sweep
    ;;
  retry)
    deferred_retry
    ;;
  *)
    echo 'usage: fm-spawn-deferred.sh record <task-id> -- <argv...> | sweep' >&2
    exit 2
    ;;
esac
