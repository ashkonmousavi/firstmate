#!/usr/bin/env bash
# fm-curated-delivery-check.sh - report fork work that never reached the homes.
#
# Usage:
#   fm-curated-delivery-check.sh [--list]
#   fm-curated-delivery-check.sh --help
#
# Silent when there are no findings or incomplete checks. Otherwise prints one `curated-delivery:`
# line that names what is missing, so the line is a usable watcher check
# result; --list adds one detail line per finding after it. Exit status is 0
# either way (a finding is output, not a failure); a usage error exits 2.
#
# Three kinds of finding:
#   * a merged fork PR (base main or curated) whose merge commit is not an
#     ancestor of origin/curated and has no equivalent re-landing. A re-landing
#     is either a curated commit that records the merge commit in a
#     `cherry picked from commit <sha>` trailer, or an exception entry below
#     whose merged re-landing commit is an ancestor of curated.
#   * an OPEN fork PR whose base is main and that lacks the label
#     FM_CURATED_BASE_OK_LABEL (default base-main-ok).
#   * per home, merged PRs and curated commits missing from its code-root HEAD.
#
# Exceptions: <FM_HOME>/config/curated-delivery-exceptions (FM_CURATED_EXCEPTIONS
# overrides the path), one entry per line, `#` comments allowed:
#   <original-pr> <relanding-pr> <evidence text...>
# An entry without evidence text, or whose merged re-landing commit is not on curated,
# is ignored, so the original is still listed. A re-landing written
# `base:<sha>` names a commit on curated that is not a fork PR, such as the
# upstream base curated was cut from; it qualifies when <sha> is an ancestor of
# curated.
#
# Homes: FM_CURATED_HOMES_FILE or <FM_HOME>/config/curated-delivery-homes,
# one `label|code-root|ssh-host` per line, ssh-host empty for a local path.
# Repository: FM_CURATED_REPO or <FM_HOME>/config/curated-delivery-repo,
# containing the GitHub owner/repository. Missing configuration is incomplete.
#
# Environment: FM_CURATED_REPO,
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

REPO=${FM_CURATED_REPO:-}
if [ -z "$REPO" ] && [ -f "$FM_HOME/config/curated-delivery-repo" ]; then
  REPO=$(cat "$FM_HOME/config/curated-delivery-repo")
fi
HOMES_FILE=${FM_CURATED_HOMES_FILE:-$FM_HOME/config/curated-delivery-homes}
REF=${FM_CURATED_REF:-origin/curated}
CODE=${FM_CURATED_CODE:-$FM_ROOT}
GH=${FM_CURATED_GH:-gh}
LABEL=${FM_CURATED_BASE_OK_LABEL:-base-main-ok}
EXCEPTIONS=${FM_CURATED_EXCEPTIONS:-$FM_HOME/config/curated-delivery-exceptions}
TOTAL=${FM_CHECK_TIMEOUT:-30}
case "$TOTAL" in '' | *[!0-9]*) TOTAL=30 ;; esac
START=$SECONDS
DEADLINE=$((START + TOTAL - 3))
[ "$DEADLINE" -gt "$START" ] || DEADLINE=$((START + 1))

FINDINGS=$(mktemp -d "${TMPDIR:-/tmp}/fm-curated-delivery.XXXXXX") || exit 0
trap 'rm -rf -- "$FINDINGS"' EXIT
: > "$FINDINGS/incomplete"
: > "$FINDINGS/prs"
: > "$FINDINGS/open"
: > "$FINDINGS/proofs"

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

[ -n "$REPO" ] || incomplete "repository is not configured (FM_CURATED_REPO or config/curated-delivery-repo)"

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

delivery_commits() {
  local orig=$1 sha=$2 line o r carrier
  [ -z "$sha" ] || printf '%s\n' "$sha"
  if [ -n "$sha" ]; then
    awk -F '\t' -v sha="$sha" '$1==sha {print $2}' "$FINDINGS/picked"
  fi
  [ -f "$EXCEPTIONS" ] || return 0
  while IFS= read -r line; do
    case "$line" in '' | '#'*) continue ;; esac
    read -r o r carrier <<< "$line"
    [ "$o" = "$orig" ] && [ -n "$carrier" ] || continue
    case "$r" in
      base:*) carrier=${r#base:} ;;
      *) carrier=$(awk -F '\t' -v pr="$r" '$1==pr {print $2}' "$FINDINGS/merged.tsv") ;;
    esac
    [ -n "$carrier" ] || continue
    git -C "$CODE" merge-base --is-ancestor "$carrier" "$TIP" 2>/dev/null && printf '%s\n' "$carrier"
  done < "$EXCEPTIONS"
  return 0
}

delivered_to() {
  local root=$1 target=$2 proofs=$3 carrier
  for carrier in $proofs; do
    git -C "$root" merge-base --is-ancestor "$carrier" "$target" 2>/dev/null && return 0
  done
  return 1
}

