#!/usr/bin/env bash
# fm-inactive-reconcile.sh - bounded reconciliation of inactive outcomes and finished backlog PRs.
#
# Usage:
#   fm-inactive-reconcile.sh scan [--startup]
#   fm-inactive-reconcile.sh report <task-id>
#   fm-inactive-reconcile.sh acknowledge <fingerprint>
#
# This is an adjunct to the existing watcher poll loop and session-start path,
# not a separate watcher or daemon.
# In a secondmate home every `scan` invocation, which is every watcher poll,
# first runs the LEDGER-FIRST parent delivery: a direct child whose status
# ledger ends in a whole `done:` or `failed:` line has stated its own outcome,
# so that line is published on the parent channel at once through
# bin/fm-parent-channel-lib.sh from this unstamped payload:
#   <state> [key=child-outcome-<child>-<state>-<fp8>]: child <child> <state>: <note> [pr=<url>] [mode=<mode>] [yolo=<posture>] [report=data/<child>/report.md]
# carrying the child's recorded PR, delivery mode, merge posture, and scout
# report pointer, without consulting fm-crew-state.sh. A ship `done:` is
# published only when bin/fm-dod-lib.sh accepts the named head, so an
# unpushed copy is not reported upstream as ready. A no-mistakes handoff
# (fm_dod_done_is_nm_handoff) is not published. The cadence path uses
# fm-crew-state.sh: that handoff with a positive no-run reads
# stopped-before-validation and is not a terminal inactive outcome, while a
# CI-ready or direct-PR/local-only done whose head lives only in the
# disposable copy reads blocked and is not a terminal inactive outcome.
# A line still being appended (no trailing newline yet)
# is left for the next poll. This is what keeps a mate's PR-ready, finding,
# and failure outcomes from depending on the mate model appending them
# (docs/secondmate-parent-channel.md). A main home has no parent channel and
# skips this path: its watcher already signals every child status line.
# `report <task-id>` runs that same delivery for one child on behalf of a
# caller that already holds the child's meta lock, which bin/fm-teardown.sh
# does before it removes the child's record; it exits 0 when the line is
# delivered or nothing is owed, and non-zero when the parent channel could not
# be written, so teardown refuses instead of discarding an undelivered outcome.
# The cadence-gated scan below then evaluates at most once per
# FM_INACTIVE_RECONCILE_SECS (default 900, valid 60..1800) per home, except
# that --startup performs the same scan immediately in the locked session
# start's deferred worker. Each scan uses an aggregate
# FM_INACTIVE_RECONCILE_BUDGET_SECS deadline (default 10, valid 1..30) and
# resumes after its last visited child on the next scan.
# The scan enforces that budget itself through a whole-second deadline, and the
# first due child of every scan is always visited with at least a one-second
# state-read bound: whole-second arithmetic can otherwise round a small budget
# to zero mid-scan, and an invocation that exits having visited nothing would
# advance the durable cursor past a child it never examined. A process-group
# kill one second after the budget remains as a backstop for a scan wedged in
# an unbounded wait (for example a live-held wake-queue lock), so the clean
# deadline path is not racing its own backstop.
#
# It considers only a direct ordinary crewmate whose newest meta, status, or
# turn-ended mtime is older than that interval and whose last status is not
# captain-held. In a secondmate home a child whose ledger already ends in a
# terminal done or failed line belongs to the ledger-first path above and is
# skipped here, so one outcome is never reported twice. It then uses
# fm-crew-state.sh as the sole current-state source.
# Only a done or failed state is suspicious enough to create a durable terminal
# outcome record or wake the supervisor.
# Working, paused, parked, blocked, unknown, persistent secondmates, and
# captain-held work retain their existing supervision semantics.
#
# A terminal-outcomes/<fingerprint>.pending record remains until its upstream
# receipt is durable.
# In a secondmate home, that receipt is an idempotent parent-channel append
# through bin/fm-parent-channel-lib.sh; the ledger-first path and the inactive
# path share the same receipt store.
# In a main home, a presentation-stage record is acknowledged by fm-wake-drain
# only after its corresponding inactive-outcome wake is handled.
# A receipt is intentionally independent of .hb-surfaced-* bookkeeping.
#
# New fm-terminal-outcome.v1 receipts contain schema, fingerprint, task_id,
# incarnation, state, outcome_key, origin, phase, pr, created_epoch, and
# notice_emitted, plus optional status_head and ledger_claim fields. The
# inactive-path fingerprint binds only the spawn incarnation, task id, terminal
# state, and PR text, never the child's last status line, so a child that keeps
# appending routine prose after one terminal outcome yields at most one parent
# event across scans and restarts; the last line is retained in status_head as
# evidence. The ledger-path fingerprint instead binds the incarnation, task id,
# terminal state, literal `ledger` origin, and complete terminal ledger line.
# When a terminal ledger append races just after the inactive path's final read,
# ledger_claim binds that one ledger fingerprint to the already-delivered
# inactive receipt so the two publishers cannot report one completion twice.
# Pending atomically becomes reported after parent append or presented after
# main-home acknowledgement. The atomic epoch/cursor marker's mtime gates scans,
# and its cursor records the last child visited within the aggregate budget.
#
# The child scan above reads only durable local state and fm-crew-state.sh; it
# never invokes gh, gh-axi, curl, fm-pr-check.sh, fm-pr-poll.sh, or a state
# *.check.sh. The one forge read in this script is the backlog pass below.
#
# BACKLOG PASS. After the cadence gate and before the child scan, each scan also
# closes in-flight backlog records whose pull request has already finished, so
# merged work cannot sit parked as In flight. It lists this home's in-flight rows
# and collects every https://github.com/<owner>/<repo>/pull/<n>
# reference from `show --full` plus a worker meta's pr=, and reads each distinct
# PR with one bounded `gh pr view --json state,mergedAt,closedAt`. An unreadable
# PR or missing terminal timestamp leaves an unknown finding; a PR that is
# still OPEN leaves the record alone. A record whose refs are
# ALL MERGED or CLOSED, that is not held, and that has no live worker (a meta whose
# fm-crew-state.sh state is not done or failed) is closed through
# fm_backlog_done in bin/fm-backlog-transition-lib.sh, the owner teardown uses.
# A receipt state/terminal-outcomes/backlog-pr-<fingerprint>.closed, keyed by
# task id plus each PR and its state, makes that close happen once: it is written
# first as an intent (status=closing) with the dated close detail, the record is closed, and the receipt is
# marked closed once the evidence is published. A later scan that finds a closing
# receipt whose task is confirmed Done publishes the missing evidence and
# marks it closed, so an interruption never closes a record twice; a record
# someone reopens is not closed again for the same PR states.
# The pass owns half of FM_INACTIVE_RECONCILE_BUDGET_SECS (at least 1 second) and
# visits rows, outstanding findings, and receipt inspection in rotation from a cursor saved after each visit
# (state/backlog-pr-cursor), so every row is reached across short sessions.
# In the main home only, the pass upserts into data/x-reconcile.json items with
# source "inactive-reconcile": finding "fix" for a record it closed (detail
# "closed: PR <number> merged <UTC timestamp>" or the corresponding closed date)
# or found closable but could not close, and finding "unknown"
# for a record whose PR state it could not read in time, under flock on
# data/x-reconcile.json.lock; it updates only authoritatively examined items and
# leaves written_at to the file's other writer. Server and laptop homes close
# their own records and write no JSON.
set -u
export LC_ALL=C

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
OUTCOME_DIR="$STATE/terminal-outcomes"
SCAN_MARKER="$STATE/.inactive-outcome-reconcile"
SCAN_LOCK="$STATE/.inactive-outcome-reconcile.lock"
CREW_STATE_BIN="${FM_INACTIVE_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

