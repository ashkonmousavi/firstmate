#!/usr/bin/env bash
# fm-task-inbox-lib.sh - the per-task steering inbox: durable records plus a
# constant doorbell.
#
# ONE owner of the steering-inbox contract: the record format, sequence
# allocation, the idempotent re-enqueue dedup, the handled/ acknowledgement,
# the self-describing doorbell line, and the watcher's re-ring ladder policy.
# bin/fm-send.sh writes and rings locally, the host-local remote steer leg
# (bin/fm-remote-secondmate-control.sh cmd_send) writes idempotently and rings
# on the remote host, bin/fm-watch.sh polls and re-rings, and the brief
# scaffold (bin/fm-brief.sh) tells the worker how to read and acknowledge;
# none of them restates the format.
#
# Design (captain-adopted, data/fm-send-reliability-reframe-s1/report.md): the
# payload moves to the filesystem, which is reliable; the terminal carries only
# a short constant doorbell line. While the endpoint remains available, that
# line does not need to be reliable because ringing it again is free. A
# duplicated doorbell is a no-op by construction (the worker finds the inbox
# empty or already handled), and a swallowed doorbell is detected by the
# absence of the worker's acknowledgement and re-rung on a bounded schedule.
# A positively dead or missing endpoint bypasses that schedule without being
# typed into, and its unhandled record surfaces through the ordinary stale wake
# into stuck-crewmate-recovery.
#
# Layout under <state-dir>:
#   <task>.inbox/NNN.msg       one durable steer, numeric sequence, atomic rename
#   <task>.inbox/handled/      the worker's `mv` here IS the acknowledgement
#   <task>.inbox/.seq.lock     serializes sequence allocation across writers
#                              (the session and the away daemon)
#   <task>.inbox/.ring-state   watcher re-ring ladder: "<msg>\t<count>\t<epoch>"
#   <task>.inbox/.busy-state   consecutive busy deferrals: "<msg>\t<count>"
#   <task>.inbox/NNN.ring-reason   last ring result for that record: "rc=<n> token=<token>"
#                              (fm_task_inbox_ring owns the tokens; never part of the .msg)
#   <task>.inbox/.escalated    oldest-message name already surfaced as stale,
#                              so later polls suppress another escalation
#   <task>.inbox/.retry-ring   name of a fire-and-forget record still owed its
#                              one retry ring (fm_task_inbox_mark_retry)
#
# Record format (fm_task_inbox_write / fm_task_inbox_body):
#   schema=fm-task-inbox.v1
#   at=<utc timestamp>
#   delivery=fire-and-forget   present only when the re-ring ladder must ignore it
#                              (it still gets one retry ring; see below)
#   --
#   <exact message text; newlines are legal; a marked secondmate request keeps
#    its from-firstmate marker and corr token verbatim in this body>
#
# Sequence numbers are never reused within a task: allocation scans both the
# inbox root and handled/, so a message is processed at most once per worker
# lifetime even if every doorbell is duplicated. Concurrent writers serialize
# on .seq.lock; the worst racing outcome is ordering, never loss.
#
# Re-ring ladder (fm_task_inbox_due_action): an unhandled message older than
# FM_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring or be skipped to protect another draft in a proven pending
# composer; an unsubmitted copy of this doorbell is retried. After
# FM_TASK_INBOX_RING_MAX attempts without an acknowledgement it escalates. The
# caller owns the busy and recovery-grade endpoint checks: due actions deferred
# by a busy pane consume a separate durable consecutive-poll budget,
# FM_TASK_INBOX_BUSY_MAX. At that bound the same escalation path surfaces a
# stuck-busy reason without typing. A non-busy due check or acknowledgement resets
# this budget. Fire-and-forget retries remain outside escalation. A positively
# dead or missing endpoint skips delivery and the ladder and escalates directly.
# This library owns the schedule, durable budgets, and escalation marker.
# If delivery-attempt or busy-deferral bookkeeping fails while the record remains unhandled,
# the caller surfaces that failure instead of retrying silently; a concurrently
# removed inbox is a quiet no-op. Escalation deliberately queues the wake before
# writing the deduplication marker: normal polls surface a message once, while a
# local crash or marker failure may produce a rare duplicate rather than silently
# lose a wake. The remote leg preserves wake identity as described below.
#
# Retry ring (fm_task_inbox_mark_retry): only while config/wait-no-turns is
# present. A fire-and-forget record never enters the ladder, but when
# fm-send's ring at enqueue did not land
# (fm_task_inbox_ring returned 1, 2 or 4) it marks the record, and one grace later
# the due action is `retry`: once the worker has no open decision of its own,
# the watcher rings once more and spends the mark
# whatever the result, so the record never rings a third time and never
# escalates. A waiting worker does not poll its inbox (bin/fm-brief.sh), so
# without this retry the record could sit unread until a checkpoint. A pending ordinary record's
# ladder rings the same inbox, so the retry waits behind it, and an
# acknowledged record drops its mark.
#
# Remote leg: a remote secondmate's records live in its host's parent-route
# inbox, and the parent watcher (remote_inbox_tick in bin/fm-watch.sh) drives
# this same ladder there through bin/fm-remote-secondmate-control.sh's inbox
# verb: due action and ring run on the remote host, the ladder state stays
# beside the records, and the parent queues the escalation wake. A provably
# busy mate defers the ring like the local ladder does: the deferral spends no
# ladder attempt, advances the same FM_TASK_INBOX_BUSY_MAX budget, and at that
# bound the parent queues the one stuck-busy wake without typing. A later idle
# check rings through the ordinary due action, once per grace, and an idle
# failure still counts. The enqueue ring still rings a busy mate, and no
# fire-and-forget retry is owed there. Unknown is not busy, and the escalation
# marker is never cleared when the mate later goes idle.
# The parent passes its effective grace and ring maximum to each remote due
# check; individual hops have a fixed 30-second bound, and ordinary supervision
# runs the pass detached from its cycle, so a slow host never delays the
# watcher's own liveness.
# A state-scoped pass lock prevents overlap across watcher restarts; detached
# passes leave a durable wake handoff for the next watcher to surface even if
# the launching watcher exits before the pass finishes.
# Failed hops leave the remote refusal's first stderr line (or exit status) in
# the parent's triage log and retry on a later tick, without waking firstmate
# for routine re-rings.
# Confirmed unavailable endpoints or unwritable ring bookkeeping escalate through
# the same stale-wake path as a spent budget. Each record uses the stable wake
# key remote-inbox:<id>:<record>, so a failed escalation-marker hop is retried
# without appending another wake while that key remains queued; the remote
# escalation marker suppresses later due actions once written.
#
# Inbox names containing bytes outside printable ASCII are unsupported. The
# doorbell refuses them rather than sending terminal control bytes to a pane.
#
# fm_task_inbox_ring requires bin/fm-backend.sh's dispatch (sourced below); the
# other helpers are dependency-light. Sourced by bin/fm-send.sh, bin/fm-watch.sh,
# and tests. No side effects on source beyond its sourced libraries.
#
# Tunables (env):
#   FM_TASK_INBOX_GRACE_SECS   default 90; delivery-attempt grace and spacing
#   FM_TASK_INBOX_RING_MAX     default 3; delivery attempts before escalation
#   FM_TASK_INBOX_BUSY_MAX     default 2; consecutive busy-deferred due polls before escalation

