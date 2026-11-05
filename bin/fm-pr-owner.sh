#!/usr/bin/env bash
# fm-pr-owner.sh - name the home and task that own a pull request, or say UNKNOWN.
#
# Usage:
#   fm-pr-owner.sh <pull-request-url> [--branch <head-branch> | --task <task-id>]
#
# Routing uses this so a finding about a pull request reaches the home that owns
# it. This header is the one owner of the rule.
#
# THE ROWS. Every row this home can see: its own backlog and done archive, plus
# the optional fleet list data/blocked-by-fleet-rows.tsv for every other home
# (fm_blocked_by_fleet_rows in bin/fm-blocked-by-lib.sh; the library header owns
# the list format). Open, done and archived rows all count. A row cites a pull
# request when its text carries that pull request's full URL; URLs compare by
# host, owner, repository and number (case-insensitive, leading zeros ignored),
# never by the bare number.
#
# THE RULE, in order:
#   1. A head branch fm/<id> names task <id> (--task <id> names it directly, for a
#      caller that already removed its project's own branch prefix). When rows named <id> are in exactly
#      one home, that home owns it.
#   2. When rows named <id> are in several homes, the one home whose row named
#      <id> cites the pull request owns it; otherwise it is UNKNOWN, with those
#      homes as candidates.
#   3. When no row is named <id> (or the branch is not fm/), the pull request is
#      owned by the one home and task whose rows cite it; several distinct
#      citing tasks, or none, make it UNKNOWN with the citing homes as candidates.
# Nothing else is guessed: the first matching row never wins on its own.
#
# THE HEAD BRANCH. Pass --branch (or --task) when the caller already listed it.
# Without either the script reads the pull request once (`gh pr view <url> --json headRefName`);
# a failed read leaves rule 3 alone.
#
# NO FLEET LIST. With no list, or one older than FM_BLOCKED_BY_FLEET_MAX_AGE
# (six hours by default), the answer is still given from the rows that can be
# read, and a fleet_list line names the gap, because an owner in another home
# may not be seen.
#
# Output (TSV), then exit status:
#   known<TAB><home><TAB><task><TAB><here|elsewhere><TAB><evidence>     exit 0
#   unknown<TAB><candidate homes, comma-separated, or -><TAB><here|elsewhere><TAB><evidence>   exit 3
# where here means this home is one of the candidates.
#   fleet_list<TAB><absent or stale description>     (only when absent or stale)
# <home> is the fleet list's self name for this home, or `.` without a list.
# Exit 2 on bad usage, a URL that is not a GitHub pull request, or an unreadable
# backlog, archive or fleet list.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/. With FM_TEST_SEAM=1, FM_PR_OWNER_GH replaces gh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-blocked-by-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-blocked-by-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage_error() { printf 'fm-pr-owner: %s\n' "$*" >&2; exit 2; }

url='' branch='' branch_given=0 task_given=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch) [ "$#" -ge 2 ] || usage_error "--branch needs a value"; branch=$2; branch_given=1; shift 2 ;;
    --task) [ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "--task needs a value"; task_given=$2; branch_given=1; shift 2 ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    -*) usage_error "unknown option $1" ;;
    *) [ -z "$url" ] || usage_error "one pull request URL only"; url=$1; shift ;;
  esac
done
[ -n "$url" ] || usage_error "usage: fm-pr-owner.sh <pull-request-url> [--branch <head-branch> | --task <task-id>]"
fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || usage_error "not a GitHub pull request URL: $url"

if [ "$branch_given" = 0 ]; then
  gh=gh
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then gh=${FM_PR_OWNER_GH:-gh}; fi
  branch=$("$gh" pr view "$url" --json headRefName --jq .headRefName 2>/dev/null) || branch=
fi
task=$task_given
if [ -n "$task" ]; then
  [ -z "$branch" ] || usage_error "--branch and --task are alternatives"
  src="task $task"
else
  case "$branch" in
    fm/?*) task=${branch#fm/} ;;
  esac
  src="branch $branch"
  [ -n "$branch" ] || src=''
fi

rows=$(fm_blocked_by_fleet_rows "$DATA") || exit 2
fleet=$(fm_blocked_by_fleet_file "$DATA")
self=. note=''
if [ -f "$fleet" ]; then
  header=$(fm_blocked_by_fleet_header "$fleet") || exit 2
  IFS=$'\t' read -r self gen homes fresh <<<"$header"
  [ "$fresh" = 1 ] || note="fleet list stale: generated $(fm_blocked_by_iso "$gen") (age $(( ($(date +%s) - gen) / 3600 ))h), covers $homes; an owner in another home may be missing"
else
  note="fleet list absent: the owner is decided from this home's rows only, so an owner in another home is not seen"
fi

printf '%s\n' "$rows" | awk -F '\t' -v want="$url" -v task="$task" -v src="$src" -v self="$self" '
  function norm(u,   n, base, num) {
    n = index(u, "/pull/"); if (!n) return ""
    base = tolower(substr(u, 1, n - 1)); num = substr(u, n + 6)
    sub(/^0+/, "", num); sub(/^https?:\/\//, "", base)
    return base "/pull/" num
  }
  function add(list, item) { return index("," list ",", "," item ",") ? list : (list == "" ? item : list "," item) }
  BEGIN { target = norm(want) }
  NF >= 3 {
    home = $1; id = $2; cites = 0
    m = split($4, u, ",")
    for (i = 1; i <= m; i++) if (u[i] != "-" && norm(u[i]) == target) cites = 1
    if (task != "" && id == task) { named = add(named, home); if (cites) namedcite = add(namedcite, home) }
    if (cites) { citing = add(citing, home SUBSEP id); citehomes = add(citehomes, home) }
  }
  function shown(why) {
    if (self == ".") { gsub(/ in \./, " in this home", why); gsub(/only \.:/, "only this home:", why); gsub(/only \.\047s/, "only this home\047s", why) }
    return why
  }
  function known(h, t, why) { why = shown(why); print "known\t" h "\t" t "\t" (h == self ? "here" : "elsewhere") "\t" why; st = 0 }
  function unknown(c, why) { why = shown(why); print "unknown\t" (c == "" ? "-" : c) "\t" (index("," c ",", "," self ",") ? "here" : "elsewhere") "\t" why; st = 3 }
  END {
    if (named != "") {
      n = split(named, nh, ","); k = (namedcite == "" ? 0 : split(namedcite, ch, ","))
      if (n == 1) known(named, task, src " names a row only in " named)
      else if (k == 1) known(namedcite, task, src " names rows in " named "; only " namedcite "\047s cites the pull request")
      else unknown(named, src " names rows in " named " and " k " of them cite the pull request")
      exit st
    }
    lead = (task == "" ? (src == "" ? "head branch unknown" : src " names no task") : "no row is named " task)
    n = (citing == "" ? 0 : split(citing, cp, ","))
    if (n == 0) unknown("", lead " and no row cites the pull request")
    else if (n == 1) { split(cp[1], hp, SUBSEP); known(hp[1], hp[2], lead "; only " hp[1] ":" hp[2] " cites the pull request") }
    else unknown(citehomes, lead "; " n " tasks in " citehomes " cite the pull request")
    exit st
  }'
status=$?
[ -z "$note" ] || printf 'fleet_list\t%s\n' "$note"
exit "$status"