FM_INACTIVE_RECONCILE_SECS=${FM_INACTIVE_RECONCILE_SECS:-900}
case "$FM_INACTIVE_RECONCILE_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_SECS must be a whole number from 60 to 1800\n' >&2
    exit 2
    ;;
esac
if [ "$FM_INACTIVE_RECONCILE_SECS" -lt 60 ] || [ "$FM_INACTIVE_RECONCILE_SECS" -gt 1800 ]; then
  printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_SECS must be a whole number from 60 to 1800\n' >&2
  exit 2
fi
FM_INACTIVE_RECONCILE_BUDGET_SECS=${FM_INACTIVE_RECONCILE_BUDGET_SECS:-10}
case "$FM_INACTIVE_RECONCILE_BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_BUDGET_SECS must be a whole number from 1 to 30\n' >&2
    exit 2
    ;;
esac
if [ "$FM_INACTIVE_RECONCILE_BUDGET_SECS" -gt 30 ]; then
  printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_BUDGET_SECS must be a whole number from 1 to 30\n' >&2
  exit 2
fi

if [ "$(uname)" = Darwin ]; then
  file_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

reconcile_now() {
  case "${FM_INACTIVE_RECONCILE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_INACTIVE_RECONCILE_NOW" ;;
  esac
}

clean_field() {
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-1200
}

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 32)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 32)}'
  else
    printf '%s' "$1" | cksum | awk '{printf "%08x%08x", $1, $2}'
  fi
}

record_path() { printf '%s/%s.%s\n' "$OUTCOME_DIR" "$1" "$2"; }