_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Both dependencies are canonical lint roots in their own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-backend.sh"
# The submit-signal reads below need the busy record contract even when no
# tmux backend has been sourced yet.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-busy-lib.sh"

FM_TASK_INBOX_SCHEMA='fm-task-inbox.v1'
FM_TASK_INBOX_GRACE_DEFAULT=90
FM_TASK_INBOX_RING_MAX_DEFAULT=3
FM_TASK_INBOX_BUSY_MAX_DEFAULT=2
FM_TASK_INBOX_LOCK_WAIT_DEFAULT=5

fm_task_inbox_grace_secs() {
  local g=${FM_TASK_INBOX_GRACE_SECS:-$FM_TASK_INBOX_GRACE_DEFAULT}
  case "$g" in ''|*[!0-9]*) g=$FM_TASK_INBOX_GRACE_DEFAULT ;; esac
  printf '%s' "$g"
}

fm_task_inbox_ring_max() {
  local m=${FM_TASK_INBOX_RING_MAX:-$FM_TASK_INBOX_RING_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_RING_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

fm_task_inbox_busy_max() {
  local m=${FM_TASK_INBOX_BUSY_MAX:-$FM_TASK_INBOX_BUSY_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_BUSY_MAX_DEFAULT ;; esac
  # Check the length before numeric comparison so oversized input cannot overflow.
  if [ "${#m}" -gt 9 ] || [ "$m" -eq 0 ]; then
    m=$FM_TASK_INBOX_BUSY_MAX_DEFAULT
  fi
  printf '%s' "$m"
}

# Persist before returning the new count, so a fresh watcher continues the same
# bounded wait. A removed or acknowledged record is a quiet no-op.
fm_task_inbox_record_busy() {  # <state-dir> <task-id> <record-path>
  local dir base previous count
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  { IFS=$(printf '\t') read -r previous count < "$dir/.busy-state"; } 2>/dev/null || true
  [ "${previous:-}" = "$base" ] || count=0
  case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
  [ -f "$3" ] || { printf '0'; return 0; }
  count=$((count + 1))
  if ! { printf '%s\t%s\n' "$base" "$count" > "$dir/.busy-state"; } 2>/dev/null; then
    [ -f "$3" ] || { printf '0'; return 0; }
    return 1
  fi
  printf '%s' "$count"
}

fm_task_inbox_clear_busy() {  # <state-dir> <task-id>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  rm -f "$dir/.busy-state" 2>/dev/null
}

fm_task_inbox_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox' "$1" "$2"
}

fm_task_inbox_handled_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox/handled' "$1" "$2"
}

# Numeric sequence of one record basename, or fail for a non-record name.
fm_task_inbox_seq_of() {  # <basename>
  local n=${1%.msg}
  [ "$n" != "$1" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$n))"
}

