#!/usr/bin/env bash
# fm-lane-release.sh - free the lane (seat) of a worker whose job is finished
# and landed, keeping its local copy.
#
# Usage:
#   fm-lane-release.sh sweep            one bounded pass; the registered check runs it
#   fm-lane-release.sh --audit          read-only report of seats held by finished work
#   fm-lane-release.sh arm | disarm     write and register, or remove, state/lane-release.check.sh
#   fm-lane-release.sh exit-worker <id> <spawn_gen>
#                                       internal: the detached exit a sweep starts
#
# Setting: config/lane-release, exactly one line containing off, audit, or on
# with no surrounding whitespace, per home and never inherited
# (it is deliberately absent from FM_INHERITABLE_CONFIG in
# bin/fm-config-inherit-lib.sh):
#   off    (also: file absent) `sweep` and the check do nothing and print nothing.
#   audit  `sweep` evaluates every worker and appends a WOULD_RELEASE ledger row
#          once per unchanged candidate, but never stops a worker.
#   on     `sweep` releases finished-and-landed workers.
# Any other value, including an empty or blank file: `sweep` releases nothing
# and reports the value once while unchanged, with newlines and carriage returns
# escaped so the report occupies one line.
# `--audit` is an explicit read-only query and runs in any
# setting; its first line names the setting.
#
# WHAT IS RELEASED (the promise). Only two classes, and only while the agent is
# live, idle, and nothing has happened since the finished evidence:
#   merged-ship  a ship whose recorded pr= has merged. Landed evidence is the
#                merge record bin/fm-pr-merge.sh and the merge poll write through
#                bin/fm-merge-outcome-lib.sh: state/<id>.pr-poll-merge-notified,
#                whose provider/host/path/number must equal the parsed pr=. That
#                record has no timestamp field, so the merge anchor is its file
#                mtime (the moment this home confirmed the merge, never earlier
#                than the real merge, which is conservative for the checks
#                below). A closed-unmerged PR writes no such record and is never
#                released. A ship that never wrote `done` (merged while idle) is
#                released on the merge anchor alone.
#   scout        a scout whose data/<id>/report.md exists, whose completion gate
#                passes (`bin/fm-captain-hold.sh verify <id>` exits 0; it exits 1
#                on a failed gate and 2 on unreadable evidence), that is not
#                held for the captain (`fm-captain-hold.sh open <id>` exit 0 means
#                held: a decision, promotion included, is still pending), that
#                hosts no task-owned Lavish board (no state/procevent/*.source
#                with owner_task=<id>; an absent registry means no board,
#                unreadable registry or source evidence keeps the seat and is
#                unknown in audit), and whose promotion has not begun
#                (no data/<id>/ship-instructions.md).
# Everything else keeps its seat: an open-PR ship (reported by --audit as
# kept-open-pr), a local-only ship (bin/fm-merge-local.sh writes no per-task
# landed record, so landing cannot be proven from local state), a held or
# board-hosting scout, and any worker that is not proven idle and quiet.
# Promotion after a release still works: bin/fm-promote.sh takes the control
# lock, requires kind=scout, and never checks liveness, so the promoted contract
# reaches the kept copy through `bin/fm-control.sh <id> relaunch --note ...`.
#
# FINISHED (every predicate below is a function in this file):
#   done line     the raw status log (never only its latest event, because a
#                 later `done` hides an earlier open question from the status
#                 fold): the last valid `done` anywhere in the log has an [at=]
#                 epoch newer than this incarnation's launch, and the log folds to
#                 no open decision when read with no terminal rule
#                 (status_open_decisions with a non-ship kind). The launch epoch
#                 is the integer after the `s` of spawn_gen, which bin/fm-spawn.sh
#                 mints as s<epoch>.<pid>.<random> on every spawn and relaunch.
#   crew state    bin/fm-crew-state.sh with FM_CREW_STATE_NO_FORGE=1 reads
#                 `done` (a merged ship may also read `unknown`).
#   nothing since the valid done line, or the merge time without a valid done:
#                 no status line newer than it; no steering-inbox record, handled
#                 or not, newer than it and none unhandled; the incarnation
#                 launched before it; the busy record (bin/fm-busy-lib.sh) is
#                 idle, was not written by fm-interrupt, and is no newer than the
#                 quiet-since time; the live busy verdict is idle; the composer
#                 reads `empty`. A source
#                 that cannot be read is "cannot prove" and keeps the seat.
#                 A busy record's seq that moves between two sweeps restarts the
#                 debounce, so a whole turn between sweeps is never missed.
#   stuck composer an idle worker whose composer holds exactly its own steering
#                 doorbell (fm_task_inbox_composer_holds) is classified
#                 `stuck-composer`, reported, and never released.
#   debounce      a task becomes a candidate on one sweep and is released on a
#                 later sweep only when it is still finished with the same
#                 incarnation, anchor, and busy seq, at least 300 s after both
#                 the first sighting and the anchor. The marker and ledger
#                 anchor is the later of valid done and merge for a ship, the
#                 merge time without valid done, and done for a scout. It starts
#                 grace and audit age; it never advances the quiet-since time.
#
# STATE MACHINE AND MARKER. LIVE -> FINISHED -> RELEASING -> RELEASED or
# RELEASE_INCOMPLETE. bin/fm-lane-release-lib.sh owns the marker format, the
# active rule, and the reader contract. This script writes state/<id>.released
# under the task's control lock (state/.control-<id>.lock) BEFORE the exit is
# sent, then releases the lock and starts the exit DETACHED (setsid when
# available, else nohup) as `exit-worker`, which runs
#   bin/fm-control.sh <id> exit --if-idle --expect-spawn-gen <gen>
# under a 60 s bound and appends `rc=<n>` to state/<id>.release.log.
# fm-control holds the control and metadata locks during final eligibility
# validation and exit; --expect-spawn-gen requires the same incarnation.
# Exit-code mapping
# (bin/fm-control.sh): 0 stopped, already-stopped, or endpoint-gone; 75 deferred
# (the lock was busy, the agent was not idle, or the incarnation changed) - the
# marker is removed and the task retried on a later sweep, never spun on;
# 1 refused (dialog, pending or unknown composer, unverified harness, failed
# Claude background-session cleanup, or an agent that did not stop) - when the
# agent is still alive the marker is removed and the seat kept, otherwise the
# seat is verified like a success; 2 usage. The next sweep reads the log and
# verifies the seat with fm_task_record_holds_seat (bin/fm-project-capacity-lib.sh,
# the shared seat rule): free -> RELEASED; still held after two verification
# sweeps, or seat evidence still unknown after two verification sweeps ->
# RELEASE_INCOMPLETE, one printed wake line, and the task stays
# counted. A second sweep or second process on the same task is a no-op: the
# sweep lock, the control lock, and the marker.
#
# CARRIER AND BUDGET. `arm` writes the thin check shim state/lane-release.check.sh
# (it only execs `sweep`) and binds it with bin/fm-check-register.sh, so the
# watcher runs it every FM_CHECK_INTERVAL (300 s) within its 30 s check bound.
# A sweep holds state/.lane-release.lock (try-acquire; contention exits quietly),
# visits in-flight tasks from a durable cursor within 20 s; every external
# read inside it is bounded by
# the time left, at most 10 s, and a read that times out keeps the seat.
# A sweep starts at most 2 releases.
# It runs in every posture: neither away nor quiet mode skips it, and the
# watcher's check sweep has no away gate. Stdout is the wake: a sweep prints
# only the permitted RELEASE_INCOMPLETE lines and single invalid-setting report.
#
# LEDGER. data/lane-release.ledger, append-only, one tab-separated row per
# RELEASED, RELEASE_INCOMPLETE, or (audit setting) WOULD_RELEASE event:
#   <event> task=<id> host=<host> class=<class> anchor=<epoch> released_at=<epoch> verified=<yes|no> reason=<text>
# Skip decisions are bounded counters only, in state/lane-release.counters.
#
# AUDIT. `--audit` reads task state and provider state for open-PR metrics,
# changing nothing. It lists every
# class merged-ship or scout holder with a live agent, its age since the anchor,
# and RELEASE_INCOMPLETE markers; stuck-composer holders; and kept-open-pr
# seat-hours (open-PR ships with a live agent, a done line, no unread steer and
# no open conflict episode, each capped at 7 days; red checks and review
# findings are forge facts this local read does not see). Exit 0 when no holder
# is older than 1800 s, 1 when one is,
# 2 when a needed read failed (unknown is never counted as free).
#
# Test hooks: FM_LANE_RELEASE_CREW_STATE, FM_LANE_RELEASE_CONTROL,
# FM_LANE_RELEASE_CAPTAIN_HOLD replace the crew-state, control, and captain-hold
# programs; FM_LANE_RELEASE_PROBE replaces the live endpoint reads, called as
# `<probe> agent|busy|composer|doorbell|seat <id>` and answering on stdout
# exactly what the real read would (agent: alive|dead|missing|..., busy: the
# fm_busy_classify_meta line, composer: empty|pending|unknown, doorbell and
# seat: yes|no); FM_LANE_RELEASE_NOW fixes the clock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-capacity-lib.sh
. "$SCRIPT_DIR/fm-capacity-lib.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-lane-release-lib.sh
. "$SCRIPT_DIR/fm-lane-release-lib.sh"

