#!/usr/bin/env bash
# fm-pr-orphan-sweep.sh - notice a conflicted pull request that no task watches.
#
# A task's own merge poll (bin/fm-pr-check.sh, bin/fm-pr-poll.sh) owns conflict
# recovery while that task's record and poll exist. A pull request whose poll
# never existed or was lost - a record removed before cleanup kept open-PR
# watches, a rebuilt home, a worker that never recorded its pull request - has
# nothing watching it, so a conflict on it would never reach anyone. This sweep
# is the home-level net under that per-task path: it discovers candidates from
# the forge, so discovery does not depend on any task record surviving.
#
# Usage:
#   fm-pr-orphan-sweep.sh            one bounded pass; bin/fm-watch.sh runs it in
#                                    every check sweep and is its only writer
#
# WHAT IS SWEPT. Every project in data/projects.md that is not local-only, has
# no forge binding (bin/fm-project-mode.sh --forge reads none), and whose clone
# at projects/<name> resolves to a github.com publication target through
# fm_role_publication_target in bin/fm-role-lib.sh. For each, the open pull requests
# that carry a label named conflict and whose head branch starts with literal
# fm/ are candidates. A candidate is covered, and skipped, when a valid task
# poll in this home names that exact pull request (fm_pr_poll_artifacts_valid in
# bin/fm-pr-lib.sh): that poll owns its recovery.
#
# WHEN IT WAKES. The label-age rule has one owner: each uncovered candidate is
# read through `bin/fm-pr-poll.sh --validated`, which reports conflict:<added-at>
# only once the label has been applied for at least 15 minutes. This shares the
# per-task eligibility threshold; check cadence (FM_CHECK_INTERVAL in
# bin/fm-watch.sh), forge reads, and the pass limits below affect when an eligible
# candidate is inspected.
#
# OWNER ROUTING. The task id is the head branch with fm/ removed. When
# this home's backlog holds that id (bin/fm-tasks-axi.sh show), the wake names it
# as this home's task. Otherwise a main home still wakes, naming no owner, so
# the main firstmate can route it; a secondmate home stays quiet, because the
# pull request is not its work and its main home sweeps the same project when
# registered there. A pull request body carries no home marker, so a home cannot
# tell which other home opened an unclaimed pull request.
# Coverage is local to this home: a pull request a secondmate home also watches
# may receive a harmless duplicate wake in the main home.
#
# PASS LIMITS. Each pass lists at most 200 conflict-labeled pull requests per
# project by default (FM_PR_ORPHAN_LIMIT) within a per-pass budget (90 seconds
# by default). There is no continuation cursor, so capped listings or budget
# exhaustion can leave candidates or later projects uninspected.
#
# ONE WAKE PER EPISODE. A wake is committed to the durable queue first, then the
# episode marker state/pr-orphan-conflict/github.com/<owner>/<repo>/<number>
# records its label added-at time, then the wake line is printed for the watcher
# to surface; an interruption between them repeats a wake rather than losing it.
# Each uncovered candidate's current label timestamp is compared to the stored
# timestamp, so removing and reapplying the label starts a new episode.
# Markers survive temporary poll coverage, label removal, listing omissions,
# and failed reads; only a wake for a different timestamp replaces a marker.
#
# FIRSTMATE RECOVERY. This is the one home of what firstmate does on a
# conflict wake, for both forms: a task poll's `check:` result of `conflict`
# and this sweep's `check: pr-orphan-conflict:`. Either means the pull request
# has carried the conflict label for at least 15 minutes and automatic recovery
# could not run or became unavailable. Recover it in that wake:
#   1. Dispatch the worker: the task's own worker for `conflict`; for
#      `pr-orphan-conflict`, a fresh worker on that branch, or, when the wake
#      names no task in this home, route it to the secondmate whose scope owns it.
#   2. The worker merges the base branch in with a merge commit.
#   3. It regenerates generated files.
#   4. It runs their tests.
#   5. It pushes once.
# Rebasing and force-pushing stay out of this recovery.
# fm_pr_conflict_instruction in bin/fm-pr-lib.sh writes the same steps as the
# automatic worker steer.
#
# DETECT AND WAKE ONLY. Nothing here comments on, labels, merges, rebases, or
# pushes a pull request, and nothing steers or relaunches a worker.
#
# Exit 0 after a pass, including one that skipped unreadable projects (each is
# reported on stderr for the watcher's triage log); exit 2 on bad usage.
#
# Tunables (env), mainly for tests:
#   FM_PR_ORPHAN_SHOW_CMD    prefix command receiving <task-id>; exit 0 means
#                            this home's backlog holds it
#   FM_PR_ORPHAN_BOUND       per-forge-call bound in seconds (default 20)
#   FM_PR_ORPHAN_BUDGET      whole-pass budget in seconds (default 90)
#   FM_PR_ORPHAN_LIMIT       pull requests listed per project (default 200)
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
export FM_HOME

