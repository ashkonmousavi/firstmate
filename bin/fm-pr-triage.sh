#!/usr/bin/env bash
# fm-pr-triage.sh - rank one repository's open pull requests and act on the
# top two ranks, with no model in the loop, keeping one record per pull
# request per pass.
#
# Usage:
#   fm-pr-triage.sh                 dry run: print the ranking, the decisions and
#                                   the commands a real pass would run; write nothing
#   fm-pr-triage.sh --apply         one real pass: GitHub writes and fix-worker
#                                   launches happen, one record per pull request
#   fm-pr-triage.sh --print-timer   print a proposed systemd user timer and cron line
#   fm-pr-triage.sh --help
#
# A plain scheduler runs `--apply` every five minutes with FM_HOME set
# explicitly. Nothing here enables a schedule; docs/configuration.md
# "PR triage" owns enabling it per machine.
#
# RULES. config/pr-triage-rules is required; key=value lines, # comments and
# blank lines allowed, unknown keys refused:
#   repo=<owner>/<name>   required; the GitHub repository to triage
#   project=<name>        required; the registered project whose branch prefix
#                         maps a pull request's head branch to this home's task
#   title=<ERE>           rank-1 class: the title matches (case-insensitive)
#   label=<name>          rank-1 class: the pull request carries this label
#   path=<glob>           rank-1 class: a changed file matches the shell glob
# title=, label= and path= repeat; together they name the pull requests that
# unblock others now (CI or test speed, red-main repair). Never list main-red
# as a label= rule: this script applies that label, so the rule would keep a
# pull request at rank 1 after its first pass.
#
# RANK. A tier number, not a list position:
#   1  a rules class above matches, or the pull request is on the J-01 path:
#      its title or head branch carries the token J-01 (or j01), or its task is
#      a backlog item whose title carries J-01, or a transitive blocked-by
#      blocker of such an item;
#   2  its task blocks at least one open backlog item (blocked-by edges);
#   3  the rest.
# Within a rank, more blocked items first, then the lower number.
# The task of a pull request is its head branch with the project's registered
# branch prefix (bin/fm-project-mode.sh --branch-prefix) removed.
# Backlog reads use this home's backlog (bin/fm-tasks-axi.sh list and show).
#
# ACTIONS, for ranks 1 and 2 only; every pull request still gets a record.
#   Skipped first, in this order: excluded (config/pr-triage-exclude), a
#   merge-queue batch (author mergify or head mergify/merge-queue/), a draft,
#   or the label hold.
#   CONFLICTING or a FAILURE/ERROR check rollup -> fix. The fix worker launches
#   only for a task this home's backlog holds, with a state/<id>.meta record:
#     - its worker is alive                -> refused:worker live
#     - its worker exited, or the record is a released copy
#       (worktree=*.released-copy)         -> bin/fm-control.sh <id> relaunch
#                                             --note <instruction>, which is
#                                             bin/fm-spawn.sh --relaunch with
#                                             the machine-lane and project
#                                             admission every launch takes
#     - liveness unproved, a lane-release stop, no record, or no backlog item
#       here                               -> refused with that reason
#   Before a launch, bin/fm-capacity.sh --admit must admit (the auto-launcher's
#   admission rule) and state/spawn-deferred/queue must not already hold the
#   task. At most one launch per pull request head: state/pr-triage/fix-<n>
#   records the head commit launched for, and the same head is refused.
#   MERGEABLE and a SUCCESS rollup -> queue, read against the real Mergify
#   queue, never a label, a comment or an earlier record:
#     `mergify queue status --json` (batches, forming batches and waiting pull
#     requests) and `mergify queue show <n> --json` (.queued). Queued in either
#     -> `already queued`, no write. A paused queue or an unreadable queue
#     state -> refused, no write. Otherwise add the label main-red when absent
#     and comment `@mergifyio queue`; state/pr-triage/queue-<n> records the
#     head commented on, and the same head within 30 minutes is refused as
#     pending so a slow queue pickup never gets a second comment.
#   Anything else (checks pending or absent, mergeability UNKNOWN) -> refused,
#   no write and no launch.
# A fix record names the real queue state it read (queue=queued, queue=not
# queued, or queue=unknown), so a red pull request is never reported queued.
#
# EXCLUSIONS. config/pr-triage-exclude, optional: one shell glob per line,
# # comments and blank lines ignored, matched against the pull request number,
# its head branch, and its task id.
#
# TOOLS. Pull requests are read with one paginated `gh api graphql` query,
# because gh-axi renders TOON only and the record logic needs JSON; label and
# comment writes use gh-axi. Every forge and Mergify call is time-bounded.
#
# RECORDS. state/pr-triage.log, append-only, one line per pull request per pass:
#   <UTC time>\t<pr url>\t<rank>\t<action>\t<result>
# action is fix, queue, or none; result is the outcome or refused:<reason>.
# A pass that cannot read the pull requests writes one record with - fields.
# Tabs and line breaks inside a reason become spaces. Each record is also
# printed on stdout. The dry run prints `would-record:` lines and `would-run:`
# commands, takes no lock and writes no file, label, comment or launch.
#
# Exit: 0 after a pass (refusals included) or a busy lock; 1 when the rules,
# the pull requests, the backlog or the log cannot be read or written; 2 usage.
# Test seams, honored only with FM_TEST_SEAM=1: FM_PR_TRIAGE_GH_BIN,
# FM_PR_TRIAGE_GHAXI_BIN, FM_PR_TRIAGE_MERGIFY_BIN, FM_PR_TRIAGE_CAPACITY_BIN,
# FM_PR_TRIAGE_CONTROL_BIN replace gh, gh-axi, mergify, fm-capacity.sh and
# fm-control.sh; FM_PR_TRIAGE_POSTURE_BIN, given <state> <id>, prints live,
# exited, unknown or none in place of the backend liveness read.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME

usage() { echo 'usage: fm-pr-triage.sh [--apply|--print-timer|--help]' >&2; }

ACTION=dry
case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  --apply) ACTION=apply ;;
  --print-timer) ACTION=timer ;;
  *) usage; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage; exit 2; }

LOG="$STATE/pr-triage.log"
LOCK="$STATE/.pr-triage.lock"
MARKS="$STATE/pr-triage"
RULES="$CONFIG/pr-triage-rules"
EXCLUDE="$CONFIG/pr-triage-exclude"
BOUND=${FM_PR_TRIAGE_BOUND:-60}
QUEUE_COMMENT_HOLD=1800

GH_BIN=gh
GHAXI_BIN=gh-axi
MERGIFY_BIN=mergify
CAPACITY_BIN="$SCRIPT_DIR/fm-capacity.sh"
CONTROL_BIN="$SCRIPT_DIR/fm-control.sh"
POSTURE_BIN=
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  GH_BIN=${FM_PR_TRIAGE_GH_BIN:-$GH_BIN}
  GHAXI_BIN=${FM_PR_TRIAGE_GHAXI_BIN:-$GHAXI_BIN}
  MERGIFY_BIN=${FM_PR_TRIAGE_MERGIFY_BIN:-$MERGIFY_BIN}
  CAPACITY_BIN=${FM_PR_TRIAGE_CAPACITY_BIN:-$CAPACITY_BIN}
  CONTROL_BIN=${FM_PR_TRIAGE_CONTROL_BIN:-$CONTROL_BIN}
  POSTURE_BIN=${FM_PR_TRIAGE_POSTURE_BIN:-}
fi

if [ "$ACTION" = timer ]; then
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || { echo "fm-pr-triage: cannot resolve FM_HOME" >&2; exit 1; } ;;
  esac
  cmd="FM_HOME=$(printf '%q' "$home") $(printf '%q' "$SCRIPT_DIR/fm-pr-triage.sh") --apply"
  cat <<EOF
# Proposed schedule for $home (not installed; see docs/configuration.md "PR triage").
# Register the unit in the machine inventory and route pause/resume through
# the fleet pause tool before enabling it.
#
# ~/.config/systemd/user/fm-pr-triage.service
[Unit]
Description=Firstmate PR triage pass for $home

[Service]
Type=oneshot
Environment=FM_HOME=$home
ExecStart=$SCRIPT_DIR/fm-pr-triage.sh --apply

# ~/.config/systemd/user/fm-pr-triage.timer
[Unit]
Description=Firstmate PR triage every five minutes for $home

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target

# Or one crontab line instead of the two units:
*/5 * * * * $cmd >/dev/null 2>&1
EOF
  exit 0