CREW_STATE_BIN=${FM_LANE_RELEASE_CREW_STATE:-$SCRIPT_DIR/fm-crew-state.sh}
CONTROL_BIN=${FM_LANE_RELEASE_CONTROL:-$SCRIPT_DIR/fm-control.sh}
HOLD_BIN=${FM_LANE_RELEASE_CAPTAIN_HOLD:-$SCRIPT_DIR/fm-captain-hold.sh}
GRACE=300
BUDGET=20
MAX_RELEASES=2
AUDIT_MAX_AGE=1800
EXIT_BOUND=60
CHECK_ID=lane-release
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
SWEEP_LOCK="$STATE/.lane-release.lock"
CURSOR_FILE="$STATE/.lane-release-cursor"
COUNTERS="$STATE/lane-release.counters"
LEDGER="$DATA/lane-release.ledger"

# Live endpoint reads, each replaceable by FM_LANE_RELEASE_PROBE.
probe() {  # <what> <id>
  "$FM_LANE_RELEASE_PROBE" "$1" "$2" 2>/dev/null
}

raw_read_agent() {  # <meta> <id>
  if [ -n "${FM_LANE_RELEASE_PROBE:-}" ]; then probe agent "$2"; return; fi
  fm_backend_agent_state "$(fm_backend_of_meta "$1")" "$(fm_backend_target_of_meta "$1")" 2>/dev/null
}

raw_read_busy() {  # <meta> <id>
  if [ -n "${FM_LANE_RELEASE_PROBE:-}" ]; then probe busy "$2"; return; fi
  fm_busy_classify_meta "$1" "$2" "$STATE" 2>/dev/null
}

raw_read_composer() {  # <meta> <id>
  if [ -n "${FM_LANE_RELEASE_PROBE:-}" ]; then probe composer "$2"; return; fi
  fm_backend_composer_state "$(fm_backend_of_meta "$1")" "$(fm_backend_target_of_meta "$1")" "fm-$2" 2>/dev/null
}

