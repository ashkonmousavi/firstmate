#!/usr/bin/env bash
# fm-curated-delivery-check.sh - report fork work that never reached the homes.
#
# Usage:
#   fm-curated-delivery-check.sh [--list]
#   fm-curated-delivery-check.sh --help
#
# Silent when everything is delivered. Otherwise prints one `curated-delivery:`
# line that names what is missing, so the line is a usable watcher check
# result; --list adds one detail line per finding after it. Exit status is 0
# either way (a finding is output, not a failure); a usage error exits 2.
#
# Three kinds of finding:
#   * a merged fork PR (base main or curated) whose merge commit is not an
#     ancestor of origin/curated and has no equivalent re-landing. A re-landing
#     is either a curated commit that records the merge commit in a
#     `cherry picked from commit <sha>` trailer, or an exception entry below
#     whose re-landing PR is itself merged onto curated.
#   * an OPEN fork PR whose base is main and that lacks the label
#     FM_CURATED_BASE_OK_LABEL (default base-main-ok).
#   * per home, curated commits missing from that home's code-root HEAD.
#
# Exceptions: <FM_HOME>/config/curated-delivery-exceptions (FM_CURATED_EXCEPTIONS
# overrides the path), one entry per line, `#` comments allowed:
#   <original-pr> <relanding-pr> <evidence text...>
# An entry without evidence text, or whose re-landing PR is not on curated,
# is ignored, so the original is still listed. A re-landing written
# `base:<sha>` names a commit on curated that is not a fork PR, such as the
# upstream base curated was cut from; it qualifies when <sha> is an ancestor of
# curated.
#
# Baseline: PRs merged before curated was cut cannot be delivered by the check.
# `since <pr> <evidence text...>` in the exceptions file (or FM_CURATED_SINCE_PR)
# ignores merged PRs numbered below <pr>; evidence is required for the file form.
#
# Homes: the built-in fleet list, or FM_CURATED_HOMES_FILE (one
# `label|code-root|ssh-host` per line, ssh-host empty for a local path).
#
# Environment: FM_CURATED_REPO (default ashkonmousavi/firstmate),
# FM_CURATED_REF (default origin/curated), FM_CURATED_CODE (the git checkout
# the PR ancestry is read from; default this script's checkout),
# FM_CHECK_TIMEOUT (default 30; every gh, git fetch and ssh call is bounded
# inside it, and a call that cannot finish is reported, never waited on),
# FM_CURATED_GH (default gh).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

LIST=0
case "${1:-}" in
  "") ;;
  --list) LIST=1 ;;
  --help | -h) usage; exit 0 ;;
  *) echo "usage: fm-curated-delivery-check.sh [--list]" >&2; exit 2 ;;
esac

REPO=${FM_CURATED_REPO:-ashkonmousavi/firstmate}
REF=${FM_CURATED_REF:-origin/curated}
CODE=${FM_CURATED_CODE:-$FM_ROOT}
GH=${FM_CURATED_GH:-gh}
LABEL=${FM_CURATED_BASE_OK_LABEL:-base-main-ok}
EXCEPTIONS=${FM_CURATED_EXCEPTIONS:-$FM_HOME/config/curated-delivery-exceptions}
TOTAL=${FM_CHECK_TIMEOUT:-30}
case "$TOTAL" in '' | *[!0-9]*) TOTAL=30 ;; esac
SINCE=${FM_CURATED_SINCE_PR:-}
if [ -z "$SINCE" ] && [ -f "$EXCEPTIONS" ]; then
  SINCE=$(awk '$1=="since" && $2 ~ /^[0-9]+$/ && NF>=3 {print $2; exit}' "$EXCEPTIONS")
fi
case "$SINCE" in '' | *[!0-9]*) SINCE=0 ;; esac
START=$SECONDS
DEADLINE=$((START + TOTAL - 3))
[ "$DEADLINE" -gt "$START" ] || DEADLINE=$((START + 1))

FINDINGS=$(mktemp -d "${TMPDIR:-/tmp}/fm-curated-delivery.XXXXXX") || exit 0
trap 'rm -rf -- "$FINDINGS"' EXIT
: > "$FINDINGS/incomplete"
: > "$FINDINGS/prs"
: > "$FINDINGS/open"

# bounded <max-seconds> <cmd...>: run with the smaller of max and what is left
# of the overall budget. 124 when no budget is left or the bound is hit.
bounded() {
  local max=$1 left
  shift
  left=$((DEADLINE - SECONDS))
  [ "$left" -ge 1 ] || return 124
  [ "$left" -lt "$max" ] && max=$left
  fm_run_timed "$max" "$@"
}

incomplete() { printf '%s\n' "$1" >> "$FINDINGS/incomplete"; }

default_homes() {
  cat <<'EOF'
pc-main|/home/tegris/Firstmate/firstmate|
fleet-ops|/home/tegris/.treehouse/firstmate-8bf1b0/1/firstmate|
eel-web|/home/tegris/.treehouse/firstmate-8bf1b0/12/firstmate|
q-server|~/firstmate-stock|q-crew
q-zenbook|~/firstmate-stock|zb-crew
EOF
}