fi

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-lane-release-lib.sh
. "$SCRIPT_DIR/fm-lane-release-lib.sh"

flat() { printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-300; }

TMPD=
LOCK_HELD=0
# shellcheck disable=SC2329 # Invoked through the EXIT trap below.
cleanup() {
  [ -z "$TMPD" ] || rm -rf -- "$TMPD"
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$LOCK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# record <pr> <rank> <action> <result>
record() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ)	$(flat "$1")	$(flat "$2")	$(flat "$3")	$(flat "$4")"
  if [ "$ACTION" = dry ]; then
    printf 'would-record: %s\n' "$line"
    return 0
  fi
  printf '%s\n' "$line" >> "$LOG" || { echo "fm-pr-triage: cannot append to $LOG" >&2; exit 1; }
  printf '%s\n' "$line"
}

# would_run <cmd...>: the dry run's view of a write or launch.
would_run() {
  printf 'would-run:'
  printf ' %q' "$@"
  printf '\n'
}

# --- rules ------------------------------------------------------------------
R_REPO='' R_PROJECT=''
read_rules() {
  local line key value
  [ -f "$RULES" ] && [ -r "$RULES" ] || { echo "fm-pr-triage: missing rules file $RULES (see --help)" >&2; return 1; }
  : > "$TMPD/rule-title"; : > "$TMPD/rule-label"; : > "$TMPD/rule-path"
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) echo "fm-pr-triage: rules line without key=value: $line" >&2; return 1 ;; esac
    key=${line%%=*} value=${line#*=}
    case "$key" in
      repo) R_REPO=$value ;;
      project) R_PROJECT=$value ;;
      title) printf '%s\n' "$value" >> "$TMPD/rule-title" ;;
      label) printf '%s\n' "$value" >> "$TMPD/rule-label" ;;
      path) printf '%s\n' "$value" >> "$TMPD/rule-path" ;;
      *) echo "fm-pr-triage: rules file has unknown key $key" >&2; return 1 ;;
    esac
  done < "$RULES"
  case "$R_REPO" in
    */*) ;;
    *) echo "fm-pr-triage: rules repo= must be <owner>/<name>" >&2; return 1 ;;
  esac
  case "$R_PROJECT" in
    ''|.|..|*/*) echo "fm-pr-triage: rules project= is missing or not a plain name" >&2; return 1 ;;
  esac
}

# --- pull requests ------------------------------------------------------------
# read_prs: writes $TMPD/prs.json, one JSON array of open pull requests.
read_prs() {
  local owner=${R_REPO%%/*} name=${R_REPO#*/} query
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansions
  query='query($owner:String!,$name:String!,$endCursor:String){repository(owner:$owner,name:$name){pullRequests(states:OPEN,first:50,after:$endCursor,orderBy:{field:CREATED_AT,direction:ASC}){pageInfo{hasNextPage endCursor} nodes{number url title isDraft headRefName headRefOid baseRefName mergeable author{login} labels(first:50){nodes{name}} files(first:100){nodes{path}} commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}}'
  fm_run_timed "$BOUND" "$GH_BIN" api graphql --paginate -f owner="$owner" -f name="$name" -f query="$query" \
    > "$TMPD/prs.raw" 2> "$TMPD/prs.err" || return 1
  jq -s '[.[].data.repository.pullRequests.nodes[]]' "$TMPD/prs.raw" > "$TMPD/prs.json" 2>> "$TMPD/prs.err" || return 1
}