# 0 when the composer holds exactly <line>, the task's own doorbell.
raw_composer_holds_doorbell() {  # <meta> <id> <line>
  if [ -n "${FM_LANE_RELEASE_PROBE:-}" ]; then [ "$(probe doorbell "$2")" = yes ]; return; fi
  fm_task_inbox_composer_holds "$(fm_backend_of_meta "$1")" "$(fm_backend_target_of_meta "$1")" "$3" "fm-$2" 2>/dev/null
}

# 0 while the task record still holds a seat under the shared seat rule.
raw_seat_held() {  # <meta> <id>
  local raw
  if [ -n "${FM_LANE_RELEASE_PROBE:-}" ]; then
    case "$(probe seat "$2")" in yes) return 0 ;; no) return 1 ;; *) return 2 ;; esac
  fi
  raw=$(cat "$1" 2>/dev/null) || return 2
  local rc=0
  fm_task_record_holds_seat "$1" "$raw" "$STATE" || rc=$?
  [ "$FM_TASK_RECORD_SEAT_KNOWN" = 1 ] || return 2
  return "$rc"
}

now() {
  if [ -n "${FM_LANE_RELEASE_NOW:-}" ]; then
    printf '%s\n' "$FM_LANE_RELEASE_NOW"
  else
    date +%s
  fi
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# The setting word, or `invalid:<word>`.
setting() {
  local file="$CONFIG/lane-release"
  [ -f "$file" ] || { printf 'off\n'; return 0; }
  LC_ALL=C awk '
    { word = word (NR > 1 ? "\n" : "") $0 }
    END {
      if (NR == 1 && (word == "off" || word == "audit" || word == "on")) print word
      else printf "invalid:%s\n", word
    }
  ' "$file" 2>/dev/null || printf 'invalid:\n'
}

counter_bump() {  # <reason>
  local reason=$1 tmp
  [ -d "$STATE" ] || return 0
  tmp=$(mktemp "$STATE/.lane-release-counters.XXXXXX" 2>/dev/null) || return 0
  awk -v r="$reason" '
    $1 == r { $2 = $2 + 1; seen = 1 }
    { print }
    END { if (!seen) print r, 1 }
  ' "$COUNTERS" 2>/dev/null > "$tmp" || awk -v r="$reason" 'BEGIN { print r, 1 }' > "$tmp"
  mv -f -- "$tmp" "$COUNTERS" 2>/dev/null || rm -f -- "$tmp"
}

ledger_row() {  # <event> <id> <class> <anchor> <released_at> <verified> <reason>
  mkdir -p "$DATA" 2>/dev/null || return 0
  printf '%s\ttask=%s\thost=%s\tclass=%s\tanchor=%s\treleased_at=%s\tverified=%s\treason=%s\n' \
    "$1" "$2" "$(hostname 2>/dev/null || printf unknown)" "$3" "$4" "$5" "$6" "$7" >> "$LEDGER"
}

meta_field() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

# The launch epoch embedded in a spawn_gen token, or failure.
launch_epoch() {  # <spawn_gen>
  local e=${1#s}
  e=${e%%.*}
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$e"
}

# --- predicates -------------------------------------------------------------
# Each predicate leaves its finding in OUT on success; a non-zero return
# carries the keep reason in KEEP (a short slug). Both are globals, so callers
# never run a predicate in a subshell.

KEEP=
OUT=
DEADLINE=

# Seconds a subprocess read may take: at most 10, never past the sweep's
# deadline.
read_bound() {
  local left
  [ -n "$DEADLINE" ] || { printf '10\n'; return 0; }
  left=$((DEADLINE - $(date +%s)))
  [ "$left" -le 10 ] || left=10
  [ "$left" -ge 1 ] || return 124
  printf '%s\n' "$left"
}

timed_read() {
  local bound
  bound=$(read_bound) || return 124
  fm_run_timed "$bound" "$@"
}

read_agent() { timed_read "$0" read-evidence agent "$@"; }
read_busy() { timed_read "$0" read-evidence busy "$@"; }
read_composer() { timed_read "$0" read-evidence composer "$@"; }
composer_holds_doorbell() { timed_read "$0" read-evidence doorbell "$@"; }
seat_held() { timed_read "$0" read-evidence seat "$@"; }

raw_read_pr() {
  local meta=$1
  fm_pr_url_parse "$(meta_field "$meta" pr)" || return 1
  case "$FM_PR_PROVIDER" in
    github) fm_pr_github_read_record "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER" || return 1 ;;
    gitlab) fm_pr_gitlab_read_record "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" || return 1 ;;
    forgejo) fm_pr_forgejo_read_record "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" || return 1 ;;
    gerrit) fm_pr_gerrit_read_record "$FM_PR_HOST" "$FM_PR_NUMBER" || return 1 ;;
  esac
  case "$FM_PR_PROVIDER:$FM_PR_RECORD_STATE:$FM_PR_RECORD_MERGED" in
    github:OPEN:false|gitlab:opened:false|forgejo:open:false|gerrit:NEW:false) printf 'open\n' ;;
    github:CLOSED:false|gitlab:closed:false|forgejo:closed:false|gerrit:ABANDONED:false) printf 'closed\n' ;;
    github:MERGED:true|gitlab:merged:true|forgejo:closed:true|gerrit:MERGED:true) printf 'merged\n' ;;
    *) return 1 ;;
  esac
}

pred_no_unhandled_inbox() {
  local dir f found=0
  dir=$(fm_task_inbox_dir "$STATE" "$1")
  OUT=
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || { KEEP='inbox-unreadable'; return 2; }
  fi
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if ! { [ -f "$f" ] && [ ! -L "$f" ] && cat "$f" >/dev/null 2>&1; }; then
      KEEP='inbox-unreadable'
      return 2
    fi
    [ "$found" = 1 ] || OUT=$f
    found=1
  done
  [ "$found" = 0 ] || { KEEP=unread-steer; return 1; }
}