if [ "$#" -ne 0 ]; then
  echo "usage: fm-pr-orphan-sweep.sh" >&2
  exit 2
fi

REG="$DATA/projects.md"
[ -f "$REG" ] && [ ! -L "$REG" ] || exit 0

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

BOUND=${FM_PR_ORPHAN_BOUND:-20}
case "$BOUND" in ''|*[!0-9]*|0) BOUND=20 ;; esac
BUDGET=${FM_PR_ORPHAN_BUDGET:-90}
case "$BUDGET" in ''|*[!0-9]*|0) BUDGET=90 ;; esac
LIMIT=${FM_PR_ORPHAN_LIMIT:-200}
case "$LIMIT" in ''|*[!0-9]*|0) LIMIT=200 ;; esac
MARKERS="$STATE/pr-orphan-conflict"
MARKER_VERSION=fm-pr-orphan-conflict-v1

fm_checkpoint_clock || exit 0
FM_CHECKPOINT_DEADLINE=$((FM_CHECKPOINT_NOW + BUDGET))

MAIN_HOME=1
home_rc=0
fm_parent_channel_home_id "$FM_HOME" >/dev/null 2>&1 || home_rc=$?
# Only a proven secondmate identity stays quiet on unclaimed pull requests; an
# unusable marker reports, which repeats a wake rather than losing one.
[ "$home_rc" -ne 0 ] || MAIN_HOME=0

warn() {
  printf 'fm-pr-orphan-sweep: %s\n' "$*" >&2
}

# Registered project names, one per line. A name ends at the " [" or " - " that
# follows it (bin/fm-project-mode.sh owns the line format).
registered_projects() {
  local line name
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '- '*) ;;
      *) continue ;;
    esac
    name=${line#- }
    name=${name%% \[*}
    name=${name%% - *}
    [ -n "$name" ] || continue
    printf '%s\n' "$name"
  done < "$REG"
}

# Pull request URLs that a valid task poll in this home watches, one per line.
covered_urls() {
  local data id
  for data in "$STATE"/*.pr-poll; do
    [ -f "$data" ] || continue
    id=${data##*/}
    id=${id%.pr-poll}
    fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" 2>/dev/null || continue
    printf '%s\n' "$FM_PR_DATA_URL" | tr '[:upper:]' '[:lower:]'
  done
}

marker_added_at() {  # <marker>; print the recorded added-at of a valid marker
  local marker=$1 version url added _extra
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  { exec 8< "$marker"; } 2>/dev/null || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r added <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then exec 8<&-; return 1; fi
  exec 8<&-
  [ "$version" = "$MARKER_VERSION" ] && [ -n "$url" ] && [ -n "$added" ] || return 1
  printf '%s\n' "$added"
}

