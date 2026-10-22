#!/usr/bin/env bash
NM_HANDOFF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-dod-lib.sh
. "$NM_HANDOFF_LIB_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$NM_HANDOFF_LIB_DIR/fm-task-inbox-lib.sh"

# Worktree HEAD for <task>, or nothing when meta or HEAD cannot be read.
nm_handoff_head() {  # <task>
  local meta wt sha
  meta="$STATE/$1.meta"
  [ -f "$meta" ] && [ -r "$meta" ] || return 0
  wt=$(fm_dod_meta_value "$meta" worktree)
  [ -n "$wt" ] || return 0
  sha=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 0
  fm_dod_is_sha40 "$sha" || return 0
  printf '%s\n' "$sha"
}

# State token from the same crew-state read the rest of this watcher uses.
nm_handoff_state_token() {  # <task>
  local line state
  line=$("$FM_CREW_STATE_BIN" "$1" 2>/dev/null) || true
  case "$line" in
    state:*) ;;
    *) return 0 ;;
  esac
  state=${line#state: }
  state=${state%% *}
  printf '%s\n' "$state"
}

nm_handoff_receipt_head() {
  local line=$1 head
  case "$line" in
    'done [handoff-escalated='*']: '*)
      head=${line#'done [handoff-escalated='}
      head=${head%%']:'*}
      fm_dod_is_sha40 "$head" || return 1
      printf '%s\n' "$head"
      ;;
    *) return 1 ;;
  esac
}

nm_handoff_filter_receipts() {
  local LC_ALL=C line rc
  while :; do
    line=
    IFS= read -r line
    rc=$?
    [ "$rc" -eq 0 ] || [ -n "$line" ] || break
    if nm_handoff_receipt_head "$line" >/dev/null; then
      printf '%*s' "${#line}" '' || return 1
    else
      printf '%s' "$line" || return 1
    fi
    [ "$rc" -eq 0 ] || break
    printf '\n' || return 1
  done < "$1"
}

NM_HANDOFF_SNAPSHOT_DIR=

nm_handoff_snapshot_clear() {
  [ -z "$NM_HANDOFF_SNAPSHOT_DIR" ] || rm -rf "$NM_HANDOFF_SNAPSHOT_DIR"
  NM_HANDOFF_SNAPSHOT_DIR=
}

nm_handoff_snapshot() {
  local task=$1 source="$STATE/$1.status" size ident current
  if [ -z "$NM_HANDOFF_SNAPSHOT_DIR" ]; then
    NM_HANDOFF_SNAPSHOT_DIR=$(mktemp -d "$STATE/.watch-snapshot.XXXXXX") || return 1
  fi
  NM_HANDOFF_STATUS="$NM_HANDOFF_SNAPSHOT_DIR/$task.status"
  NM_HANDOFF_RAW_STATUS="$NM_HANDOFF_STATUS.raw"
  if [ ! -f "$NM_HANDOFF_STATUS" ]; then
    [ -f "$source" ] && [ -r "$source" ] && [ ! -L "$source" ] || return 1
    ident=$(_fm_open_decisions_file_ident "$source") || return 1
    size=$(_fm_status_file_size "$source") || return 1
    size=${size//[[:space:]]/}
    _fm_status_read_span "$source" 0 "$size" > "$NM_HANDOFF_STATUS.tmp" || return 1
    current=$(_fm_open_decisions_file_ident "$source") || return 1
    [ "$current" = "$ident" ] || return 1
    [ "$(_fm_status_file_size "$NM_HANDOFF_STATUS.tmp" | tr -d '[:space:]')" = "$size" ] || return 1
    printf '%s\t%s\n' "$size" "$ident" > "$NM_HANDOFF_STATUS.endpoint" || return 1
    if [ -f "$STATE/$task.meta" ]; then
      cp "$STATE/$task.meta" "$NM_HANDOFF_SNAPSHOT_DIR/$task.meta" || return 1
    fi
    mv "$NM_HANDOFF_STATUS.tmp" "$NM_HANDOFF_RAW_STATUS" || return 1
    nm_handoff_filter_receipts "$NM_HANDOFF_RAW_STATUS" > "$NM_HANDOFF_STATUS.tmp" || return 1
    mv "$NM_HANDOFF_STATUS.tmp" "$NM_HANDOFF_STATUS" || return 1
  fi
  IFS=$'\t' read -r NM_HANDOFF_END NM_HANDOFF_IDENT < "$NM_HANDOFF_STATUS.endpoint"
}

# clean when every captain-relevant line in the not-yet-surfaced span is an
# eligible handoff for <head> (an empty span is clean).
# needs-decision when that span carries a needs-decision line.
# dirty for any other captain-relevant line that is not an eligible handoff.
nm_handoff_span_shape() {  # <status-file> <start> <head>
  local f=$1 start=$2 head=$3 size length tmp line verb shape=clean epoch internal=0 handoffs=0
  size=$(_fm_status_file_size "$f") || { printf 'dirty\n'; return 0; }
  size=${size//[[:space:]]/}
  case "$start" in ''|*[!0-9]*) start=0 ;; esac
  case "$size" in ''|*[!0-9]*) printf 'dirty\n'; return 0 ;; esac
  [ "$start" -le "$size" ] || start=0
  if [ "$start" -ge "$size" ]; then
    printf 'clean\n'
    return 0
  fi
  length=$((size - start))
  tmp=$(mktemp "${TMPDIR:-/tmp}/nm-handoff-span.XXXXXX") || { printf 'dirty\n'; return 0; }
  if ! _fm_status_read_span "$f" "$start" "$length" > "$tmp"; then
    rm -f "$tmp"
    printf 'dirty\n'
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    if status_is_captain_held "$line"; then
      shape=needs-decision
      break
    fi
    status_is_captain_relevant "$line" || continue
    if nm_handoff_receipt_head "$line" >/dev/null; then
      internal=1
      continue
    fi
    epoch=$(fm_dod_nm_handoff_line_epoch "$line" "$head") || epoch=
    if [ -n "$epoch" ]; then
      handoffs=1
      continue
    fi
    verb=$(status_line_verb "$line")
    if [ "$verb" = needs-decision ]; then
      shape=needs-decision
      break
    fi
    shape=dirty
  done < "$tmp"
  rm -f "$tmp"
  if [ "$shape" = clean ] && [ "$internal" -eq 1 ] && [ "$handoffs" -eq 0 ]; then
    shape=internal
  fi
  printf '%s\n' "$shape"
}