if [ -n "$TIP" ] && [ -n "$REPO" ]; then
  rows_merged | sort -n -u > "$FINDINGS/merged.tsv"
  git -C "$CODE" log "$TIP" --format='%H%x00%B%x00' 2>/dev/null | jq -Rrs '
    split("\u0000") as $parts |
    range(0; ($parts | length) - 1; 2) as $i |
    ($parts[$i] | gsub("^\\s+|\\s+$"; "")) as $carrier |
    $parts[$i+1] | scan("cherry picked from commit ([0-9a-f]{40})") |
    [.[0], $carrier] | @tsv' > "$FINDINGS/picked"
  while IFS=$'\t' read -r num sha title url; do
    [ -n "$num" ] || continue
    proofs=$(delivery_commits "$num" "$sha" | sort -u | paste -sd' ' -)
    printf '%s|%s\n' "$num" "$proofs" >> "$FINDINGS/proofs"
    delivered_to "$CODE" "$TIP" "$proofs" && continue
    printf '%s\t%s\t%s\n' "$num" "$url" "$title" >> "$FINDINGS/prs"
  done < "$FINDINGS/merged.tsv"
fi

if [ -n "$REPO" ]; then
  out=$(pr_json open main) || {
    incomplete "gh open PR list failed"
    out='[]'
  }
  printf '%s' "$out" \
    | jq -r --arg l "$LABEL" '.[] | select(([.labels[].name] | index($l)) | not) | [.number, .url, .title] | @tsv' 2>/dev/null \
    | sort -n > "$FINDINGS/open" || incomplete "gh open PR list is unreadable"
fi

# ---- homes -------------------------------------------------------------------
home_comparison() {
  local root=$1 tip=$2 rc n num proofs missing=
  case "$root" in \~/*) root="$HOME/${root#\~/}" ;; esac
  if ! git -C "$root" rev-parse --verify HEAD >/dev/null 2>&1; then
    printf 'home code root %s is not readable\n' "$root"
    return 0
  fi
  git -C "$root" merge-base --is-ancestor "$tip" HEAD 2>/dev/null
  rc=$?
  if [ "$rc" -eq 1 ]; then
    n=$(git -C "$root" rev-list --count "HEAD..$tip" 2>/dev/null) || n='?'
    printf 'HEAD lacks %s curated commit(s) (tip %.8s)\n' "$n" "$tip"
  elif [ "$rc" -ne 0 ]; then
    printf 'cannot compare HEAD with curated tip %.8s (commit unknown there)\n' "$tip"
  fi
  while IFS='|' read -r num proofs; do
    [ -n "$num" ] || continue
    delivered_to "$root" HEAD "$proofs" && continue
    missing="${missing:+$missing }$num"
  done
  [ -z "$missing" ] || printf 'HEAD lacks merged PRs: %s\n' "$missing"
  return 0
}

check_home() {
  local label=$1 root=$2 host=$3 out quoted_root script quoted_script
  [ -n "$TIP" ] || return 0
  if [ -z "$host" ]; then
    git -C "$root" cat-file -e "$TIP^{commit}" 2>/dev/null \
      || bounded 8 git -C "$root" fetch --quiet origin >/dev/null 2>&1 || true
    out=$(home_comparison "$root" "$TIP" < "$FINDINGS/proofs")
  else
    printf -v quoted_root '%q' "$root"
    script=$(cat <<EOF
$(declare -f delivered_to)
$(declare -f home_comparison)
home_comparison $quoted_root '$TIP' <<'FM_DELIVERY_PROOFS'
$(cat "$FINDINGS/proofs")
FM_DELIVERY_PROOFS
EOF
    )
    quoted_script=$(printf '%s' "$script" | sed "s/'/'\\\\''/g")
    out=$(bounded 10 ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" "bash -c '$quoted_script'") \
      || out="cannot reach $host in time"
  fi
  while IFS= read -r out; do
    [ -z "$out" ] || printf '%s|%s\n' "$label" "$out"
  done <<< "$out"
}

HOMES=
if [ -f "$HOMES_FILE" ] && [ -r "$HOMES_FILE" ]; then
  HOMES=$(cat "$HOMES_FILE")
else
  incomplete "cannot read homes configuration $HOMES_FILE"
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
  parts="${parts:+$parts; }homes behind: $(cut -d'|' -f1 "$FINDINGS/homes" | sort -u | paste -sd' ' -)"
fi
home_prs=$(awk -F '|' '$2 ~ /^HEAD lacks merged PRs:/ {sub(/^HEAD lacks merged PRs: /,"",$2); printf "%s%s=%s", sep,$1,$2;sep="; "}' "$FINDINGS/homes")
[ -z "$home_prs" ] || parts="${parts:+$parts; }missing home PRs: $home_prs"
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