# --- Mergify queue --------------------------------------------------------------
# read_queue: sets QUEUE_OK (1 readable), QUEUE_PAUSED (1 paused) and writes
# $TMPD/queued, the queued pull request numbers.
QUEUE_OK=0 QUEUE_PAUSED=0
read_queue() {
  : > "$TMPD/queued"
  fm_run_timed "$BOUND" "$MERGIFY_BIN" queue status --repository "$R_REPO" --json \
    > "$TMPD/queue.json" 2> "$TMPD/queue.err" || return 0
  jq -r '[(.batches // [])[].pull_requests[]?.number,
          (.forming_batches // [])[].pull_requests[]?.number,
          (.waiting_pull_requests // [])[]?.number] | .[] | select(. != null)' \
    "$TMPD/queue.json" > "$TMPD/queued" 2>/dev/null || return 0
  if jq -e '.pause != null' "$TMPD/queue.json" >/dev/null 2>&1; then
    QUEUE_PAUSED=1
  fi
  QUEUE_OK=1
}

# queue_state <number>: prints queued, not queued, or unknown, reading the
# status snapshot and then `queue show` for this pull request.
queue_state() {
  local n=$1 out q
  [ "$QUEUE_OK" = 1 ] || { printf 'unknown\n'; return 0; }
  if grep -qx "$n" "$TMPD/queued"; then
    printf 'queued\n'; return 0
  fi
  out=$(fm_run_timed "$BOUND" "$MERGIFY_BIN" queue show "$n" --repository "$R_REPO" --json 2>/dev/null) \
    || { printf 'unknown\n'; return 0; }
  q=$(printf '%s\n' "$out" | jq -r 'if (.queued | type) == "boolean" then .queued else "unknown" end' 2>/dev/null) || q=unknown
  case "$q" in
    true) printf 'queued\n' ;;
    false) printf 'not queued\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# --- backlog ------------------------------------------------------------------
# read_backlog: writes $TMPD/backlog.tsv as id, title, blockers (comma list),
# one line per open backlog item.
read_backlog() {
  local out id show title blockers
  out=$("$SCRIPT_DIR/fm-tasks-axi.sh" list --limit 100000 2>&1) || {
    printf 'backlog unreadable: %s\n' "$(flat "$out")" >&2
    return 1
  }
  : > "$TMPD/backlog.tsv"
  for id in $(printf '%s\n' "$out" | awk '
      /^tasks\[[0-9]+\]/ { inside = 1; next }
      inside && /^  [^ ]/ { sub(/^  /, ""); sub(/,.*/, ""); print; next }
      inside { inside = 0 }'); do
    show=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" --full 2>/dev/null) || continue
    title=$(printf '%s\n' "$show" | sed -n 's/^  title: //p' | head -1 | sed 's/^"//; s/"$//')
    blockers=$(printf '%s\n' "$show" | sed -n 's/^  blocked_by: //p' | head -1 | tr -d '" ')
    case "$blockers" in none|-) blockers= ;; esac
    printf '%s\t%s\t%s\n' "$id" "$(flat "$title")" "$blockers" >> "$TMPD/backlog.tsv"
  done
}

has_j01() {
  printf '%s\n' "$1" | grep -Eqi '(^|[^A-Za-z0-9])j-?01($|[^0-9])'
}

# backlog_index: writes $TMPD/blocked-count (id \t n) and $TMPD/j01-path (ids
# on the J-01 path: J-01 titled items and their transitive blockers).
backlog_index() {
  local id title blockers frontier next b
  awk -F'\t' '$3 != "" { n = split($3, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") c[a[i]]++ }
    END { for (k in c) printf "%s\t%d\n", k, c[k] }' "$TMPD/backlog.tsv" > "$TMPD/blocked-count"
  : > "$TMPD/j01-path"
  while IFS=$'\t' read -r id title blockers; do
    has_j01 "$title" && printf '%s\n' "$id" >> "$TMPD/j01-path"
  done < "$TMPD/backlog.tsv"
  frontier=$(cat "$TMPD/j01-path")
  while [ -n "$frontier" ]; do
    next=
    for id in $frontier; do
      blockers=$(awk -F'\t' -v id="$id" '$1 == id { print $3; exit }' "$TMPD/backlog.tsv")
      for b in $(printf '%s' "$blockers" | tr ',' ' '); do
        grep -qxF "$b" "$TMPD/j01-path" && continue
        printf '%s\n' "$b" >> "$TMPD/j01-path"
        next="$next $b"
      done
    done
    frontier=$next
  done
}

blocked_count() {
  local n
  n=$(awk -F'\t' -v id="$1" '$1 == id { print $2; exit }' "$TMPD/blocked-count")
  printf '%s\n' "${n:-0}"
}

in_backlog() {
  [ -n "$1" ] && awk -F'\t' -v id="$1" '$1 == id { f = 1 } END { exit !f }' "$TMPD/backlog.tsv"
}

# --- per pull request -----------------------------------------------------------
# pr_field <number> <jq-expr>
pr_field() {
  jq -r --argjson n "$1" ".[] | select(.number == \$n) | $2" "$TMPD/prs.json"
}

# rank_of <number> <task>: prints rank, blocked count and class (TSV).
rank_of() {
  local n=$1 task=$2 title head pat count class=''
  title=$(pr_field "$n" '.title')
  head=$(pr_field "$n" '.headRefName')
  count=0
  [ -z "$task" ] || count=$(blocked_count "$task")
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    if printf '%s\n' "$title" | grep -Eqi -- "$pat" 2>/dev/null; then class="title:$pat"; break; fi
  done < "$TMPD/rule-title"
  if [ -z "$class" ]; then
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      if pr_field "$n" '.labels.nodes[].name' | grep -qxF -- "$pat"; then class="label:$pat"; break; fi
    done < "$TMPD/rule-label"
  fi
  if [ -z "$class" ] && [ -s "$TMPD/rule-path" ]; then
    pr_field "$n" '.files.nodes[].path' > "$TMPD/files"
    while IFS= read -r pat && [ -z "$class" ]; do
      [ -n "$pat" ] || continue
      while IFS= read -r f; do
        # shellcheck disable=SC2254 # the rules line is a deliberate glob
        case "$f" in $pat) class="path:$pat"; break ;; esac
      done < "$TMPD/files"
    done < "$TMPD/rule-path"
  fi
  if [ -z "$class" ]; then
    if has_j01 "$title" || has_j01 "$head"; then
      class=J-01
    elif [ -n "$task" ] && grep -qxF -- "$task" "$TMPD/j01-path"; then
      class=J-01
    fi
  fi
  if [ -n "$class" ]; then
    printf '1\t%s\t%s\n' "$count" "$class"
  elif [ "$count" -gt 0 ]; then
    printf '2\t%s\tblocks %s\n' "$count" "$count"
  else
    printf '3\t0\t-\n'
  fi
}