fm_nm_handoff_decision() {
  local snapshot=$1 head=$2 ids epoch line count=0 epochs= action=none recorded=0
  fm_dod_is_sha40 "$head" || { printf 'none||\n'; return 0; }
  ids=$(fm_dod_nm_handoff_ids "$snapshot" "$head") || return 1
  while IFS= read -r epoch; do
    [ -n "$epoch" ] || continue
    count=$((count + 1))
    epochs="${epochs}${epochs:+,}$epoch"
  done <<EOF
$ids
EOF
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$(nm_handoff_receipt_head "$line")" = "$head" ]; then
      recorded=1
    fi
  done < "$snapshot"
  if [ "$count" -eq 1 ]; then
    action=steer
  elif [ "$count" -ge 2 ] && [ "$recorded" -eq 0 ]; then
    action=escalate
  fi
  printf '%s|nm-handoff-%s|%s\n' "$action" "$head" "$epochs"
}

nm_handoff_decide() {
  local task=$1 start=$2 status head state decision action epochs shape
  NM_HANDOFF_ACTION=ordinary
  NM_HANDOFF_STEER=0
  NM_HANDOFF_HEAD=
  NM_HANDOFF_KEY=
  NM_HANDOFF_EPOCH=
  NM_HANDOFF_PAYLOAD=
  nm_handoff_snapshot "$task" || return 0
  status=$NM_HANDOFF_RAW_STATUS
  shape=$(nm_handoff_span_shape "$status" "$start" '')
  if [ "$shape" = internal ]; then
    NM_HANDOFF_ACTION=absorb
    return 0
  fi
  head=$(nm_handoff_head "$task") || return 0
  [ -n "$head" ] || return 0
  decision=$(fm_nm_handoff_decision "$status" "$head") || return 0
  action=${decision%%|*}; decision=${decision#*|}
  NM_HANDOFF_KEY=${decision%%|*}; epochs=${decision#*|}
  [ -n "$epochs" ] || return 0
  state=$(nm_handoff_state_token "$task")
  [ "$state" = stopped-before-validation ] || return 0
  NM_HANDOFF_HEAD=$head
  shape=$(nm_handoff_span_shape "$status" "$start" "$head")
  if [ "$action" = steer ]; then
    NM_HANDOFF_STEER=1
    NM_HANDOFF_EPOCH=$epochs
  elif [ "$action" = escalate ]; then
    if ! fm_wake_queued_keys signal | LC_ALL=C grep -Fx "$NM_HANDOFF_KEY" >/dev/null; then
      [ "$shape" = needs-decision ] && return 0
      NM_HANDOFF_ACTION=escalate
      NM_HANDOFF_PAYLOAD="signal: $(cd "$STATE" && pwd)/$task.status stopped-before-validation head=$head lines=$epochs"
      if [ "$shape" = dirty ]; then
        nm_handoff_publish "$task" || exit 1
        NM_HANDOFF_ACTION=ordinary
      fi
      return 0
    fi
  fi
  [ "$shape" != clean ] || NM_HANDOFF_ACTION=absorb
  return 0
}

nm_handoff_daemon_task() {
  local task=$1 STATE=$2 start=$3 SCRIPT_DIR=${FM_NM_HANDOFF_SEND_DIR:-$NM_HANDOFF_LIB_DIR}
  nm_handoff_decide "$task" "$start"
  if [ "$NM_HANDOFF_STEER" = 1 ]; then
    nm_handoff_send_steer "$task" || { NM_HANDOFF_ACTION=ordinary; return 1; }
  fi
  if [ "$NM_HANDOFF_ACTION" = escalate ]; then
    nm_handoff_publish "$task" || return 1
    NM_HANDOFF_ACTION=absorb
  fi
}

# 0 when <task>'s inbox or its handled directory already holds this exact body.
nm_handoff_steer_present() {  # <task> <text>
  local dir f body
  dir=$(fm_task_inbox_dir "$STATE" "$1")
  for f in "$dir"/*.msg "$dir/handled"/*.msg; do
    [ -f "$f" ] || continue
    body=$(fm_task_inbox_body "$f" 2>/dev/null) || continue
    [ "$body" = "$2" ] && return 0
  done
  return 1
}

# Send the one fixed steer unless that exact body is already recorded.
# A repeat call would ring the doorbell again, so a present body skips fm-send.
nm_handoff_send_steer() {  # <task>
  local text err
  text="The done line at=${NM_HANDOFF_EPOCH} for head ${NM_HANDOFF_HEAD} is the handoff, not completion. Start validation now with /no-mistakes."
  nm_handoff_steer_present "$1" "$text" && return 0
  err=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_IDEMPOTENT=1 \
    "$SCRIPT_DIR/fm-send.sh" "$1" "$text" 2>&1) || {
    printf 'nm handoff steer failed for %s: %s\n' "$1" "$err" >&2
    return 1
  }
  return 0
}

nm_handoff_publish() {
  local rc=0 line recorded=0 status="$STATE/$1.status"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  if fm_wake_queued_keys_locked signal | LC_ALL=C grep -Fx "$NM_HANDOFF_KEY" >/dev/null; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  if [ ! -f "$status" ] || [ ! -r "$status" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$(nm_handoff_receipt_head "$line")" = "$NM_HANDOFF_HEAD" ]; then
      recorded=1
      break
    fi
  done < "$status"
  if [ "$recorded" -eq 1 ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  fm_wake_append_locked signal "$NM_HANDOFF_KEY" "$NM_HANDOFF_PAYLOAD" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'done [handoff-escalated=%s]: %s\n' "$NM_HANDOFF_HEAD" "$NM_HANDOFF_PAYLOAD" >> "$STATE/$1.status" || rc=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$rc"
}

nm_handoff_daemon_span() {
  local task=$1 state=$2 start=$3 output=$4 span='' tail rc=1 result
  if [ ! -e "$state/$task.status" ]; then
    [ ! -L "$state/$task.status" ] || return 2
    printf -v "$output" '%s' ''
    return 1
  fi
  nm_handoff_daemon_task "$task" "$state" "$start" || return 2
  [ -f "$NM_HANDOFF_STATUS" ] || return 2
  result="${NM_HANDOFF_END}"$'\t'"${NM_HANDOFF_IDENT}"
  if [ "$NM_HANDOFF_ACTION" != absorb ]; then
    status_span_first_actionable_record "$NM_HANDOFF_STATUS" "$start" span
    rc=$?
    [ "$rc" -ne 2 ] || return 2
    if [ "$rc" -eq 0 ]; then
      tail=${span#*$'\t'}; tail=${tail#*$'\t'}
      result="${result}"$'\t'"${tail}"
    fi
  fi
  printf -v "$output" '%s' "$result"
  return "$rc"
}
