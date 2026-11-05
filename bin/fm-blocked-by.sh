#!/usr/bin/env bash
# fm-blocked-by.sh - show and record whether this home's blocked-by edges still block.
#
# Usage:
#   fm-blocked-by.sh verdicts
#   fm-blocked-by.sh mark <row-id> <target> --pr <pull-request-url>
#   fm-blocked-by.sh unmark <row-id> <target>
#
# verdicts prints bin/fm-blocked-by-lib.sh's verdict for every blocked-by edge
# in this home's backlog (TSV: row, closed, target, verdict, evidence).
# The library header owns the rule.
#
# mark records that <target> no longer blocks <row-id> because the pull request
# that delivered it merged. It reads the pull request once with
# `gh pr view <url> --json state,url,headRefName,mergedAt` and refuses unless it
# is MERGED; it also refuses when <row-id> has no such blocked-by edge, when the
# edge names another home (a qualifier matching the fleet list self is local),
# and when <target> has a visible open row (an open row still blocks whatever a
# mark says). It appends one line to the ledger and
# changes nothing else; a repeated mark is a no-op.
# unmark appends the reversing line, so the edge reads as it did before the mark.
# Use mark for a blocker whose only trace is its merged pull request (no done
# row in this home's backlog or archive); a done or archived row already
# satisfies the edge without one under the library header's fleet-list rule.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/. Exit 0 on success, 1 on a refusal, 2 on a usage error or an
# unreadable backlog, archive, or ledger.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-blocked-by-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-blocked-by-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() { printf 'fm-blocked-by: %s\n' "$*" >&2; exit "${2:-1}"; }
usage_error() { printf 'fm-blocked-by: %s\n' "$*" >&2; exit 2; }

verdicts() {
  local out
  out=$(fm_blocked_by_verdicts "$DATA") || exit 2
  [ -z "$out" ] || printf '%s\n' "$out"
}

edge_verdict() {  # <row> <target>
  fm_blocked_by_verdicts "$DATA" | awk -F '\t' -v r="$1" -v t="$2" '$1 == r && $3 == t { print $4; exit }'
}

last_entry() {  # <ledger> <row> <target>: "<mark|unmark><TAB><url|->" of the newest line for that edge
  awk -F '\t' -v r="$2" -v t="$3" '$3 == r && $4 == t { last = $1 "\t" $5 } END { print last }' "$1"
}

mark() {
  local row=$1 target=$2 url=$3 current gh json state merged_url ledger fleet header self
  case "$url" in
    https://*/pull/[0-9]*) ;;
    *) usage_error "--pr wants a pull request URL, got '$url'" ;;
  esac
  case "$target" in
    *:*)
      fleet=$(fm_blocked_by_fleet_file "$DATA")
      [ -f "$fleet" ] || die "$row: the qualifier in $target cannot be resolved without a fleet list"
      header=$(fm_blocked_by_fleet_header "$fleet") || exit 2
      self=${header%%$'\t'*}
      [ "${target%%:*}" = "$self" ] || die "$row: the edge $target names another home; a mark here cannot satisfy it"
      ;;
  esac
  current=$(edge_verdict "$row" "$target") || exit 2
  case "$current" in
    '') die "$row has no blocked-by: $target edge in $DATA/backlog.md" ;;
    blocked) die "$target has a visible open row; it still blocks $row" ;;
  esac
  ledger=$(fm_blocked_by_marks_file "$DATA")
  if [ -f "$ledger" ] && [ "$(last_entry "$ledger" "$row" "$target")" = "mark"$'\t'"$url" ]; then
    printf 'already marked: %s blocked-by %s satisfied by %s\n' "$row" "$target" "$url"
    return 0
  fi
  gh=gh
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then gh=${FM_BLOCKED_BY_GH:-gh}; fi
  json=$("$gh" pr view "$url" --json state,url,headRefName,mergedAt 2>/dev/null) \
    || die "cannot read $url; nothing recorded"
  state=$(printf '%s' "$json" | jq -r '.state // empty' 2>/dev/null) || state=
  merged_url=$(printf '%s' "$json" | jq -r '.url // empty' 2>/dev/null) || merged_url=
  [ "$state" = MERGED ] || die "$url is ${state:-unreadable}, not merged; nothing recorded"
  [ -n "$merged_url" ] || merged_url=$url
  printf 'mark\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$row" "$target" "$merged_url" >>"$ledger" \
    || die "cannot write $ledger" 2
  printf 'marked: %s blocked-by %s satisfied by %s\n' "$row" "$target" "$merged_url"
}

unmark() {
  local row=$1 target=$2 ledger last
  ledger=$(fm_blocked_by_marks_file "$DATA")
  last=
  [ ! -f "$ledger" ] || last=$(last_entry "$ledger" "$row" "$target")
  [ "${last%%$'\t'*}" = mark ] || die "$row blocked-by $target has no standing mark"
  printf 'unmark\t%s\t%s\t%s\t-\n' "$(date +%s)" "$row" "$target" >>"$ledger" || die "cannot write $ledger" 2
  printf 'unmarked: %s blocked-by %s\n' "$row" "$target"
}

case "${1:-}" in
  -h|--help) usage ;;
  verdicts)
    [ $# -eq 1 ] || usage_error "verdicts takes no arguments"
    verdicts
    ;;
  mark)
    [ $# -eq 5 ] && [ "$4" = --pr ] || usage_error "usage: fm-blocked-by.sh mark <row-id> <target> --pr <url>"
    fm_blocked_by_readable "$(fm_blocked_by_marks_file "$DATA")" "mark ledger" || exit 2
    mark "$2" "$3" "$5"
    ;;
  unmark)
    [ $# -eq 3 ] || usage_error "usage: fm-blocked-by.sh unmark <row-id> <target>"
    unmark "$2" "$3"
    ;;
  *) usage_error "usage: fm-blocked-by.sh verdicts|mark|unmark (see --help)" ;;
esac