record_value() {
  local record=$1 key=$2
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  grep "^${key}=" "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

record_phase_set() {
  local record=$1 phase=$2 tmp line
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  tmp=$(mktemp "$OUTCOME_DIR/.record.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in phase=*) continue ;; esac
    printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done < "$record"
  printf 'phase=%s\n' "$phase" >> "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$record"
}

record_field_set() {
  local record=$1 key=$2 value=$3 tmp line
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  tmp=$(mktemp "$OUTCOME_DIR/.record.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "${key}="*) continue ;; esac
    printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done < "$record"
  printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$record"
}

ensure_record() { # <fingerprint> <task> <incarnation> <state> <outcome-key> <origin> <phase> <pr> [status-head]
  local fingerprint=$1 task=$2 incarnation=$3 state=$4 outcome_key=$5 origin=$6 phase=$7 pr=$8 status_head=${9:-} tmp
  RECORD_PENDING=$(record_path "$fingerprint" pending)
  RECORD_PRESENTED=$(record_path "$fingerprint" presented)
  RECORD_REPORTED=$(record_path "$fingerprint" reported)
  if [ -f "$RECORD_PRESENTED" ] || [ -f "$RECORD_REPORTED" ]; then
    RECORD_PENDING=
    return 0
  fi
  if [ -f "$RECORD_PENDING" ] && [ ! -L "$RECORD_PENDING" ]; then
    return 0
  fi
  mkdir -p "$OUTCOME_DIR" || return 1
  [ ! -L "$OUTCOME_DIR" ] || return 1
  tmp=$(mktemp "$OUTCOME_DIR/.pending.XXXXXX") || return 1
  {
    printf 'schema=fm-terminal-outcome.v1\n'
    printf 'fingerprint=%s\n' "$fingerprint"
    printf 'task_id=%s\n' "$task"
    printf 'incarnation=%s\n' "$incarnation"
    printf 'state=%s\n' "$state"
    printf 'outcome_key=%s\n' "$outcome_key"
    printf 'origin=%s\n' "$origin"
    printf 'phase=%s\n' "$phase"
    printf 'pr=%s\n' "$pr"
    printf 'created_epoch=%s\n' "$(reconcile_now)"
    printf 'notice_emitted=0\n'
    [ -z "$status_head" ] || printf 'status_head=%s\n' "$status_head"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$RECORD_PENDING" || { rm -f "$tmp"; return 1; }
}

mark_reported() { # <record>
  local record=$1 reported
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  reported=${record%.pending}.reported
  mv -f "$record" "$reported"
}

queue_key_exists() { # <key>
  local key=$1 queued
  queued=$(fm_wake_queued_keys check 2>/dev/null || true)
  printf '%s\n' "$queued" | grep -Fx -- "$key" >/dev/null 2>&1
}

publish_actionable() { # <key> <payload>
  local key=$1 payload=$2
  queue_key_exists "$key" && return 1
  fm_wake_append check "$key" "$payload" || return 2
  printf 'actionable: %s\n' "$payload"
}

queue_notice_once() { # <record> <key> <payload>
  local record=$1 key=$2 payload=$3 notified rc=0
  notified=$(record_value "$record" notice_emitted)
  [ "$notified" = 1 ] && return 1
  publish_actionable "$key" "$payload" || rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    record_field_set "$record" notice_emitted 1 || return 2
  fi
  return "$rc"
}

queue_presentation() { # <record> <fingerprint> <payload>
  local record=$1 fingerprint=$2 payload=$3
  publish_actionable "inactive-outcome:$fingerprint" "$payload"
}

last_activity_age() { # <meta> <status> <turn-ended>
  local meta=$1 status=$2 turn=$3 now m newest=0 file
  now=$(reconcile_now)
  for file in "$meta" "$status" "$turn"; do
    [ -e "$file" ] || continue
    m=$(file_mtime "$file" 2>/dev/null || true)
    case "$m" in ''|*[!0-9]*) continue ;; esac
    [ "$m" -le "$newest" ] || newest=$m
  done
  [ "$newest" -gt 0 ] || { printf '0\n'; return; }
  if [ "$now" -lt "$newest" ]; then printf '0\n'; else printf '%s\n' $((now - newest)); fi
}

scan_marker_age() {
  local now m
  [ -e "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || { printf '999999\n'; return; }
  now=$(reconcile_now)
  m=$(file_mtime "$SCAN_MARKER" 2>/dev/null || true)
  case "$m" in ''|*[!0-9]*) printf '999999\n'; return ;; esac
  if [ "$now" -lt "$m" ]; then printf '0\n'; else printf '%s\n' $((now - m)); fi
}

scan_marker_cursor() {
  [ -f "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || return 0
  grep '^cursor=' "$SCAN_MARKER" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

write_scan_marker() { # <cursor>
  local cursor=$1 marker_tmp
  marker_tmp=$(mktemp "$STATE/.inactive-outcome-reconcile.XXXXXX") || return 1
  {
    printf 'epoch=%s\n' "$(reconcile_now)"
    printf 'cursor=%s\n' "$cursor"
  } > "$marker_tmp" || { rm -f "$marker_tmp"; return 1; }
  chmod 600 "$marker_tmp" 2>/dev/null || true
  mv -f "$marker_tmp" "$SCAN_MARKER" || { rm -f "$marker_tmp"; return 1; }
}

meta_field() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

meta_incarnation() { # <meta>
  local meta=$1 incarnation identity
  incarnation=$(meta_field "$meta" spawn_gen)
  if valid_id "$incarnation"; then
    printf '%s\n' "$incarnation"
    return
  fi
  identity=$(meta_field "$meta" tasktmp)
  if [ -z "$identity" ]; then
    identity="$(meta_field "$meta" window)|$(meta_field "$meta" worktree)"
  fi
  printf 'legacy-%s\n' "$(sha256_text "$identity")"
}

# The task's delivered PR. Recorded meta pr= is the only authoritative source;
# the fallback scrape accepts only a preferred terminal line in a mode's
# ready-signal shape (`done: PR <url>` or `done: PR <url> checks green`,
# optionally carrying an emission-time tag this scrape steps over without
# reading), so a PR a worker merely mentioned in prose is never claimed as the
# delivery.
# A scout never delivers a PR, so it never carries one.
pr_for_task() { # <meta> [preferred-line]
  local meta=$1 preferred=${2:-} value
  [ "$(meta_field "$meta" kind)" != scout ] || return 0
  value=$(meta_field "$meta" pr)
  if [ -z "$value" ] && [ -n "$preferred" ]; then
    value=$(printf '%s\n' "$preferred" \
      | sed -nE 's|^done( \[at=[^]]*\])?: PR (https?://[^[:space:])"]+/pull/[0-9]+)( checks green)?$|\2|p' \
      | head -1 || true)
  fi
  clean_field "$value"
}

home_secondmate_id() {
  fm_parent_channel_home_id "$FM_HOME"
}

report_to_parent() { # <task> <state> <outcome-key> <fingerprint> <pr>
  local task=$1 state=$2 outcome_key=$3 fingerprint=$4 pr=$5 line
  line="$state [key=$outcome_key]: inactive terminal child=$task fingerprint=$fingerprint"
  [ -z "$pr" ] || line="$line pr=$pr"
  fm_parent_channel_report "$FM_HOME" "$STATE" "$line"
}

# Queue the once-per-record notice that a parent report could not be written.
# A home seeded without its parent binding cannot report upward at all, and
# every later terminal outcome fails the same way for the same reason, so the
# binding is named when it is the cause.
notice_parent_report_failed() { # <record> <fingerprint> <payload>
  local record=$1 fingerprint=$2 payload=$3
  if ! fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent"; then
    payload="$payload (missing or unreadable parent binding .fm-secondmate-parent)"
  fi
  queue_notice_once "$record" "inactive-reconcile:$fingerprint" "$payload" || true
}

# The whole terminal event a child's ledger states, or non-zero when the ledger
# is absent, unusable, or states no done or failed event (1), or when that event
# is the line still being appended (2, no trailing newline yet). The event is
# selected through the shared latest-event reader, so the ledger path owns a
# terminal record whose continuation prose trails it, and an unfinished line of
# ordinary prose withholds nothing.
child_terminal_ledger_line() { # <status>
  local status=$1 snapshot last marker='__FM_LEDGER_SNAPSHOT_END__'
  [ -f "$status" ] && [ ! -L "$status" ] && [ -s "$status" ] || return 1
  last=$(last_status_line "$status")
  case "$(status_line_verb "$last")" in done|failed) ;; *) return 1 ;; esac
  snapshot=$(cat "$status"; printf '%s' "$marker") || return 1
  case "$snapshot" in
    *$'\n'"$marker") ;;
    "$last$marker"|*$'\n'"$last$marker") return 2 ;;
  esac
  printf '%s\n' "$last"
}

# Claim one already-delivered inactive fallback as the delivery of this ledger
# event. Both reconciliation paths hold the child's meta lock, so this receipt
# update serializes their decision even though the child appends its ledger
# without that lock. The claim stores the exact ledger fingerprint: a retry of
# this event stays suppressed, while a later terminal line remains a new event.
claim_inactive_report_for_ledger() { # <task> <incarnation> <state> <ledger-fingerprint> <predecessor-head>
  local task=$1 incarnation=$2 state=$3 ledger_fingerprint=$4 predecessor_head=$5 record key claim
  for record in "$OUTCOME_DIR"/*.reported; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    [ "$(record_value "$record" task_id)" = "$task" ] || continue
    [ "$(record_value "$record" incarnation)" = "$incarnation" ] || continue
    [ "$(record_value "$record" state)" = "$state" ] || continue
    key=$(record_value "$record" outcome_key)
    case "$key" in inactive-outcome-*) ;; *) continue ;; esac
    [ "$(record_value "$record" status_head)" = "$predecessor_head" ] || continue
    claim=$(record_value "$record" ledger_claim)
    if [ "$claim" = "$ledger_fingerprint" ]; then
      return 0
    fi
    [ -z "$claim" ] || continue
    record_field_set "$record" ledger_claim "$ledger_fingerprint" || return 2
    return 0
  done
  return 1
}

# The ledger-first parent delivery for one direct child, for a caller holding
# the child's meta lock. Returns 0 when the line is delivered, already
# delivered, or nothing is owed, and 1 when it is owed but the parent channel
# could not be written (the notice is queued once per record).
report_child_ledger_locked() { # <id> <meta>
  local id=$1 meta=$2 status last previous state note pr mode yolo data incarnation fingerprint predecessor_head outcome_key line
  status="$STATE/$id.status"
  last=$(child_terminal_ledger_line "$status") || return 0
  state=$(status_line_verb "$last")
  pr=$(pr_for_task "$meta" "$last")
  incarnation=$(meta_incarnation "$meta")
  fingerprint=$(sha256_text "$incarnation|$id|$state|ledger|$last")
  if [ "$state" = "done" ] && [ ! -f "$(record_path "$fingerprint" reported)" ] \
    && [ ! -f "$(record_path "$fingerprint" pending)" ]; then
    if fm_dod_done_is_nm_handoff "$(meta_field "$meta" kind)" "$(meta_field "$meta" mode)" "$last"; then
      return 0
    fi
    if ! fm_dod_accept_ship_done "$(meta_field "$meta" kind)" "$(meta_field "$meta" mode)" \
      "$(meta_field "$meta" worktree)" "$(meta_field "$meta" project)" "$last" \
      "$STATE" "$id" "$meta" >/dev/null; then
      return 0
    fi
  fi
  outcome_key="child-outcome-$id-$state-${fingerprint:0:8}"
  ensure_record "$fingerprint" "$id" "$incarnation" "$state" "$outcome_key" direct upstream "$pr" || return 1
  [ -n "$RECORD_PENDING" ] || return 0
  last_status_line "$status" previous >/dev/null
  predecessor_head=$(sha256_text "$previous")
  if claim_inactive_report_for_ledger "$id" "$incarnation" "$state" "$fingerprint" "$predecessor_head"; then
    # The fallback line is already on the parent channel. This reported ledger
    # receipt records that its richer rendering owes no second publication.
    mark_reported "$RECORD_PENDING" || return 1
    return 0
  elif [ "$?" -eq 2 ]; then
    return 1
  fi
  note=$(clean_field "$(status_line_note "$last")")
  mode=$(clean_field "$(meta_field "$meta" mode)")
  yolo=$(clean_field "$(meta_field "$meta" yolo)")
  data="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
  line="$state [key=$outcome_key]: child $id $state: $note"
  [ -z "$pr" ] || line="$line pr=$pr"
  [ -z "$mode" ] || line="$line mode=$mode"
  [ -z "$yolo" ] || line="$line yolo=$yolo"
  if [ -f "$data/$id/report.md" ] && [ ! -L "$data/$id/report.md" ]; then
    line="$line report=data/$id/report.md"
  fi
  if fm_parent_channel_report "$FM_HOME" "$STATE" "$line"; then
    mark_reported "$RECORD_PENDING" || return 1
    return 0
  fi
  notice_parent_report_failed "$RECORD_PENDING" "$fingerprint" \
    "child outcome needs parent report: child=$id state=$state"
  return 1
}

# Every direct child's ledger, under its meta lock. File reads, plus a local
# git reachability check for a ship done: with no delivery record yet, so it
# runs on every poll in a secondmate home; a delivery failure is already queued as a
# notice and never fails the scan.
ledger_pass() {
  local meta id lock
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    [ "$(meta_field "$meta" kind)" != secondmate ] || continue
    lock=$(fm_meta_lock_path "$meta") || continue
    fm_lock_try_acquire "$lock" || continue
    if [ ! -f "$meta" ] || [ -L "$meta" ] \
      || [ "$(meta_field "$meta" kind)" = secondmate ]; then
      fm_lock_release "$lock"
      continue
    fi
    report_child_ledger_locked "$id" "$meta" || true
    fm_lock_release "$lock"
  done
}

# The `report <task-id>` entry point: the caller holds the child's meta lock.
report_child() { # <id>
  local id=$1 meta rc=0
  mkdir -p "$STATE" "$OUTCOME_DIR" || return 1
  [ ! -L "$OUTCOME_DIR" ] || return 1
  home_secondmate_id >/dev/null || { rc=$?; [ "$rc" -eq 1 ] && return 0; return 1; }
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  [ "$(meta_field "$meta" kind)" != secondmate ] || return 0
  report_child_ledger_locked "$id" "$meta"
}

reconcile_direct_child_locked() { # <id> <meta> <secondmate-id-or-empty> <timeout>
  local id=$1 meta=$2 self=${3:-} timeout=$4 status turn last age state_line state pr incarnation fingerprint outcome_key payload kind state_rc=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(meta_field "$meta" kind)
  [ "$kind" = secondmate ] && return 0
  status="$STATE/$id.status"
  turn="$STATE/$id.turn-ended"
  last=$(last_status_line "$status")
  status_line_verb "$last" | grep -Fx captain-held >/dev/null 2>&1 && return 0
  # A ledger that states its own outcome is the ledger-first path's to deliver.
  if [ -n "$self" ]; then
    child_terminal_ledger_line "$status" >/dev/null
    case "$?" in 0|2) return 0 ;; esac
  fi
  age=$(last_activity_age "$meta" "$status" "$turn")
  [ "$age" -ge "$FM_INACTIVE_RECONCILE_SECS" ] || return 0
  state_line=$(fm_run_timed "$timeout" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_NO_FORGE=1 \
    "$CREW_STATE_BIN" "$id" 2>/dev/null) || state_rc=$?
  [ "$state_rc" -ne 124 ] || return 3
  last=$(last_status_line "$status")
  if [ -n "$self" ]; then
    child_terminal_ledger_line "$status" >/dev/null
    case "$?" in 0|2) return 0 ;; esac
  fi
  case "$state_line" in
    'state: done '*) state='done' ;;
    'state: failed '*) state='failed' ;;
    *) return 0 ;;
  esac
  pr=$(pr_for_task "$meta")
  incarnation=$(meta_incarnation "$meta")
  # The receipt identity binds structured fields only: a persistent child that
  # keeps appending routine prose after one terminal outcome must not mint a
  # fresh parent event per sentence. The last line stays in the record as
  # status_head evidence.
  fingerprint=$(sha256_text "$incarnation|$id|$state|$pr")
  if [ -n "$self" ]; then
    outcome_key="inactive-outcome-$self-$id-$state"
  else
    outcome_key="inactive-outcome-main-$id-$state"
  fi
  ensure_record "$fingerprint" "$id" "$incarnation" "$state" "$outcome_key" direct "upstream" "$pr" "$(sha256_text "$last")" || return 1
  [ -n "$RECORD_PENDING" ] || return 0
  if [ -n "$self" ]; then
    if report_to_parent "$id" "$state" "$outcome_key" "$fingerprint" "$pr"; then
      mark_reported "$RECORD_PENDING" || return 1
    else
      notice_parent_report_failed "$RECORD_PENDING" "$fingerprint" \
        "inactive terminal outcome needs parent report: child=$id state=$state"
    fi
    return 0
  fi
  record_phase_set "$RECORD_PENDING" presentation || return 1
  payload="inactive terminal outcome awaiting captain presentation: child=$id state=$state"
  [ -z "$pr" ] || payload="$payload pr=$pr"
  queue_presentation "$RECORD_PENDING" "$fingerprint" "$payload" || true
}

reconcile_direct_child() { # <id> <meta> <secondmate-id-or-empty> <timeout>
  local id=$1 meta=$2 self=${3:-} timeout=$4 lock rc=0
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  reconcile_direct_child_locked "$id" "$meta" "$self" "$timeout" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

# SCAN_FIRST_VISIT_PENDING is armed by scan() before its passes. The deadline
# below is whole-second arithmetic, so a small budget can quantize to zero
# between the deadline computation and these checks; without the guaranteed
# first visit, such a scan would return 3 having examined no child at all while
# write_scan_marker had already advanced the cursor past the skipped child.
scan_pass() { # <cursor> <after|through> <deadline> <secondmate-id-or-empty>
  local cursor=$1 range=$2 deadline=$3 self=${4:-} meta id remaining rc first
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    case "$range" in
      after) [ -z "$cursor" ] || [[ "$id" > "$cursor" ]] || continue ;;
      through) [ -n "$cursor" ] && [[ "$id" > "$cursor" ]] && continue ;;
    esac
    first=0
    if [ "${SCAN_FIRST_VISIT_PENDING:-0}" -eq 1 ]; then
      first=1
      SCAN_FIRST_VISIT_PENDING=0
    fi
    if [ "$first" -eq 0 ]; then
      [ "$(date +%s)" -lt "$deadline" ] || return 3
    fi
    write_scan_marker "$id" || return 1
    remaining=$((deadline - $(date +%s)))
    if [ "$first" -eq 1 ] && [ "$remaining" -lt 1 ]; then
      remaining=1
    fi
    [ "$remaining" -gt 0 ] || return 3
    reconcile_direct_child "$id" "$meta" "$self" "$remaining" || {
      rc=$?
      [ "$rc" -eq 3 ] && return 3
      return "$rc"
    }
  done
}

# One PR's state and terminal UTC timestamp as tab-separated fields through a
# bounded read; an unreadable state or missing terminal timestamp prints nothing.
backlog_pr_state() { # <url>
  local url=$1 out
  fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || return 1
  out=$(gh pr view "$FM_PR_NUMBER" -R "$FM_PR_OWNER/$FM_PR_REPO" --json state,mergedAt,closedAt 2>/dev/null) || return 1
  printf '%s' "$out" | python3 -I -c '
import datetime, json, sys
try:
    doc = json.load(sys.stdin)
    state = doc["state"]
    if state == "OPEN":
        print("OPEN\t")
    elif state in ("MERGED", "CLOSED"):
        value = doc["mergedAt" if state == "MERGED" else "closedAt"]
        stamp = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if stamp.tzinfo is None:
            sys.exit(1)
        finished = stamp.astimezone(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
        print(state + "\t" + finished)
    else:
        sys.exit(1)
except (KeyError, TypeError, ValueError, AttributeError):
    sys.exit(1)
'
}

backlog_pr_evidence() {
  local signature=$1 item ref expected info state finished verb detail=''
  while IFS= read -r item; do
    ref=${item%=*}
    expected=${item##*=}
    info=$(printf '%s\n' "$cache" | awk -F'\t' -v u="$ref" '$1 == u { print $2 "\t" $3; exit }')
    [ -n "$info" ] || info=$(backlog_pr_state "$ref") || return 1
    state=${info%%$'\t'*}
    finished=${info#*$'\t'}
    [ "$state" = "$expected" ] && [ -n "$finished" ] || return 1
    case "$state" in MERGED) verb=merged ;; CLOSED) verb=closed ;; *) return 1 ;; esac
    fm_pr_url_parse "$ref" || return 1
    detail="${detail:+$detail; }PR $FM_PR_NUMBER $verb $finished"
  done <<EOF
$(printf '%s' "$signature" | tr ',' '\n')
EOF
  [ -n "$detail" ] || return 1
  printf 'closed: %s\n' "$detail"
}

backlog_pr_refs() { # reads text on stdin
  grep -oE 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[1-9][0-9]*' 2>/dev/null || true
}

# Upsert examined items in data/x-reconcile.json from tab-separated
# "<id>\t<finding>\t<detail>" lines; an empty finding retires that item.
# Unexamined items, other sources, and unparseable files are left untouched.
x_reconcile_upsert() { # <timeout> <json-path> <home-label> <observed-epoch>
  local timeout=$1
  shift
  fm_run_timed "$timeout" python3 -I -c '
import fcntl, json, os, sys, tempfile
path, home, observed = sys.argv[1], sys.argv[2], int(sys.argv[3])
items = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if line:
        item_id, finding, detail = (line.split("\t", 2) + ["", ""])[:3]
        items.append({"id": item_id, "home": home, "finding": finding,
                      "observed_at": observed, "detail": detail,
                      "source": "inactive-reconcile"})
with open(path + ".lock", "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    exists = os.path.exists(path)
    doc = {"schema": "x-reconcile.v1", "written_at": observed, "items": []}
    if exists:
        with open(path) as f:
            doc = json.load(f)
        if not isinstance(doc, dict) or not isinstance(doc.get("items"), list):
            sys.exit(3)
    elif not items:
        sys.exit(0)
    updates = {x["id"]: x for x in items}
    merged = [x for x in doc["items"]
              if not (isinstance(x, dict) and x.get("source") == "inactive-reconcile"
                      and x.get("home") == home and x.get("id") in updates)]
    merged += [x for x in updates.values() if x["finding"]]
    if exists and merged == doc["items"]:
        sys.exit(0)
    doc["items"] = merged
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".x-reconcile.")
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
' "$@"
}

backlog_pr_receipt_write() { # <receipt> <task> <signature> <closing|closed> <detail>
  local receipt=$1 task=$2 signature=$3 status=$4 detail=$5 tmp
  tmp=$(mktemp "$OUTCOME_DIR/.record.XXXXXX") || return 1
  {
    printf 'schema=fm-backlog-pr-close.v1\n'
    printf 'task_id=%s\n' "$task"
    printf 'prs=%s\n' "$signature"
    printf 'status=%s\n' "$status"
    printf 'detail=%s\n' "$detail"
    printf 'written_epoch=%s\n' "$(reconcile_now)"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$receipt" || { rm -f "$tmp"; return 1; }
}

backlog_pr_receipt_status() { # <receipt>; prints closing, closed or nothing
  [ -f "$1" ] || return 0
  case "$(sed -n 's/^status=//p' "$1" 2>/dev/null | sed -n '1p')" in
    closing) printf 'closing\n' ;;
    *) printf 'closed\n' ;;
  esac
}

backlog_pr_with_locks() {
  local id=$1 control lock rc=1
  shift
  control="$STATE/.control-$id.lock"
  lock=$(fm_meta_lock_path "$STATE/$id.meta") || return 1
  fm_lock_try_acquire "$control" || return 1
  if fm_lock_try_acquire "$lock"; then
    "$@"
    rc=$?
    fm_lock_release "$lock"
  fi
  fm_lock_release "$control"
  return "$rc"
}

backlog_pr_close() {
  local data=$1 id=$2 receipt=$3 signature=$4 first_ref=$5 refs=$6 deadline=$7 incarnation=$8 detail=$9
  local remaining full current_refs meta="$STATE/$id.meta" state_line
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -ge 1 ] || return 3
  full=$(FM_BACKLOG_ROW_TIMEOUT_SECS=$remaining fm_backlog_row_show "$data" "$id" --full 2>/dev/null) || return 3
  [ "$(printf '%s\n' "$full" | sed -n 's/^  state: *//p' | head -1)" = in_flight ] || return 2
  [ "$(printf '%s\n' "$full" | sed -n 's/^  held: *//p' | head -1)" = no ] || return 2
  case "$(printf '%s\n' "$full" | sed -n 's/^  hold_kind: *//p' | head -1)" in
    -|'"-"') ;; *) return 2 ;;
  esac
  current_refs=$(printf '%s\n' "$full" | backlog_pr_refs)
  [ ! -L "$meta" ] || return 2
  if [ -f "$meta" ]; then
    [ "$(meta_incarnation "$meta")" = "$incarnation" ] || return 2
    current_refs=$(printf '%s\n%s\n' "$current_refs" "$(meta_field "$meta" pr)" | backlog_pr_refs)
    state_line=$(env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_NO_FORGE=1 \
      "$CREW_STATE_BIN" "$id" 2>/dev/null) || return 3
    case "$state_line" in 'state: done '*|'state: failed '*) ;; *) return 2 ;; esac
    status_line_verb "$(last_status_line "$STATE/$id.status")" | grep -Fx captain-held >/dev/null 2>&1 && return 2
  else
    [ -z "$incarnation" ] || return 2
  fi
  current_refs=$(printf '%s\n' "$current_refs" | sort -u | sed '/^$/d')
  [ "$current_refs" = "$refs" ] || return 2
  [ "$(date +%s)" -lt "$deadline" ] || return 3
  backlog_pr_receipt_write "$receipt" "$id" "$signature" closing "$detail" \
    && fm_backlog_done "$data" "$id" --pr "$first_ref" \
      --note "closed by inactive reconcile: pull request finished ($signature)" >/dev/null 2>&1
}