excluded_by() {
  local line pat subject
  [ -f "$EXCLUDE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    pat=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$pat" in ''|'#'*) continue ;; esac
    for subject in "$1" "$2" "$3"; do
      [ -n "$subject" ] || continue
      # shellcheck disable=SC2254 # the exclusion line is a deliberate glob
      case "$subject" in $pat) printf '%s\n' "$pat"; return 0 ;; esac
    done
  done < "$EXCLUDE"
  return 1
}

deferred_pending() {
  local f
  for f in "$STATE/spawn-deferred/queue"/*; do
    [ -f "$f" ] || continue
    grep -qx "task=$1" "$f" 2>/dev/null && return 0
  done
  return 1
}

posture_of() {  # <id>
  if [ -n "$POSTURE_BIN" ]; then
    "$POSTURE_BIN" "$STATE" "$1" 2>/dev/null || printf 'unknown\n'
    return 0
  fi
  fm_pr_conflict_posture "$STATE" "$1"
}

released_copy() {  # <id>
  grep -q '^worktree=.*\.released-copy$' "$STATE/$1.meta" 2>/dev/null
}

capacity_admits() {
  local out rc=0
  out=$("$CAPACITY_BIN" --admit 2>&1) || rc=$?
  CAP_REASON=$(printf '%s\n' "$out" | sed -n '/^capacity:/{s/.*[[:space:]]reason=\([^[:space:]]*\).*/\1/p;q;}')
  [ -n "$CAP_REASON" ] || CAP_REASON=unreadable
  [ "$rc" = 0 ]
}

marker_get() {  # <file>: prints "<head> <epoch>" or nothing
  [ -f "$1" ] && head -1 "$1" 2>/dev/null
}

marker_put() {  # <file> <head>
  [ "$ACTION" = apply ] || return 0
  mkdir -p "$MARKS" && printf '%s %s\n' "$2" "$(date +%s)" > "$1"
}

fix_note() {  # <url> <base> <why>
  printf '%s\n' "PR triage ranks $1 among the pull requests to move first, and it is $3."
  printf '%s\n' "Merge origin/$2 into the branch with a merge commit if it conflicts, regenerate generated files, fix the failing checks, run their tests, and push once."
  printf '%s\n' "Do not rebase." "Do not force-push." "Report done with the same pull request URL when its checks are green."
}