# pred_merged <meta> <id>: OUT is the merge anchor epoch.
pred_merged() {
  local meta=$1 id=$2 pr marker
  OUT=
  pr=$(meta_field "$meta" pr)
  [ -n "$pr" ] || { KEEP='no-pr'; return 1; }
  fm_pr_url_parse "$pr" || { KEEP='pr-unreadable'; return 1; }
  if ! fm_pr_poll_merge_already_notified "$STATE" "$id" \
      "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
    KEEP='kept-open-pr'
    return 1
  fi
  marker="$STATE/$id.pr-poll-merge-notified"
  OUT=$(file_mtime "$marker") && [ -n "$OUT" ] || { KEEP='merge-record-unreadable'; return 1; }
}

# pred_scout_complete <id>
pred_scout_complete() {
  local id=$1 src rc=0 registry="$STATE/procevent"
  [ -f "$DATA/$id/report.md" ] || { KEEP='no-report'; return 1; }
  [ ! -e "$DATA/$id/ship-instructions.md" ] || { KEEP='promotion-pending'; return 1; }
  if [ -e "$registry" ] || [ -L "$registry" ]; then
    [ -d "$registry" ] && [ -r "$registry" ] && [ -x "$registry" ] || { KEEP='board-unreadable'; return 1; }
  fi
  for src in "$registry"/*.source; do
    [ -e "$src" ] || [ -L "$src" ] || continue
    [ -f "$src" ] && [ -r "$src" ] || { KEEP='board-unreadable'; return 1; }
    if grep -Fx "owner_task=$id" "$src" >/dev/null 2>&1; then
      KEEP='board-pending'
      return 1
    else
      rc=$?
      [ "$rc" = 1 ] || { KEEP='board-unreadable'; return 1; }
    fi
  done
  rc=0
  timed_read env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$HOLD_BIN" open "$id" --distinguish-absent >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) KEEP='held-for-captain'; return 1 ;;
    1|3) ;;
    *) KEEP='hold-unreadable'; return 1 ;;
  esac
  rc=0
  timed_read env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$HOLD_BIN" verify "$id" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) ;;
    1) KEEP='completion-gate-not-passed'; return 1 ;;
    *) KEEP='hold-unreadable'; return 1 ;;
  esac
}

# pred_done_line <status> <launch>: OUT is the done line's epoch.
pred_done_line() {
  local status=$1 launch=$2 lines line verb at
  OUT=
  [ -e "$status" ] || [ -L "$status" ] || { KEEP='no-done'; return 1; }
  [ -f "$status" ] && [ ! -L "$status" ] || { KEEP='status-unreadable'; return 1; }
  lines=$(cat "$status" 2>/dev/null) || { KEEP='status-unreadable'; return 1; }
  KEEP='no-done'
  while IFS= read -r line; do
    status_line_verb "$line" verb
    [ "$verb" = "done" ] || continue
    at=$(status_line_at_epoch "$line") || { KEEP='done-unstamped'; continue; }
    [ "$at" -gt "$launch" ] || { [ "$KEEP" != no-done ] || KEEP='done-before-launch'; continue; }
    OUT=$at
  done <<< "$lines"
  [ -n "$OUT" ]
}

# pred_no_open_decision <status>
pred_no_open_decision() {
  local status=$1 open
  [ -f "$status" ] || return 0
  open=$(status_open_decisions "$status" lane-release)
  [ -z "$open" ] || { KEEP='open-decision'; return 1; }
  case "$(status_line_verb "$(last_status_line "$status")")" in
    paused|needs-decision|blocked|failed) KEEP='declared-stop'; return 1 ;;
  esac
}

# pred_crew_state <id> <class>
pred_crew_state() {
  local id=$1 class=$2 line state
  line=$(timed_read env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_CREW_STATE_NO_FORGE=1 "$CREW_STATE_BIN" "$id" 2>/dev/null) || { KEEP='crew-state-unreadable'; return 1; }
  state=${line#state: }
  state=${state%% *}
  case "$class:$state" in
    *:done|merged-ship:unknown) return 0 ;;
  esac
  KEEP="crew-state-$state"
  return 1
}

# pred_nothing_since <meta> <id> <quiet-since> <launch>: OUT is busy-gen:seq.
pred_nothing_since() {
  local meta=$1 id=$2 quiet_since=$3 launch=$4 status last at inbox f m rec
  local target busy_rec ts seq b_state b_source verdict composer line record snapshot busy_gen inbox_rc=0
  OUT=
  [ "$launch" -lt "$quiet_since" ] || { KEEP='relaunched-since'; return 1; }
  status="$STATE/$id.status"
  if [ -f "$status" ]; then
    last=$(last_status_line "$status")
    at=$(status_line_at_epoch "$last") || { KEEP='status-unreadable'; return 1; }
    if [ "$at" -gt "$quiet_since" ]; then
      KEEP='status-since'
      return 1
    fi
  fi
  busy_rec=$(fm_busy_record_path "$STATE" "$id")
  [ -f "$busy_rec" ] && [ ! -L "$busy_rec" ] || { KEEP='busy-record-unreadable'; return 1; }
  snapshot=$(cat "$busy_rec" 2>/dev/null) || { KEEP='busy-record-unreadable'; return 1; }
  busy_gen=$(fm_busy_current_gen "$STATE" "$id") || { KEEP='busy-record-unreadable'; return 1; }
  record=$(fm_busy_record_read "$STATE" "$id") || { KEEP='busy-record-unreadable'; return 1; }
  read -r b_state b_source _ seq <<< "$record"
  case "$b_state" in
    idle) ;;
    busy) KEEP='busy-record-busy'; return 1 ;;
    *) KEEP='busy-record-unreadable'; return 1 ;;
  esac
  [ "$b_source" != fm-interrupt ] || { KEEP='interrupted'; return 1; }
  ts=$(sed -n 's/.* ts=\([0-9][0-9]*\).*/\1/p' "$busy_rec" 2>/dev/null | head -n 1)
  [ -n "$ts" ] || { KEEP='busy-record-unreadable'; return 1; }
  [ "$ts" -le "$quiet_since" ] || { KEEP='turn-since'; return 1; }
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || { KEEP='no-endpoint'; return 1; }
  case "$(read_agent "$meta" "$id")" in
    alive) ;;
    dead|missing) KEEP='agent-not-live'; return 1 ;;
    *) KEEP='endpoint-unreadable'; return 1 ;;
  esac
  inbox=$(fm_task_inbox_dir "$STATE" "$id")
  pred_no_unhandled_inbox "$id" || inbox_rc=$?
  case "$inbox_rc" in
    2) return 1 ;;
    1)
      rec=$OUT
      line=$(fm_task_inbox_doorbell_line "$rec" 2>/dev/null || true)
      if [ -n "$line" ] && composer_holds_doorbell "$meta" "$id" "$line"; then KEEP='stuck-composer'; fi
      return 1
      ;;
  esac
  for f in "$inbox"/*.msg "$inbox"/handled/*.msg; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ -f "$f" ] && [ ! -L "$f" ] || { KEEP='inbox-unreadable'; return 1; }
    m=$(file_mtime "$f") || { KEEP='inbox-unreadable'; return 1; }
    [ "$m" -le "$quiet_since" ] || { KEEP='steer-since'; return 1; }
  done
  verdict=$(read_busy "$meta" "$id") || verdict=unknown
  case "$verdict" in
    idle*) ;;
    busy*) KEEP='busy-busy'; return 1 ;;
    *) KEEP='busy-unreadable'; return 1 ;;
  esac
  composer=$(read_composer "$meta" "$id") || composer=unknown
  case "$composer" in
    empty) ;;
    pending*) KEEP='pending-composer'; return 1 ;;
    *) KEEP='composer-unknown'; return 1 ;;
  esac
  [ "$(cat "$busy_rec" 2>/dev/null)" = "$snapshot" ] \
    && [ "$(fm_busy_current_gen "$STATE" "$id")" = "$busy_gen" ] \
    || { KEEP='turn-since'; return 1; }
  OUT="$busy_gen:$seq"
}

# evaluate <id>: on success EVAL is "<class> <gen> <anchor> <seq>"; otherwise
# KEEP names why the seat stays. Returns 2 when the task is not a lane-release
# subject at all (a secondmate, a remote record, an active marker).
evaluate() {
  local id=$1 meta kind gen launch class anchor done_at merge_at status
  meta="$STATE/$id.meta"
  KEEP=
  EVAL=
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 2
  kind=$(meta_field "$meta" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in ship|scout) ;; *) return 2 ;; esac
  [ -z "$(meta_field "$meta" remote_host)" ] || return 2
  if [ "${2:-0}" != 1 ]; then fm_lane_release_marker_active "$STATE" "$id" && return 2; fi
  gen=$(meta_field "$meta" spawn_gen)
  launch=$(launch_epoch "$gen") || { KEEP='no-incarnation'; return 1; }
  status="$STATE/$id.status"
  done_at=
  if [ "$kind" = scout ]; then
    class=scout
    pred_done_line "$status" "$launch" || return 1
    done_at=$OUT
    pred_scout_complete "$id" || return 1
    anchor=$done_at
    pred_no_open_decision "$status" || return 1
  else
    class='merged-ship'
    [ "$(meta_field "$meta" mode)" != local-only ] || { KEEP='local-only-unproven'; return 1; }
    pred_merged "$meta" "$id" || return 1
    merge_at=$OUT
    if pred_done_line "$status" "$launch"; then
      done_at=$OUT
      anchor=$done_at
      [ "$merge_at" -le "$anchor" ] || anchor=$merge_at
      pred_no_open_decision "$status" || return 1
    else
      case "$KEEP" in no-done|done-before-launch) ;; *) return 1 ;; esac
      [ "$merge_at" -gt "$launch" ] || { KEEP='merged-before-launch'; return 1; }
      anchor=$merge_at
      pred_no_open_decision "$status" || return 1
    fi
  fi
  pred_crew_state "$id" "$class" || return 1
  pred_nothing_since "$meta" "$id" "${done_at:-$anchor}" "$launch" || return 1
  EVAL="$class $gen $anchor $OUT"
}

# --- release ----------------------------------------------------------------

marker_write() {  # <id> <gen> <released_at> <anchor> <class> <result> <busy-gen:seq>
  local marker tmp
  marker=$(fm_lane_release_marker_path "$STATE" "$1")
  tmp=$(mktemp "$STATE/.lane-release-marker.XXXXXX") || return 1
  printf 'fm-lane-release-v1\ntask=%s\nspawn_gen=%s\nreleased_at=%s\nanchor=%s\nclass=%s\nresult=%s\nbusy_seq=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$marker" || { rm -f -- "$tmp"; return 1; }
}

marker_set_result() {  # <id> <result>
  local marker
  marker=$(fm_lane_release_marker_path "$STATE" "$1")
  marker_write "$1" "$(fm_lane_release_marker_field "$marker" spawn_gen)" \
    "$(fm_lane_release_marker_field "$marker" released_at)" \
    "$(fm_lane_release_marker_field "$marker" anchor)" \
    "$(fm_lane_release_marker_field "$marker" class)" "$2" \
    "$(fm_lane_release_marker_field "$marker" busy_seq)"
}

marker_remove() {  # <id>
  rm -f -- "$(fm_lane_release_marker_path "$STATE" "$1")" "$STATE/$1.release.log" "$STATE/$1.release-verify"
}

start_release() {  # <id> <class> <gen> <anchor> <busy-gen:seq>
  local id=$1 class=$2 gen=$3 anchor=$4 seq=$5 lock
  lock="$STATE/.control-$id.lock"
  if ! fm_lock_try_acquire "$lock"; then
    counter_bump lock-busy
    return 1
  fi
  if [ "$(meta_field "$STATE/$id.meta" spawn_gen)" != "$gen" ]; then
    fm_lock_release "$lock" || true
    counter_bump relaunched-since
    return 1
  fi
  rm -f -- "$STATE/$id.release.log" "$STATE/$id.release-verify"
  if ! marker_write "$id" "$gen" "$(now)" "$anchor" "$class" releasing "$seq"; then
    fm_lock_release "$lock" || true
    counter_bump marker-unwritable
    return 1
  fi
  fm_lock_release "$lock" || true
  rm -f -- "$STATE/$id.release-candidate"
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$0" exit-worker "$id" "$gen" </dev/null >/dev/null 2>&1 &
  else
    nohup "$0" exit-worker "$id" "$gen" </dev/null >/dev/null 2>&1 &
  fi
  return 0
}

action_exit_worker() {  # <id> <gen>
  local id=$1 gen=$2 log rc=0
  [ "$(setting)" = on ] || return 0
  log="$STATE/$id.release.log"
  fm_run_timed "$EXIT_BOUND" env FM_HOME="$FM_HOME" FM_CONTROL_LANE_RELEASE=1 \
    "$CONTROL_BIN" "$id" exit --if-idle --expect-spawn-gen "$gen" > "$log.tmp" 2>&1 || rc=$?
  printf 'rc=%s\n' "$rc" >> "$log.tmp"
  mv -f -- "$log.tmp" "$STATE/$id.release.log"
}

action_validate_exit() {
  local id=$1 gen=$2 marker expected
  [ "$(setting)" = on ] || return 75
  fm_lane_release_marker_active "$STATE" "$id" || return 75
  [ "$FM_LANE_RELEASE_RESULT" = releasing ] || return 75
  marker=$(fm_lane_release_marker_path "$STATE" "$id")
  [ "$(fm_lane_release_marker_field "$marker" spawn_gen)" = "$gen" ] || return 75
  expected="$FM_LANE_RELEASE_CLASS $gen $(fm_lane_release_marker_field "$marker" anchor) $(fm_lane_release_marker_field "$marker" busy_seq)"
  evaluate "$id" 1 || return 75
  [ "$EVAL" = "$expected" ] || return 75
}

# Verify one releasing or incomplete marker; prints a wake line for a new
# RELEASE_INCOMPLETE.
verify_marker() {  # <id>
  local id=$1 marker meta result rc class anchor released_at tries seat_rc reason detail
  marker=$(fm_lane_release_marker_path "$STATE" "$id")
  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ]; then
    marker_remove "$id"
    return 0
  fi
  if ! fm_lane_release_marker_active "$STATE" "$id"; then
    marker_remove "$id"
    return 0
  fi
  result=$FM_LANE_RELEASE_RESULT
  class=$FM_LANE_RELEASE_CLASS
  released_at=$FM_LANE_RELEASE_AT
  anchor=$(fm_lane_release_marker_field "$marker" anchor)
  [ "$result" != released ] || return 0
  if [ "$result" = releasing ]; then
    if [ ! -f "$STATE/$id.release.log" ]; then
      [ $(( $(now) - released_at )) -gt $((EXIT_BOUND * 2)) ] || return 0
      rc=unknown
    else
      rc=$(sed -n 's/^rc=//p' "$STATE/$id.release.log" | tail -n 1)
    fi
    case "$rc" in
      75)
        marker_remove "$id"
        counter_bump exit-deferred
        return 0
        ;;
      0|unknown) ;;
      *)
        if [ "$(read_agent "$meta" "$id")" = alive ]; then
          marker_remove "$id"
          counter_bump exit-refused
          return 0
        fi
        ;;
    esac
  fi
  seat_rc=0
  seat_held "$meta" "$id" || seat_rc=$?
  if [ "$seat_rc" = 1 ]; then
    marker_set_result "$id" released
    ledger_row RELEASED "$id" "$class" "$anchor" "$released_at" yes "seat free"
    rm -f -- "$STATE/$id.release-verify"
    return 0
  fi
  [ "$result" = releasing ] || return 0
  tries=$(cat "$STATE/$id.release-verify" 2>/dev/null || printf 0)
  case "$tries" in ''|*[!0-9]*) tries=0 ;; esac
  tries=$((tries + 1))
  printf '%s\n' "$tries" > "$STATE/$id.release-verify"
  [ "$tries" -ge 2 ] || return 0
  marker_set_result "$id" release-incomplete
  if [ "$seat_rc" = 0 ]; then
    reason='seat still held after exit'
    detail='its seat is still held by a process in its local copy'
  else
    reason='seat evidence unavailable after exit'
    detail='seat evidence unavailable'
  fi
  ledger_row RELEASE_INCOMPLETE "$id" "$class" "$anchor" "$released_at" no "$reason"
  printf 'lane-release: RELEASE_INCOMPLETE %s - the worker was stopped but %s; the task stays counted (state/%s.release.log)\n' "$id" "$detail" "$id"
}

candidate_step() {  # <id> <class> <gen> <anchor> <seq> <mode>
  local id=$1 class=$2 gen=$3 anchor=$4 seq=$5 mode=$6 file cur t first audited c_gen c_anchor c_seq
  file="$STATE/$id.release-candidate"
  t=$(now)
  cur=$(cat "$file" 2>/dev/null || true)
  read -r c_gen c_anchor c_seq first audited <<< "$cur"
  if [ "${c_gen:-}" != "$gen" ] || [ "${c_anchor:-}" != "$anchor" ] || [ "${c_seq:-}" != "$seq" ]; then
    printf '%s %s %s %s 0\n' "$gen" "$anchor" "$seq" "$t" > "$file"
    return 1
  fi
  [ $((t - first)) -ge "$GRACE" ] && [ $((t - anchor)) -ge "$GRACE" ] || return 1
  if [ "$mode" = audit ]; then
    if [ "${audited:-0}" != 1 ]; then
      ledger_row WOULD_RELEASE "$id" "$class" "$anchor" - no "audit setting"
      printf '%s %s %s %s 1\n' "$gen" "$anchor" "$seq" "$first" > "$file"
    fi
    return 1
  fi
  return 0
}

action_sweep() {
  local mode id meta ids cursor started=0 deadline class gen anchor seq m bad bad_display rc
  mode=$(setting)
  case "$mode" in
    off) return 0 ;;
    invalid:*)
      bad=${mode#invalid:}
      if [ ! -f "$STATE/.lane-release-invalid" ] || [ "$(cat "$STATE/.lane-release-invalid" 2>/dev/null)" != "$bad" ]; then
        printf '%s\n' "$bad" > "$STATE/.lane-release-invalid"
        bad_display=${bad//$'\n'/\\n}
        bad_display=${bad_display//$'\r'/\\r}
        printf "lane-release: config/lane-release holds '%s', expected off, audit, or on; nothing is released until it is corrected\n" "$bad_display"
      fi
      return 0
      ;;
  esac
  rm -f -- "$STATE/.lane-release-invalid"
  fm_lock_try_acquire "$SWEEP_LOCK" || return 0
  trap 'fm_lock_release "$SWEEP_LOCK" || true' EXIT
  deadline=$(( $(date +%s) + BUDGET ))
  DEADLINE=$deadline
  ids=$(
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      id=${meta##*/}; printf '%s\n' "${id%.meta}"
    done
    for m in "$STATE"/*.released; do
      [ -f "$m" ] || continue
      id=${m##*/}; printf '%s\n' "${id%.released}"
    done
  )
  ids=$(printf '%s\n' "$ids" | LC_ALL=C sort -u)
  cursor=$(cat "$CURSOR_FILE" 2>/dev/null || true)
  ids=$(printf '%s\n' "$ids" | awk -v c="$cursor" 'NF { if (c != "" && $0 <= c) late = late $0 "\n"; else print } END { printf "%s", late }')
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(date +%s)" -lt "$deadline" ] || break
    [ "$started" -lt "$MAX_RELEASES" ] || break
    fm_task_id_creation_valid "$id" || continue
    printf '%s\n' "$id" > "$CURSOR_FILE"
    if [ -f "$STATE/$id.released" ]; then
      verify_marker "$id"
      fm_lane_release_marker_active "$STATE" "$id" && continue
    fi
    rc=0
    evaluate "$id" || rc=$?
    case "$rc" in
      0) ;;
      2) continue ;;
      *)
        rm -f -- "$STATE/$id.release-candidate"
        counter_bump "${KEEP:-unknown}"
        continue
        ;;
    esac
    read -r class gen anchor seq <<< "$EVAL"
    candidate_step "$id" "$class" "$gen" "$anchor" "$seq" "$mode" || continue
    [ "$(date +%s)" -lt "$deadline" ] || break
    start_release "$id" "$class" "$gen" "$anchor" "$seq" && started=$((started + 1))
  done <<< "$ids"
  return 0
}