backlog_pr_publish() {
  [ "$main" -eq 1 ] && [ -n "$out" ] || return 0
  printf '%s' "$out" | x_reconcile_upsert 1 "$data/x-reconcile.json" main "$(reconcile_now)" 2>/dev/null
}

backlog_pr_recover() {
  local receipt=$1 id=$2 remaining full signature detail
  [ -z "$receipt" ] || [ "$(backlog_pr_receipt_status "$receipt")" = closing ] || return 0
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -ge 1 ] || return 1
  full=$(FM_BACKLOG_ROW_TIMEOUT_SECS=$remaining fm_backlog_row_show "$data" "$id" --full 2>/dev/null) || return 1
  [ "$(printf '%s\n' "$full" | sed -n 's/^  state: *//p' | head -1)" = done ] || return 0
  if [ -n "$receipt" ]; then
    signature=$(sed -n 's/^prs=//p' "$receipt" | sed -n '1p')
    detail=$(record_value "$receipt" detail)
    [ -n "$detail" ] || detail=$(backlog_pr_evidence "$signature") || return 1
    out="$out$id"$'\t'"fix"$'\t'"$detail"$'\n'
    backlog_pr_publish && backlog_pr_receipt_write "$receipt" "$id" "$signature" closed "$detail"
  else
    printf '%s' "$out" | awk -F'\t' -v id="$id" '$1 == id && $2 == "fix" && $3 ~ /^closed:/ { found=1 } END { exit !found }' && return 0
    out="$out$id"$'\t\t\n'
    backlog_pr_publish
  fi
}