# Next unused sequence, scanning the inbox root AND handled/ so an
# acknowledged sequence is never reissued. Caller must hold .seq.lock.
fm_task_inbox_next_seq() {  # <inbox-dir>
  local dir=$1 max=0 d f n
  for d in "$dir" "$dir/handled"; do
    for f in "$d"/*.msg; do
      [ -e "$f" ] || continue
      n=$(fm_task_inbox_seq_of "${f##*/}") || continue
      [ "$n" -le "$max" ] || max=$n
    done
  done
  printf '%03d' "$((max + 1))"
}

fm_task_inbox_lock_acquire() {  # <lock-path>
  local lock=$1 wait=${FM_TASK_INBOX_LOCK_WAIT_SECS:-$FM_TASK_INBOX_LOCK_WAIT_DEFAULT}
  local deadline probe
  case "$wait" in ''|*[!0-9]*) wait=$FM_TASK_INBOX_LOCK_WAIT_DEFAULT ;; esac
  probe=$(mktemp "${lock%/*}/.lock-probe.XXXXXX") || return 1
  rm -f "$probe" || return 1
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    fm_lock_try_create "$lock" && return 0
  fi
  deadline=$(( $(date +%s) + wait ))
  while ! fm_lock_try_acquire "$lock"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# Write one record into the next sequence slot: temp-write, then atomic