# --- audit ------------------------------------------------------------------

action_audit() {
  local mode id meta rc class anchor age t miss=0 unknown=0 status done_at launch gen
  local holders=0 stuck=0 seat_hours=0 h agent pr_state
  mode=$(setting)
  t=$(now)
  printf 'lane-release audit: home=%s setting=%s max-age=%ss\n' "$FM_HOME" "$mode" "$AUDIT_MAX_AGE"
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_task_id_creation_valid "$id" || continue
    if fm_lane_release_marker_active "$STATE" "$id"; then
      anchor=$(fm_lane_release_marker_field "$STATE/$id.released" anchor)
      rc=0
      seat_held "$meta" "$id" || rc=$?
      case "$anchor" in ''|*[!0-9]*) rc=2 ;; esac
      case "$rc" in
        0)
          age=$((t - anchor))
          holders=$((holders + 1))
          printf 'holder %s class=%s age=%ss state=%s\n' "$id" "$FM_LANE_RELEASE_CLASS" "$age" "$FM_LANE_RELEASE_RESULT"
          [ "$age" -le "$AUDIT_MAX_AGE" ] || miss=1
          ;;
        1) printf 'released %s class=%s result=%s\n' "$id" "$FM_LANE_RELEASE_CLASS" "$FM_LANE_RELEASE_RESULT" ;;
        *) holders=$((holders + 1)); unknown=1; printf 'unknown %s (release evidence unreadable; unknown is never counted as free)\n' "$id" ;;
      esac
      continue
    fi
    rc=0
    evaluate "$id" || rc=$?
    case "$rc" in
      0)
        read -r class _ anchor _ <<< "$EVAL"
        age=$((t - anchor))
        holders=$((holders + 1))
        printf 'holder %s class=%s age=%ss\n' "$id" "$class" "$age"
        [ "$age" -le "$AUDIT_MAX_AGE" ] || miss=1
        ;;
      2) ;;
      *)
        case "$KEEP" in
          stuck-composer)
            stuck=$((stuck + 1))
            printf 'stuck-composer %s (its own steering doorbell sits unsubmitted; never released)\n' "$id"
            ;;
          crew-state-unreadable|endpoint-unreadable|status-unreadable|done-unstamped|busy-record-unreadable|busy-unreadable|composer-unknown|inbox-unreadable|hold-unreadable|board-unreadable|merge-record-unreadable)
            unknown=1
            printf 'unknown %s (%s; unknown is never counted as free)\n' "$id" "$KEEP"
            ;;
          local-only-unproven)
            rc=0
            seat_held "$meta" "$id" || rc=$?
            case "$rc" in
              0) printf 'kept-local-only %s (excluded from automatic lane release)\n' "$id" ;;
              1) ;;
              *) unknown=1; printf 'unknown %s (local-only seat unreadable; unknown is never counted as free)\n' "$id" ;;
            esac
            ;;
          kept-open-pr)
            status="$STATE/$id.status"
            gen=$(meta_field "$meta" spawn_gen)
            launch=$(launch_epoch "$gen" 2>/dev/null) || launch=0
            if ! pr_state=$(timed_read "$0" read-evidence pr "$meta" "$id"); then
              unknown=1
              printf 'unknown %s (pr-unreadable; unknown is never counted as free)\n' "$id"
              continue
            fi
            [ "$pr_state" = open ] || continue
            agent=$(read_agent "$meta" "$id") || agent=unknown
            case "$agent" in
              alive) ;;
              dead|missing) continue ;;
              *) unknown=1; printf 'unknown %s (endpoint-unreadable; unknown is never counted as free)\n' "$id"; continue ;;
            esac
            if ! pred_done_line "$status" "$launch"; then
              case "$KEEP" in
                status-unreadable|done-unstamped) unknown=1; printf 'unknown %s (%s; unknown is never counted as free)\n' "$id" "$KEEP" ;;
              esac
              continue
            fi
            done_at=$OUT
            rc=0
            pred_no_unhandled_inbox "$id" || rc=$?
            case "$rc" in
              2) unknown=1; printf 'unknown %s (inbox-unreadable; unknown is never counted as free)\n' "$id"; continue ;;
              1) continue ;;
            esac
            [ ! -e "$(fm_pr_conflict_episode_path "$STATE" "$id")" ] || continue
            h=$(( (t - done_at) / 3600 ))
            [ "$h" -le 168 ] || h=168
            seat_hours=$((seat_hours + h))
            printf 'kept-open-pr %s idle-since-done=%sh\n' "$id" "$h"
            ;;
        esac
        ;;
    esac
  done
  printf 'summary: class merged-ship/scout holders=%s stuck-composer=%s kept-open-pr seat-hours=%s (PR state read; red checks and review findings not read)\n' \
    "$holders" "$stuck" "$seat_hours"
  [ "$unknown" = 0 ] || return 2
  [ "$miss" = 0 ] || return 1
  return 0
}