# ---- curated tip and ancestry ------------------------------------------------
TIP=
if bounded 8 git -C "$CODE" fetch --quiet origin >/dev/null 2>&1; then
  TIP=$(git -C "$CODE" rev-parse --verify --quiet "$REF^{commit}" 2>/dev/null) || TIP=
  [ -n "$TIP" ] || incomplete "cannot read $REF in $CODE"
else
  incomplete "cannot refresh $REF in $CODE"
fi

# ---- merged and open PRs -----------------------------------------------------
pr_json() {  # <state> <base>
  local state=$1 base=$2 fields out
  case "$state" in
    merged) state=MERGED; fields='number mergeCommit { oid } title url' ;;
    open) state=OPEN; fields='number labels(first: 100) { nodes { name } } title url' ;;
  esac
  out=$(bounded 12 "$GH" api graphql --paginate \
    -F owner="${REPO%/*}" -F name="${REPO#*/}" -F base="$base" \
    -f query="query(\$owner: String!, \$name: String!, \$base: String!, \$endCursor: String) {
      repository(owner: \$owner, name: \$name) {
        pullRequests(first: 100, after: \$endCursor, states: [$state], baseRefName: \$base) {
          nodes { $fields }
          pageInfo { hasNextPage endCursor }
        }
      }
    }") || return 1
  printf '%s' "$out" | jq -se '
    if length > 0 and all(.[]; .errors == null and
      (.data.repository.pullRequests.nodes | type) == "array") and
      (.[-1].data.repository.pullRequests.pageInfo.hasNextPage == false)
    then [.[].data.repository.pullRequests.nodes[] |
      if has("labels") then .labels = .labels.nodes else . end]
    else error("incomplete PR pagination") end'
}

# One tab-separated row per PR: number, merge commit (or empty), title, url.
# jq is the one parser; a gh failure is an incomplete result, not a clean one.
rows_merged() {
  local base out
  for base in main curated; do
    out=$(pr_json merged "$base") || {
      incomplete "gh merged PR list for $base failed"
      continue
    }
    printf '%s' "$out" | jq -r '.[] | [.number, (.mergeCommit.oid // ""), .title, .url] | @tsv' 2>/dev/null \
      || incomplete "gh merged PR list for $base is unreadable"
  done
}

exception_valid() {  # <orig> -> 0 when an evidenced entry's re-landing is on curated
  local orig=$1 line o r ev
  [ -f "$EXCEPTIONS" ] || return 1
  while IFS= read -r line; do
    case "$line" in '' | '#'*) continue ;; esac
    # shellcheck disable=SC2086
    set -- $line
    o=${1:-}
    r=${2:-}
    [ "$o" = "$orig" ] || continue
    shift 2 2>/dev/null || continue
    ev=$*
    [ -n "$ev" ] || continue
    case "$r" in
      base:*)
        # The carrier is a non-PR commit already on curated, such as the
        # upstream base curated was cut from.
        git -C "$CODE" merge-base --is-ancestor "${r#base:}" "$TIP" 2>/dev/null && return 0
        ;;
      *) grep -Fxq -- "$r" "$FINDINGS/curated-prs" 2>/dev/null && return 0 ;;
    esac
  done < "$EXCEPTIONS"
  return 1
}

if [ -n "$TIP" ]; then
  rows_merged > "$FINDINGS/merged.tsv"
  # PR numbers whose merge commit is on curated: the re-landing proof for exceptions.
  while IFS=$'\t' read -r num sha _; do
    [ -n "$sha" ] || continue
    if git -C "$CODE" merge-base --is-ancestor "$sha" "$TIP" 2>/dev/null; then
      printf '%s\n' "$num"
    fi
  done < "$FINDINGS/merged.tsv" > "$FINDINGS/curated-prs"
  # Commits recorded by cherry-pick -x trailers on curated.
  git -C "$CODE" log "$TIP" --format=%B 2>/dev/null \
    | sed -n 's/.*cherry picked from commit \([0-9a-f]\{40\}\).*/\1/p' \
    | sort -u > "$FINDINGS/picked"

  while IFS=$'\t' read -r num sha title url; do
    [ -n "$num" ] || continue
    [ "$num" -lt "$SINCE" ] && continue
    grep -Fxq -- "$num" "$FINDINGS/curated-prs" && continue
    [ -n "$sha" ] && grep -Fxq -- "$sha" "$FINDINGS/picked" && continue
    exception_valid "$num" && continue
    printf '%s\t%s\t%s\n' "$num" "$url" "$title"
  done < "$FINDINGS/merged.tsv" | sort -n -u > "$FINDINGS/prs"
fi