marker_write() {  # <marker> <url> <added-at>
  local marker=$1 url=$2 added=$3 dir tmp
  dir=${marker%/*}
  mkdir -p "$dir" || return 1
  tmp=$(umask 077; mktemp "$dir/.marker.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n' "$MARKER_VERSION" "$url" "$added" > "$tmp" \
    || ! mv -f "$tmp" "$marker"; then
    rm -f "$tmp"
    return 1
  fi
}

task_claimed_here() {  # <task-id>
  local id=$1 bound
  fm_pr_task_id_valid "$id" || return 1
  bound=$(fm_checkpoint_budget "$BOUND") || return 1
  if [ -n "${FM_PR_ORPHAN_SHOW_CMD:-}" ]; then
    # shellcheck disable=SC2086 # A test seam: a prefix command plus its words.
    fm_run_timed "$bound" $FM_PR_ORPHAN_SHOW_CMD "$id" >/dev/null 2>&1
  else
    fm_run_timed "$bound" "$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" >/dev/null 2>&1
  fi
}

sweep_project() {  # <name>
  local name=$1 clone target path mode forge bound listing number head url
  local result added previous task owner reason marker dir
  case "$name" in
    */*|.|..) return 0 ;;
  esac
  clone="$PROJECTS/$name"
  [ -d "$clone" ] || return 0
  mode=$("$SCRIPT_DIR/fm-project-mode.sh" "$name" 2>/dev/null) || return 0
  [ "${mode%% *}" != local-only ] || return 0
  forge=$("$SCRIPT_DIR/fm-project-mode.sh" --forge "$name" 2>/dev/null) || return 0
  [ "$forge" = none ] || return 0
  target=$(fm_role_publication_target "$clone") || return 0
  case "$target" in
    github.com/*) path=${target#github.com/} ;;
    *) return 0 ;;
  esac
  fm_pr_url_parse "https://github.com/$path/pull/1" || return 0
  path=$FM_PR_PATH

  bound=$(fm_checkpoint_budget "$BOUND") || return 0
  listing=$(fm_run_timed "$bound" gh pr list -R "$path" --state open --label conflict \
    --limit "$LIMIT" --json number,headRefName \
    --jq '.[] | "\(.number)\t\(.headRefName)"' 2>&1) || {
    warn "could not list conflicted pull requests for $name ($path): $(printf '%s' "$listing" | head -1)"
    return 0
  }

  dir="$MARKERS/github.com/$path"
  while IFS=$'\t' read -r number head; do
    [ -n "$number" ] || continue
    case "$number" in *[!0-9]*) continue ;; esac
    case "$head" in
      fm/*) ;;
      *) continue ;;
    esac
    fm_pr_url_parse "https://github.com/$path/pull/$number" || continue
    url=$FM_PR_URL
    if printf '%s\n' "$COVERED" | grep -Fqx -- "$url"; then
      continue
    fi
    task=${head#fm/}
    marker="$dir/$number"
    if fm_checkpoint_expired; then
      warn "pass budget spent before $url"
      continue
    fi
    if task_claimed_here "$task"; then
      owner="task $task in this home's backlog"
    elif [ "$MAIN_HOME" = 1 ]; then
      owner="no task in this home's backlog is named $task"
    else
      continue
    fi
    bound=$(fm_checkpoint_budget "$BOUND") || continue
    result=$(fm_run_timed "$bound" "$SCRIPT_DIR/fm-pr-poll.sh" --validated github "$url" github.com "$path" "$number" 2>/dev/null) || {
      warn "could not read the conflict label age of $url"
      continue
    }
    case "$result" in
      conflict:*) added=${result#conflict:} ;;
      *) continue ;;
    esac
    previous=$(marker_added_at "$marker") || previous=
    [ "$previous" != "$added" ] || continue
    reason="check: pr-orphan-conflict: $url (branch $head) has carried the conflict label since $added and no task poll watches it; owner: $owner"
    fm_wake_append check "pr-orphan:$url" "$reason" || {
      warn "could not queue the wake for $url"
      continue
    }
    marker_write "$marker" "$url" "$added" || warn "queued the wake for $url but could not record its episode"
    printf '%s\n' "$reason"
  done <<EOF
$listing
EOF
}

COVERED=$(covered_urls)
while IFS= read -r project; do
  [ -n "$project" ] || continue
  if fm_checkpoint_expired; then
    warn "pass budget spent before project $project"
    break
  fi
  sweep_project "$project"
done <<EOF
$(registered_projects)
EOF
exit 0