# --- arm / disarm -----------------------------------------------------------

action_arm() {
  local home tmp
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || { echo "fm-lane-release: cannot resolve FM_HOME" >&2; return 1; } ;;
  esac
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "fm-lane-release: state directory is unavailable" >&2; return 1; }
  [ -x "$SCRIPT_DIR/fm-lane-release.sh" ] || { echo "fm-lane-release: refusing to arm, $SCRIPT_DIR/fm-lane-release.sh is not executable" >&2; return 1; }
  [ ! -L "$CHECK_SHIM" ] || { echo "fm-lane-release: $CHECK_SHIM is a symlink" >&2; return 1; }
  tmp=$(umask 077; mktemp "$STATE/.fm-lane-release-check.XXXXXX") || return 1
  # shellcheck disable=SC2016  # single quotes are deliberate: the shim expands $own when it runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-lane-release.sh - the lane-release check shim.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    '# Run the home own code root when it has the script; the arming root is only the fallback.' \
    "own=$(printf '%q' "$home")/bin/fm-lane-release.sh" \
    "pinned=$(printf '%q' "$SCRIPT_DIR/fm-lane-release.sh")" \
    '[ -x "$own" ] || own=$pinned' \
    '[ -x "$own" ] || { echo "fm-lane-release shim: no executable fm-lane-release.sh at $own" >&2; exit 1; }' \
    'exec "$own" sweep' > "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM"
    echo "fm-lane-release: could not register $CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh (setting: %s)\n' "$CHECK_ID" "$(setting)"
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$STATE/$CHECK_ID.check-trust"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-}" in
  read-evidence)
    shift
    case "$1" in
      agent) shift; raw_read_agent "$@" ;;
      busy) shift; raw_read_busy "$@" ;;
      composer) shift; raw_read_composer "$@" ;;
      doorbell) shift; raw_composer_holds_doorbell "$@" ;;
      seat) shift; raw_seat_held "$@" ;;
      pr) shift; raw_read_pr "$@" ;;
      *) exit 2 ;;
    esac
    ;;
  validate-exit) action_validate_exit "$2" "$3" ;;
  sweep) action_sweep ;;
  --audit) action_audit ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  exit-worker)
    if [ "$#" -ne 3 ] || ! fm_task_id_creation_valid "$2"; then
      usage >&2
      exit 2
    fi
    action_exit_worker "$2" "$3"
    ;;
  *) usage >&2; exit 2 ;;
esac