out=$(pr_json open main) || {
  incomplete "gh open PR list failed"
  out='[]'
}
printf '%s' "$out" \
  | jq -r --arg l "$LABEL" '.[] | select(([.labels[].name] | index($l)) | not) | [.number, .url, .title] | @tsv' 2>/dev/null \
  | sort -n > "$FINDINGS/open" || incomplete "gh open PR list is unreadable"

# ---- homes -------------------------------------------------------------------
check_home() {  # <label> <code-root> <ssh-host>
  local label=$1 root=$2 host=$3 rc n
  [ -n "$TIP" ] || return 0
  if [ -z "$host" ]; then
    if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
      echo "$label|home code root $root is not readable"
      return 0
    fi
    git -C "$root" cat-file -e "$TIP^{commit}" 2>/dev/null \
      || bounded 8 git -C "$root" fetch --quiet origin >/dev/null 2>&1 || true
    git -C "$root" merge-base --is-ancestor "$TIP" HEAD 2>/dev/null
    rc=$?
    if [ "$rc" -eq 0 ]; then
      return 0
    elif [ "$rc" -eq 1 ]; then
      n=$(git -C "$root" rev-list --count "HEAD..$TIP" 2>/dev/null || echo '?')
      echo "$label|HEAD lacks $n curated commit(s) (tip ${TIP:0:8})"
    else
      echo "$label|cannot compare HEAD with curated tip ${TIP:0:8} (commit unknown there)"
    fi
    return 0
  fi
  # Remote: one ssh call prints the verdict; the root keeps its ~ for the remote shell.
  # shellcheck disable=SC2016
  n=$(bounded 10 ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" \
    'cd '"$root"' 2>/dev/null || { echo nodir; exit 0; }
     git cat-file -e '"$TIP"'^{commit} 2>/dev/null || { echo unknown; exit 0; }
     if git merge-base --is-ancestor '"$TIP"' HEAD; then echo ok
     else echo behind "$(git rev-list --count HEAD..'"$TIP"')"; fi' 2>/dev/null) || n=unreachable
  case "$n" in
    ok) ;;
    "behind "*) echo "$label|HEAD lacks ${n#behind } curated commit(s) (tip ${TIP:0:8})" ;;
    nodir) echo "$label|code root $root is missing on $host" ;;
    unknown) echo "$label|HEAD cannot be compared: curated tip ${TIP:0:8} not fetched on $host" ;;
    *) echo "$label|cannot reach $host in time" ;;
  esac
}

if [ -n "${FM_CURATED_HOMES_FILE:-}" ] && [ -f "$FM_CURATED_HOMES_FILE" ]; then
  HOMES=$(cat "$FM_CURATED_HOMES_FILE")
else
  HOMES=$(default_homes)
fi
i=0
while IFS='|' read -r label root host; do
  case "$label" in '' | '#'*) continue ;; esac
  i=$((i + 1))
  # Homes run in parallel so slow ssh calls share one bound; results keep home order.
  ( check_home "$label" "$root" "$host" > "$FINDINGS/home.$i" 2>/dev/null ) &
done <<EOF
$HOMES
EOF
wait
: > "$FINDINGS/homes"
j=1
while [ "$j" -le "$i" ]; do
  cat "$FINDINGS/home.$j" >> "$FINDINGS/homes" 2>/dev/null
  j=$((j + 1))
done

# ---- report ------------------------------------------------------------------
nums() { cut -f1 "$1" | paste -sd' ' -; }
parts=
[ -s "$FINDINGS/prs" ] && parts="merged PRs not on curated: $(nums "$FINDINGS/prs")"
if [ -s "$FINDINGS/open" ]; then
  parts="${parts:+$parts; }open PRs to main without $LABEL: $(nums "$FINDINGS/open")"
fi
if [ -s "$FINDINGS/homes" ]; then
  parts="${parts:+$parts; }homes behind: $(cut -d'|' -f1 "$FINDINGS/homes" | paste -sd' ' -)"
fi
if [ -s "$FINDINGS/incomplete" ]; then
  parts="${parts:+$parts; }check incomplete: $(paste -sd',' "$FINDINGS/incomplete")"
fi
[ -n "$parts" ] || exit 0

fm_cap_line_var "curated-delivery: $parts" 400
printf '%s\n' "$FM_LINE_CAP_LINE"
if [ "$LIST" = 1 ]; then
  while IFS=$'\t' read -r num url title; do
    printf 'merged PR not on curated: #%s %s %s\n' "$num" "$title" "$url"
  done < "$FINDINGS/prs" 2>/dev/null
  while IFS=$'\t' read -r num url title; do
    printf 'open PR targets main without %s: #%s %s %s\n' "$LABEL" "$num" "$title" "$url"
  done < "$FINDINGS/open" 2>/dev/null
  while IFS='|' read -r label msg; do
    printf 'home %s: %s\n' "$label" "$msg"
  done < "$FINDINGS/homes"
  while IFS= read -r msg; do
    printf 'incomplete: %s\n' "$msg"
  done < "$FINDINGS/incomplete"
fi
exit 0