# act_fix <number> <url> <rank> <task> <why> <head> <base>
act_fix() {
  local n=$1 url=$2 rank=$3 task=$4 why=$5 head=$6 base=$7 q posture mark rc note
  q=$(queue_state "$n")
  if [ -z "$task" ] || ! in_backlog "$task"; then
    record "$url" "$rank" fix "refused:not owned here: ${task:-no task branch} (queue=$q)"
    return 0
  fi
  if [ ! -f "$STATE/$task.meta" ]; then
    record "$url" "$rank" fix "refused:no task record for $task (queue=$q)"
    return 0
  fi
  mark=$(marker_get "$MARKS/fix-$n")
  if [ -n "$mark" ] && [ "${mark%% *}" = "$head" ]; then
    record "$url" "$rank" fix "refused:fix already launched for head ${head:0:12} (queue=$q)"
    return 0
  fi
  posture=$(posture_of "$task")
  if [ "$posture" = live ]; then
    record "$url" "$rank" fix "refused:worker live for $task (queue=$q)"
    return 0
  fi
  if fm_lane_release_marker_active "$STATE" "$task"; then
    record "$url" "$rank" fix "refused:lane release stopped $task on purpose (queue=$q)"
    return 0
  fi
  if [ "$posture" != exited ] && ! released_copy "$task"; then
    record "$url" "$rank" fix "refused:worker liveness $posture for $task (queue=$q)"
    return 0
  fi
  if deferred_pending "$task"; then
    record "$url" "$rank" fix "refused:spawn deferred pending for $task (queue=$q)"
    return 0
  fi
  if ! capacity_admits; then
    record "$url" "$rank" fix "refused:no capacity: $CAP_REASON (queue=$q)"
    return 0
  fi
  note=$(fix_note "$url" "$base" "$why")
  if [ "$ACTION" = dry ]; then
    would_run "$CONTROL_BIN" "$task" relaunch --note "$note"
    record "$url" "$rank" fix "launched $task (queue=$q)"
    return 0
  fi
  rc=0
  "$CONTROL_BIN" "$task" relaunch --note "$note" > "$TMPD/control.out" 2>&1 < /dev/null || rc=$?
  case "$rc" in
    0)
      marker_put "$MARKS/fix-$n" "$head"
      record "$url" "$rank" fix "launched $task (queue=$q)"
      ;;
    75) record "$url" "$rank" fix "refused:deferred: $(grep -m1 -E '^(deferred|error):' "$TMPD/control.out" || tail -1 "$TMPD/control.out") (queue=$q)" ;;
    *) record "$url" "$rank" fix "refused:launch error: $(grep -m1 '^error:' "$TMPD/control.out" || tail -1 "$TMPD/control.out") (exit $rc, queue=$q)" ;;
  esac
}