# rename. Prints the record path. Caller must hold .seq.lock.
_fm_task_inbox_write_record_locked() {  # <inbox-dir> <text> [delivery-mode]
  local dir=$1 text=$2 delivery_mode=${3:-} seq tmp rec status=0
  seq=$(fm_task_inbox_next_seq "$dir")
  rec="$dir/$seq.msg"
  tmp=$(mktemp "$dir/.staging.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_TASK_INBOX_SCHEMA"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ "$delivery_mode" != fire-and-forget ] || printf 'delivery=fire-and-forget\n'
    printf -- '--\n'
    printf '%s' "$text"
  } > "$tmp" && mv "$tmp" "$rec" || status=1
  [ "$status" -eq 0 ] || { rm -f "$tmp"; return 1; }
  printf '%s' "$rec"
}

# Durably enqueue one steer: temp-write, then atomic rename into the next
# sequence slot. Prints the record path. Fails without a partial record.
fm_task_inbox_write() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock rec status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# Durably enqueue one steer at most once: when a record with the exact same
# body already exists - unhandled or already acknowledged in handled/ - no new
# record is written and the existing record's path is printed instead.
# This is the enqueue primitive for a transport that can fail with completion
# unknown (the remote steer leg over ssh): the caller's safe recovery is to run
# the same enqueue again, and this dedup is what makes the re-run land on the
# same record instead of a duplicate the worker would act on twice. Two
# distinct logical requests never collapse in practice because a marked
# secondmate request embeds a per-request correlation token in its body. The
# local plane keeps plain fm_task_inbox_write: its outcome is synchronous, so
# a repeated identical local steer is a deliberate new instruction.
# Only records of the exact byte size this body would produce are compared:
# the header above is fixed-width, so one find call replaces per-record reads
# that grew with handled/ and, on a loaded host, outlasted the remote send
# budget before the doorbell could ring.
fm_task_inbox_write_idempotent() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock want have f size rec='' status=0
  local -a candidates=()
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if want=$(mktemp "$dir/.dedup.XXXXXX") && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    if printf '%s' "$text" > "$want" && size=$(wc -c < "$want"); then
      size=$((size + ${#FM_TASK_INBOX_SCHEMA} + 35))
      [ "$delivery_mode" != fire-and-forget ] || size=$((size + 25))
      while IFS= read -r f; do
        candidates+=("$f")
      done < <(find "$dir" "$dir/handled" -maxdepth 1 -type f -name '*.msg' -size "${size}c" 2>/dev/null)
      for f in ${candidates[@]+"${candidates[@]}"}; do
        if [ ! -e "$f" ]; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              [ -e "$f" ] || continue
              ;;
            *) continue ;;
          esac
        fi
        if [ "$delivery_mode" = fire-and-forget ]; then
          fm_task_inbox_is_fire_and_forget "$f" || continue
        elif fm_task_inbox_is_fire_and_forget "$f"; then
          continue
        fi
        if ! fm_task_inbox_body "$f" > "$have" 2>/dev/null; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              fm_task_inbox_body "$f" > "$have" 2>/dev/null || continue
              ;;
            *) continue ;;
          esac
        fi
        cmp -s "$want" "$have" || continue
        [ ! -e "$dir/handled/${f##*/}" ] || f="$dir/handled/${f##*/}"
        rec=$f
        break
      done
    else
      status=1
    fi
    rm -f "$want" "$have"
  else
    rm -f "${want:-}" 2>/dev/null || true
    status=1
  fi
  if [ "$status" -eq 0 ] && [ -z "$rec" ]; then
    rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# The exact enqueued text back out of a record.
fm_task_inbox_body() {  # <record-path>
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    if [ "$line" = -- ]; then
      cat
      return 0
    fi
  done < "$1"
  return 1
}

# The constant self-describing doorbell line for the inbox containing a record.
# It names the inbox by the literal "$FM_TASK_INBOX", which bin/fm-spawn.sh
# exports into every launch as the inbox's absolute path, so the worker can
# resolve it from its own environment even after losing its brief context.
# The short `<task>.inbox` name follows as the fallback for a worker launched
# before that export, whose brief carries the full path (bin/fm-dod-lib.sh
# role contract, bin/fm-brief.sh inbox section). No absolute path is printed,
# so the line's length never grows with the home's depth: a long line wraps
# past what a harness composer read can prove, and a Herdr submit then reports
# it did not reach the pane on every re-ring. The leading `: ` is the POSIX
# shell no-op, so the same line typed into a pane whose agent has exited (a
# bare shell) runs nothing; see the dead-pane note in the header. A
# non-printable inbox name fails without output so terminal controls never
# reach the pane's line discipline.
fm_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs name quoted LC_ALL=C
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  abs=${abs%/handled}
  name=${abs##*/}
  case "$name" in
    ''|*[![:print:]]*) return 1 ;;
  esac
  quoted=$(printf '%s' "$name" | sed "s/'/'\\\\''/g")
  printf ": Firstmate instruction waiting: list \"\$FM_TASK_INBOX\"/*.msg in your '%s' steering inbox, read and act on each in numeric order, then mv each into its handled/." \
    "$quoted"
}