backlog_pr_cursor_file() { printf '%s/backlog-pr-cursor\n' "$STATE"; }

backlog_pr_rows() {
  python3 -I -c '
import json, os, re, sys
path, main, outcomes = sys.argv[1:]
seen = set()
for row in sys.stdin:
    row = row.rstrip("\n")
    if row:
        print(row)
        seen.add(row.lstrip().split(",", 1)[0])
items = []
if main == "1":
    try:
        with open(path) as f:
            doc = json.load(f)
        if isinstance(doc, dict) and isinstance(doc.get("items"), list):
            items = doc["items"]
    except (OSError, ValueError):
        pass
for item in items:
    if not isinstance(item, dict) or item.get("source") != "inactive-reconcile" or item.get("home") != "main":
        continue
    item_id = item.get("id")
    if not isinstance(item_id, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", item_id) or item_id in seen:
        continue
    seen.add(item_id)
    print("  -,evidence," + item_id)
with os.scandir(outcomes) as entries:
    receipts = sorted(entry.path for entry in entries
                      if re.fullmatch(r"backlog-pr-[A-Za-z0-9._-]+[.]closed", entry.name))
for receipt in receipts:
    print("  -,receipt," + receipt)
' "$1/x-reconcile.json" "$2" "$OUTCOME_DIR"
}

backlog_pr_pass() { # <deadline> <main-home: 0|1>
  local deadline=$1 main=$2 config data rows row id refs ref meta state signature fingerprint receipt remaining
  local all_finished unreadable first_ref full out='' marks='' cache='' total start k idx cursor_file rstatus incarnation close_rc info detail
  config="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  data="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
  command -v gh >/dev/null 2>&1 && command -v tasks-axi >/dev/null 2>&1 || return 0
  fm_backlog_transition_applies "$config" "$data" ship >/dev/null 2>&1 || return 0
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -ge 1 ] || return 0
  rows=$(fm_backlog_row_list "$data" --state in_flight) || return 0
  rows=$(printf '%s\n' "$rows" | grep -E '^  [^,]+,in_flight,' || true)
  rows=$(printf '%s\n' "$rows" | backlog_pr_rows "$data" "$main" 2>/dev/null) || return 0
  total=$(printf '%s\n' "$rows" | sed '/^$/d' | wc -l | tr -d ' ')
  cursor_file=$(backlog_pr_cursor_file)
  start=$(sed -n '1p' "$cursor_file" 2>/dev/null || true)
  case "$start" in ''|*[!0-9]*) start=0 ;; esac
  [ "$total" -gt 0 ] || start=0
  k=0
  while [ "$k" -lt "$total" ]; do
    idx=$(( (start + k) % total ))
    k=$((k + 1))
    row=$(printf '%s\n' "$rows" | sed -n "$((idx + 1))p")
    id=${row#  }
    id=${id%%,*}
    valid_id "$id" || { printf '%s\n' $(( (idx + 1) % total )) > "$cursor_file" 2>/dev/null || true; continue; }
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -ge 1 ] || break
    printf '%s\n' $(( (idx + 1) % total )) > "$cursor_file" 2>/dev/null || true
    case "${row#*,}" in
      receipt,*)
        receipt=${row#*,receipt,}
        [ -f "$receipt" ] && [ ! -L "$receipt" ] || continue
        id=$(sed -n 's/^task_id=//p' "$receipt" | sed -n '1p')
        valid_id "$id" || continue
        backlog_pr_with_locks "$id" backlog_pr_recover "$receipt" "$id" || true
        continue
        ;;
      evidence,*)
        id=${row#*,evidence,}
        valid_id "$id" || continue
        backlog_pr_with_locks "$id" backlog_pr_recover '' "$id" || true
        continue
        ;;
    esac
    out="$out$id"$'\t'"unknown"$'\t'"in-flight record could not be examined before the time budget ran out"$'\n'
    backlog_pr_publish || true
    full=$(FM_BACKLOG_ROW_TIMEOUT_SECS=$remaining fm_backlog_row_show "$data" "$id" --full 2>/dev/null) || continue
    case "$(printf '%s\n' "$full" | sed -n 's/^  state: *//p' | head -1):$(printf '%s\n' "$full" | sed -n 's/^  held: *//p' | head -1):$(printf '%s\n' "$full" | sed -n 's/^  hold_kind: *//p' | head -1)" in
      'in_flight:no:-'|'in_flight:no:"-"') ;;
      *) out="$out$id"$'\t\t\n'; continue ;;
    esac
    meta="$STATE/$id.meta"
    [ -f "$meta" ] && [ ! -L "$meta" ] || meta=''
    incarnation=''
    refs=$(printf '%s\n' "$full" | backlog_pr_refs)
    if [ -n "$meta" ]; then
      incarnation=$(meta_incarnation "$meta")
      refs=$(printf '%s\n%s\n' "$refs" "$(meta_field "$meta" pr)" | backlog_pr_refs)
    fi
    refs=$(printf '%s\n' "$refs" | sort -u | sed '/^$/d')
    if [ -z "$refs" ]; then
      out="$out$id"$'\t\t\n'
      continue
    fi
    all_finished=1
    unreadable=0
    signature=''
    while IFS= read -r ref; do
      remaining=$((deadline - $(date +%s)))
      if [ "$remaining" -lt 1 ]; then all_finished=0; unreadable=1; break; fi
      info=$(printf '%s\n' "$cache" | awk -F'\t' -v u="$ref" '$1 == u { print $2 "\t" $3; exit }')
      if [ -z "$info" ]; then
        info=$(backlog_pr_state "$ref") || info=''
        [ -z "$info" ] || cache="$cache$ref"$'\t'"$info"$'\n'
      fi
      state=${info%%$'\t'*}
      case "$state" in
        MERGED|CLOSED) signature="${signature:+$signature,}$ref=$state" ;;
        '') all_finished=0; unreadable=1; break ;;
        *) all_finished=0; break ;;
      esac
    done <<EOF