# act_queue <number> <url> <rank> <head>
act_queue() {
  local n=$1 url=$2 rank=$3 head=$4 q mark now out
  q=$(queue_state "$n")
  case "$q" in
    queued) record "$url" "$rank" queue "already queued"; return 0 ;;
    unknown) record "$url" "$rank" queue "refused:queue state unreadable"; return 0 ;;
  esac
  if [ "$QUEUE_PAUSED" = 1 ]; then
    record "$url" "$rank" queue "refused:queue paused"
    return 0
  fi
  mark=$(marker_get "$MARKS/queue-$n")
  now=$(date +%s)
  if [ -n "$mark" ] && [ "${mark%% *}" = "$head" ] && [ $((now - ${mark##* })) -lt "$QUEUE_COMMENT_HOLD" ]; then
    record "$url" "$rank" queue "refused:queue comment pending for head ${head:0:12}"
    return 0
  fi
  if ! pr_field "$n" '.labels.nodes[].name' | grep -qx 'main-red'; then
    if [ "$ACTION" = dry ]; then
      would_run "$GHAXI_BIN" pr edit "$n" --repo "$R_REPO" --add-label main-red
    elif ! out=$(fm_run_timed "$BOUND" "$GHAXI_BIN" pr edit "$n" --repo "$R_REPO" --add-label main-red 2>&1); then
      record "$url" "$rank" queue "refused:label failed: $(flat "$out")"
      return 0
    fi
  fi
  if [ "$ACTION" = dry ]; then
    would_run "$GHAXI_BIN" pr comment "$n" --repo "$R_REPO" --body '@mergifyio queue'
  elif ! out=$(fm_run_timed "$BOUND" "$GHAXI_BIN" pr comment "$n" --repo "$R_REPO" --body '@mergifyio queue' 2>&1); then
    record "$url" "$rank" queue "refused:comment failed: $(flat "$out")"
    return 0
  fi
  marker_put "$MARKS/queue-$n" "$head"
  record "$url" "$rank" queue "labelled main-red and commented queue (queue=$q)"
}

# --- pass -----------------------------------------------------------------------
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-triage.XXXXXX") || exit 1
read_rules || exit 1
[ -d "$STATE" ] || { echo "fm-pr-triage: state directory $STATE is unavailable" >&2; exit 1; }
if [ "$ACTION" = apply ]; then
  if ! fm_lock_try_acquire "$LOCK"; then
    echo "fm-pr-triage: another pass holds $LOCK${FM_LOCK_HELD_PID:+ (pid $FM_LOCK_HELD_PID)}; nothing done" >&2
    exit 0
  fi
  LOCK_HELD=1
fi

PREFIX=$("$SCRIPT_DIR/fm-project-mode.sh" --branch-prefix "$R_PROJECT" 2>/dev/null) || PREFIX=fm/
if ! read_prs; then
  record - - - "refused:pull requests unreadable: $(head -1 "$TMPD/prs.err")"
  exit 1
fi
if ! read_backlog 2> "$TMPD/backlog.err"; then
  record - - - "refused:$(head -1 "$TMPD/backlog.err")"
  exit 1
fi
backlog_index
read_queue

# Rank every pull request: rank, -blocked, number, task.
: > "$TMPD/ranked"
for n in $(jq -r '.[].number' "$TMPD/prs.json"); do
  head=$(pr_field "$n" '.headRefName')
  task=
  case "$head" in "$PREFIX"?*) task=${head#"$PREFIX"} ;; esac
  [ -n "$PREFIX" ] || task=$head
  IFS=$'\t' read -r rank count class <<<"$(rank_of "$n" "$task")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$rank" "$count" "$n" "$task" "$class" >> "$TMPD/ranked"
done
sort -t$'\t' -k1,1n -k2,2nr -k3,3n "$TMPD/ranked" > "$TMPD/ranked.sorted"

while IFS=$'\t' read -r rank count n task class; do
  url=$(pr_field "$n" '.url')
  head=$(pr_field "$n" '.headRefName')
  sha=$(pr_field "$n" '.headRefOid')
  base=$(pr_field "$n" '.baseRefName')
  author=$(pr_field "$n" '.author.login // ""')
  if pat=$(excluded_by "$n" "$head" "$task"); then
    record "$url" "$rank" none "refused:excluded: $pat"; continue
  fi
  case "$author:$head" in
    mergify*:*|*:mergify/merge-queue/*) record "$url" "$rank" none "refused:merge-queue batch"; continue ;;
  esac
  if [ "$rank" -gt 2 ]; then
    record "$url" "$rank" none "none"; continue
  fi
  if [ "$(pr_field "$n" '.isDraft')" = true ]; then
    record "$url" "$rank" none "refused:draft ($class)"; continue
  fi
  if pr_field "$n" '.labels.nodes[].name' | grep -qx 'hold'; then
    record "$url" "$rank" none "refused:held ($class)"; continue
  fi
  mergeable=$(pr_field "$n" '.mergeable')
  rollup=$(pr_field "$n" '.commits.nodes[0].commit.statusCheckRollup.state // "NONE"')
  why=
  [ "$mergeable" != CONFLICTING ] || why=conflicting
  case "$rollup" in
    FAILURE|ERROR) why="${why:+$why and }red" ;;
  esac
  if [ -n "$why" ]; then
    act_fix "$n" "$url" "$rank" "$task" "$why" "$sha" "$base"
  elif [ "$mergeable" = MERGEABLE ] && [ "$rollup" = SUCCESS ]; then
    act_queue "$n" "$url" "$rank" "$sha"
  elif [ "$mergeable" != MERGEABLE ]; then
    record "$url" "$rank" none "refused:mergeability $mergeable"
  else
    record "$url" "$rank" none "refused:checks $rollup"
  fi
done < "$TMPD/ranked.sorted"
exit 0