FM_TASK_INBOX_SIGNAL_STATE=
FM_TASK_INBOX_SIGNAL_ID=
FM_TASK_INBOX_SIGNAL_HARNESS=
FM_TASK_INBOX_SIGNAL_BASELINE=
fm_task_inbox_signal_prepare() {
  local dir=${2%/*} abs name state meta harness baseline
  FM_TASK_INBOX_SIGNAL_STATE=
  FM_TASK_INBOX_SIGNAL_ID=
  FM_TASK_INBOX_SIGNAL_HARNESS=
  FM_TASK_INBOX_SIGNAL_BASELINE=
  [ "$1" = tmux ] || return 1
  abs=$(cd "$dir" 2>/dev/null && pwd) || return 1
  abs=${abs%/handled}
  name=${abs##*/}
  state=${abs%/*}
  case "$name" in
    *.inbox) name=${name%.inbox} ;;
    *) return 1 ;;
  esac
  meta="$state/$name.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  harness=$(fm_meta_get "$meta" harness)
  baseline=$(fm_busy_submit_baseline "$state" "$name" "$harness" "$3") || return 1
  FM_TASK_INBOX_SIGNAL_STATE=$state
  FM_TASK_INBOX_SIGNAL_ID=$name
  FM_TASK_INBOX_SIGNAL_HARNESS=$harness
  FM_TASK_INBOX_SIGNAL_BASELINE=$baseline
}

fm_task_inbox_confirmed_enter() {
  local backend=$1 target=$2 line=$3 label=${4:-} i=0 cstate
  while [ "$i" -lt 5 ]; do
    fm_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || return 2
    i=$((i + 1))
    if FM_SUBMIT_SIGNAL_STATE=$FM_TASK_INBOX_SIGNAL_STATE FM_SUBMIT_SIGNAL_ID=$FM_TASK_INBOX_SIGNAL_ID \
         FM_SUBMIT_SIGNAL_HARNESS=$FM_TASK_INBOX_SIGNAL_HARNESS FM_SUBMIT_SIGNAL_BASELINE=$FM_TASK_INBOX_SIGNAL_BASELINE \
         fm_busy_submit_wait 2; then
      return 0
    fi
    cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
    case "$cstate" in
      empty) return 0 ;;
      pending) fm_task_inbox_composer_holds "$backend" "$target" "$line" "$label" || return 4 ;;
      *) return 4 ;;
    esac
  done
  return 4
}

# Ring best-effort, protecting a proven foreign draft. An exact own-doorbell
# draft receives Enter only; otherwise type the line once. Both paths allow
# five Enter presses with two-second confirmation windows (up to ten seconds).
# A fresh line uses the backend's submit verdict. An existing draft requires a
# cleared composer or matching receipt under bin/fm-busy-lib.sh's contract;
# an unknown or unreadable composer ends confirmation without another blind
# Enter. Backend-specific confirmation boundaries live in docs/tmux-backend.md
# and docs/herdr-backend.md.
# Returns 0 submit confirmed, 1 foreign pending draft skipped, 2 backend send
# failed, 3 positively dead/missing endpoint skipped, 4 submit unconfirmed.
# The inbox record remains durable for every ring result; only the worker's
# move into handled/ acknowledges that the steer was acted on.
# Ambiguous pre-checks still permit a fresh constant doorbell, so classifier
# uncertainty cannot starve steering. Accepted residual race: the endpoint can
# exit between the liveness check and typing; the ': ' prefix protects complete
# shell lines only, not suffixes typed after such an exit.
fm_task_inbox_ring() {  # <backend> <target> <record-path> [expected-label]
  local rc=0
  FM_TASK_INBOX_RING_REASON=
  _fm_task_inbox_ring_step "$@" || rc=$?
  fm_task_inbox_note_reason "$3" "$rc" "$FM_TASK_INBOX_RING_REASON"
  return "$rc"
}

# Reason for the last ring result, so the next failure names its step. The
# stdout verdicts and the 0-4 return codes above are unchanged: this is
# logging only. fm_task_inbox_ring owns the token: it leaves it in
# FM_TASK_INBOX_RING_REASON (read it right after the call) and records it in
# the sibling <inbox>/<seq>.ring-reason as one line, "rc=<n> token=<token>",
# replaced on every attempt for that record; the .msg bytes are never touched.
# A backend adapter only offers a finer token through the sink file named by
# FM_RING_REASON_SINK (fm_backend_herdr_note_reason), because it runs in a
# command substitution and cannot set a variable here. Tokens: ok, agent-dead,
# foreign-pending-draft, doorbell-rejected, submit-refused (backend refused
# before typing, such as a blocking dialog), backend-send-failed, and
# submit-unconfirmed; herdr adds composer-unreadable, composer-nonempty,
# literal-send-failed, payload-not-shown, clear-unverified, enter-send-failed,
# status-unknown and blocking-dialog; the remote busy deferral adds
# busy-deferred and stuck-busy.
_fm_task_inbox_ring_step() {  # <backend> <target> <record-path> [expected-label]
  local backend=$1 target=$2 rec=$3 label=${4:-} line cstate verdict rc sink
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    dead|missing) FM_TASK_INBOX_RING_REASON=agent-dead; return 3 ;;
  esac
  line=$(fm_task_inbox_doorbell_line "$rec") || { FM_TASK_INBOX_RING_REASON=doorbell-rejected; return 2; }
  fm_task_inbox_signal_prepare "$backend" "$rec" "$line" || true
  cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
  if [ "$cstate" = pending ]; then
    fm_task_inbox_composer_holds "$backend" "$target" "$line" "$label" \
      || { FM_TASK_INBOX_RING_REASON=foreign-pending-draft; return 1; }
    rc=0
    fm_task_inbox_confirmed_enter "$backend" "$target" "$line" "$label" || rc=$?
    case "$rc" in
      0) FM_TASK_INBOX_RING_REASON=ok ;;
      2) FM_TASK_INBOX_RING_REASON=enter-send-failed ;;
      *) FM_TASK_INBOX_RING_REASON=submit-unconfirmed ;;
    esac
    return "$rc"
  fi
  sink=$(mktemp "${TMPDIR:-/tmp}/fm-ring-reason.XXXXXX" 2>/dev/null) || sink=
  FM_RING_REASON_SINK=$sink
  if ! verdict=$(FM_SUBMIT_SIGNAL_STATE=$FM_TASK_INBOX_SIGNAL_STATE FM_SUBMIT_SIGNAL_ID=$FM_TASK_INBOX_SIGNAL_ID \
       FM_SUBMIT_SIGNAL_HARNESS=$FM_TASK_INBOX_SIGNAL_HARNESS FM_SUBMIT_SIGNAL_BASELINE=$FM_TASK_INBOX_SIGNAL_BASELINE \
       fm_backend_send_text_submit "$backend" "$target" "$line" 5 2 0.3 "$label" 2>/dev/null); then
    FM_TASK_INBOX_RING_REASON=submit-refused
    FM_RING_REASON_SINK=
    [ -z "$sink" ] || rm -f "$sink"
    return 2
  fi
  FM_TASK_INBOX_RING_REASON=$(head -1 "$sink" 2>/dev/null || true)
  FM_RING_REASON_SINK=
  [ -z "$sink" ] || rm -f "$sink"
  case "$verdict" in
    empty) FM_TASK_INBOX_RING_REASON=ok; return 0 ;;
    send-failed) : "${FM_TASK_INBOX_RING_REASON:=backend-send-failed}"; return 2 ;;
    *) : "${FM_TASK_INBOX_RING_REASON:=submit-unconfirmed}"; return 4 ;;
  esac
}

# The sibling reason file of one record (see the ring header above).
fm_task_inbox_reason_file() {  # <record-path>
  printf '%s.ring-reason' "${1%.msg}"
}

# Replace the record's reason line. Best-effort: a missing inbox or an
# unwritable sibling never changes a ring result.
fm_task_inbox_note_reason() {  # <record-path> <rc> <token>
  local f
  [ -n "${3:-}" ] || return 0
  f=$(fm_task_inbox_reason_file "$1")
  [ -d "${f%/*}" ] || return 0
  { printf 'rc=%s token=%s\n' "$2" "$3" > "$f"; } 2>/dev/null || true
}

# Token of the last recorded attempt for one record, or nothing.
fm_task_inbox_last_reason() {  # <record-path>
  local line
  line=$(head -1 "$(fm_task_inbox_reason_file "$1")" 2>/dev/null || true)
  case "$line" in
    *' token='*) printf '%s' "${line##* token=}" ;;
  esac
}

# Whether the composer's content is exactly <line>.
# Tmux and herdr use the same screen their pending verdict uses, not a plain
# tail. fm_composer_text_is_own_doorbell ignores Cursor's same-row stop hint.
fm_task_inbox_composer_holds() {  # <backend> <target> <line> [expected-label]
  local backend=$1 target=$2 line=$3 label=${4:-} cap held caps
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux)
      cap=$(fm_tmux_composer_capture "$target") || return 1
      caps=$(fm_tmux_composer_caps)
      held=$(fm_composer_extract_selected_content "$caps" "$cap") || return 1
      ;;
    herdr)
      held=$(fm_backend_herdr_composer_content "$target") || return 1
      ;;
    *)
      cap=$(fm_backend_capture "$backend" "$target" "$FM_COMPOSER_CAPTURE_LINES" "$label" 2>/dev/null) || return 1
      held=$(fm_composer_extract_selected_content styled=0 "$cap") || return 1
      ;;
  esac
  fm_composer_text_is_own_doorbell "$held" "$line"
}

fm_task_inbox_is_fire_and_forget() {  # <record-path>
  local rec=$1
  if [ ! -f "$rec" ]; then
    rec="${rec%/*}/handled/${rec##*/}"
    [ -f "$rec" ] || return 1
  fi
  awk '
    $0 == "--" { exit }
    $0 == "delivery=fire-and-forget" { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$rec"
}

# Oldest escalation-tracked unhandled record, or fail when none is due.
fm_task_inbox_oldest_unhandled() {  # <state-dir> <task-id>
  local dir best='' best_n=0 f n
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    fm_task_inbox_is_fire_and_forget "$f" && continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    if [ -z "$best" ] || [ "$n" -lt "$best_n" ]; then
      best=$f
      best_n=$n
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# Owe a fire-and-forget record its one retry ring (see the header). A newer
# mark replaces an older one: a ring names the whole inbox, not one record.
fm_task_inbox_mark_retry() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  { printf '%s\n' "${3##*/}" > "$dir/.retry-ring"; } 2>/dev/null
}

# Spend the retry mark after its ring, only while it still names that record:
# a newer mark written meanwhile is owed its own retry and survives. Fails only
# when the processed record's mark stays behind.
fm_task_inbox_clear_retry() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ "$(cat "$dir/.retry-ring" 2>/dev/null)" = "${3##*/}" ] || return 0
  rm -f "$dir/.retry-ring" 2>/dev/null
}