$refs
EOF
    if [ "$unreadable" -eq 1 ]; then
      out="$out$id"$'\t'"unknown"$'\t'"pull request state could not be read in time"$'\n'
      [ "$(( deadline - $(date +%s) ))" -ge 1 ] || break
      continue
    fi
    if [ "$all_finished" -eq 1 ]; then
      fingerprint=$(sha256_text "$id|$signature")
      receipt="$OUTCOME_DIR/backlog-pr-$fingerprint.closed"
      rstatus=$(backlog_pr_receipt_status "$receipt")
      first_ref=$(printf '%s\n' "$refs" | sed -n '1p')
      # A closed receipt means this PR state was already closed once; a closing
      # receipt on a still-open record means the close never landed, so it is
      # retried under the same receipt.
      if [ "$rstatus" != closed ]; then
        detail=$(backlog_pr_evidence "$signature") || continue
        close_rc=0
        backlog_pr_with_locks "$id" backlog_pr_close "$data" "$id" "$receipt" "$signature" "$first_ref" "$refs" "$deadline" "$incarnation" "$detail" || close_rc=$?
        if [ "$close_rc" -eq 0 ]; then
          out="$out$id"$'\t'"fix"$'\t'"$detail"$'\n'
          marks="$marks$receipt"$'\t'"$id"$'\t'"$signature"$'\t'"$detail"$'\n'
        elif [ "$close_rc" -eq 2 ]; then
          out="$out$id"$'\t\t\n'
        elif [ "$close_rc" -ne 3 ]; then
          out="$out$id"$'\t'"fix"$'\t'"pull request finished but the record is still in flight: $signature"$'\n'
        fi
      else
        out="$out$id"$'\t\t\n'
      fi
    else
      out="$out$id"$'\t\t\n'
    fi
    backlog_pr_publish || true
  done
  backlog_pr_publish || return 0
  while IFS=$'\t' read -r receipt id signature detail; do
    [ -n "$receipt" ] || continue
    backlog_pr_receipt_write "$receipt" "$id" "$signature" closed "$detail" || true
  done <<EOF
$marks
EOF
}

scan() {
  local startup=${1:-0} self='' cursor deadline rc=0 marker_rc=0 main_home share
  mkdir -p "$STATE" "$OUTCOME_DIR" || return 1
  [ ! -L "$OUTCOME_DIR" ] || return 1
  if self=$(home_secondmate_id); then
    # The ledger-first delivery is per poll, not per cadence.
    ledger_pass
  else
    marker_rc=$?
    self=''
  fi
  if [ "$startup" != 1 ] && [ "$(scan_marker_age)" -lt "$FM_INACTIVE_RECONCILE_SECS" ]; then
    return 0
  fi
  cursor=$(scan_marker_cursor)
  valid_id "$cursor" || cursor=''
  write_scan_marker "$cursor" || return 1
  if [ -z "$self" ] && [ "$marker_rc" -ne 1 ]; then
    publish_actionable "inactive-reconcile-diagnostic:invalid-secondmate-home" \
      "inactive terminal outcomes remain unreconciled: invalid .fm-secondmate-home marker" || true
    return 0
  fi
  deadline=$(( $(date +%s) + FM_INACTIVE_RECONCILE_BUDGET_SECS ))
  main_home=0
  [ -n "$self" ] || main_home=1
  share=$(( FM_INACTIVE_RECONCILE_BUDGET_SECS / 2 ))
  [ "$share" -ge 1 ] || share=1
  fm_run_timed "$share" "$0" _backlog-pr-pass $(( $(date +%s) + share )) "$main_home" || true
  SCAN_FIRST_VISIT_PENDING=1
  scan_pass "$cursor" after "$deadline" "$self" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$cursor" ]; then
    scan_pass "$cursor" through "$deadline" "$self" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    write_scan_marker '' || return 1
  elif [ "$rc" -ne 3 ]; then
    return "$rc"
  fi
}