# The re-ring ladder decision for one task. Prints exactly one of:
#   quiet                     nothing due (healthy, within grace or spacing,
#                             or already escalated for the current oldest)
#   ring <record-path>        one doorbell re-ring is due
#   escalate <record-path> <count>   attempt budget spent; surface as stale
#   retry <record-path>       a fire-and-forget record's one retry ring is due
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
fm_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base now grace max ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  if ! oldest=$(fm_task_inbox_oldest_unhandled "$1" "$2"); then
    rm -f "$dir/.ring-state" "$dir/.escalated" "$dir/.busy-state" 2>/dev/null || true
    # The one retry ring exists only while config/wait-no-turns is present.
    # Absent, a mark is left untouched and the inbox stays quiet, as before.
    if [ -e "${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}/wait-no-turns" ]; then
      base=$(cat "$dir/.retry-ring" 2>/dev/null || true)
      if ! fm_task_inbox_seq_of "$base" >/dev/null || [ ! -f "$dir/$base" ]; then
        rm -f "$dir/.retry-ring" 2>/dev/null || true
      elif [ "$(fm_path_age "$dir/.retry-ring")" -ge "$(fm_task_inbox_grace_secs)" ]; then
        printf 'retry %s' "$dir/$base"
        return 0
      fi
    fi
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  grace=$(fm_task_inbox_grace_secs)
  if [ "$(fm_path_age "$oldest")" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  count=0
  last=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  if [ -n "$rec_base" ] && [ "$rec_base" != "$base" ]; then
    count=0
    last=0
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$(cat "$dir/.escalated" 2>/dev/null || true)" = "$base" ]; then
    printf 'quiet'
    return 0
  fi
  max=$(fm_task_inbox_ring_max)
  if [ "$count" -ge "$max" ]; then
    printf 'escalate %s %s' "$oldest" "$count"
    return 0
  fi
  now=$(date +%s)
  if [ "$((now - last))" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  printf 'ring %s' "$oldest"
}

# Advance the ladder after a delivery attempt. A failed ring or a composer-
# protected skip still consumes budget so neither an unreadable pane nor a
# permanently blocked composer can retry silently forever. A positively dead or
# missing endpoint never enters the ladder: the watcher escalates it directly.
# A concurrently removed inbox is a successful no-op; otherwise failure means
# the caller must surface the unwritable ladder while the record remains
# unhandled.
fm_task_inbox_record_ring() {  # <state-dir> <task-id> <record-path>
  local dir base ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  count=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  [ "$rec_base" = "$base" ] || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ -d "$dir" ] || return 0
  if ! { printf '%s\t%s\t%s\n' "$base" "$((count + 1))" "$(date +%s)" > "$dir/.ring-state"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

# Mark the current oldest as escalated after its stale wake is durably queued,
# suppressing another wake on later polls. Wake-before-marker ordering favors
# at-least-once recovery: a crash or marker failure can cause a rare duplicate;
# stuck-crewmate-recovery owns the message from here.
fm_task_inbox_record_escalated() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  if ! { printf '%s\n' "${3##*/}" > "$dir/.escalated"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}