acknowledge() { # <fingerprint>
  local fingerprint=$1 pending presented phase
  case "$fingerprint" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  [ -d "$OUTCOME_DIR" ] && [ ! -L "$OUTCOME_DIR" ] || return 1
  pending=$(record_path "$fingerprint" pending)
  presented=$(record_path "$fingerprint" presented)
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 0
  phase=$(record_value "$pending" phase)
  [ "$phase" = presentation ] || return 0
  mv -f "$pending" "$presented"
}

acknowledge_notice() { # <fingerprint>
  local fingerprint=$1 pending
  case "$fingerprint" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  [ -d "$OUTCOME_DIR" ] && [ ! -L "$OUTCOME_DIR" ] || return 1
  pending=$(record_path "$fingerprint" pending)
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 0
  record_field_set "$pending" notice_emitted 1
}

mode=${1:-scan}
case "$mode" in
  scan)
    startup=0
    case "${2:-}" in
      '') ;;
      --startup) startup=1 ;;
      *) printf 'usage: fm-inactive-reconcile.sh scan [--startup]\n' >&2; exit 2 ;;
    esac
    # The scan's own whole-second deadline enforces the budget; this outer
    # process-group kill is only the backstop for a scan wedged outside every
    # bounded section (an unbounded lock wait), so it fires one second after
    # the deadline instead of racing the clean bounded exit it exists to guard.
    if fm_run_timed $((FM_INACTIVE_RECONCILE_BUDGET_SECS + 1)) "$0" _scan-locked "$startup"; then
      :
    elif [ "$?" -ne 124 ]; then
      exit 1
    fi
    ;;
  _backlog-pr-pass)
    [ "$#" -eq 3 ] || exit 2
    unset FM_TASKS_AXI_TIMEOUT
    backlog_pr_pass "$2" "$3"
    ;;
  _scan-locked)
    [ "$#" -eq 2 ] || exit 2
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    scan "$2"
    ;;
  report)
    if [ "$#" -ne 2 ] || ! valid_id "$2"; then
      printf 'usage: fm-inactive-reconcile.sh report <task-id>\n' >&2
      exit 2
    fi
    report_child "$2"
    ;;
  acknowledge)
    [ "$#" -eq 2 ] || { printf 'usage: fm-inactive-reconcile.sh acknowledge <fingerprint>\n' >&2; exit 2; }
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    acknowledge "$2"
    ;;
  acknowledge-notice)
    [ "$#" -eq 2 ] || exit 2
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    acknowledge_notice "$2"
    ;;
  -h|--help)
    sed -n '2,40{s/^# \{0,1\}//;p;}' "$0"
    ;;
  *)
    printf 'usage: fm-inactive-reconcile.sh scan [--startup]\n' >&2
    printf '       fm-inactive-reconcile.sh acknowledge <fingerprint>\n' >&2
    exit 2
    ;;
esac
