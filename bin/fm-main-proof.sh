#!/usr/bin/env bash
# Answer whether one named commit carries complete full proof: every named
# required check succeeded on that exact commit.
#
# Usage: fm-main-proof.sh <owner/repo> <commit-sha> <required-check>...
#
# The required checks are the project's full-proof legs, named by the caller
# from the project's own workflow definitions (AGENTS.md section 6 routes that
# workflow map into data/learnings.md). Each check is judged by its latest
# GitHub Actions run on the named commit, so a rerun that succeeded replaces
# an earlier failure and a later cancellation replaces an earlier success.
# A check that is missing,
# still running, cancelled, skipped, neutral, or failed leaves the commit
# unproven; a run on any other commit, including a newer main merge, never
# counts. The verdict therefore stays bound to the named commit: a newer commit
# needs its own complete proof.
#
# This answers proof only. Whether a scheduled daily audit ran, and whether the
# live deployment is healthy and serves which commit, are separate facts this
# script never reports.
#
# Output and exit status:
#   0  proved <sha>: <n> required checks succeeded on this commit
#   1  unproven <sha>: <check>=<state>, ...
#   2  unknown <sha>: check runs could not be read (or a malformed request)
set -eu

if [ "$#" -lt 3 ]; then
  echo "error: usage: fm-main-proof.sh <owner/repo> <commit-sha> <required-check>..." >&2
  exit 2
fi
REPO=$1
SHA=$2
shift 2
case "$REPO" in
  */*/*|/*|*/|*[!A-Za-z0-9._/-]*) echo "error: invalid repository '$REPO'" >&2; exit 2 ;;
  */*) ;;
  *) echo "error: invalid repository '$REPO'" >&2; exit 2 ;;
esac
case "$SHA" in
  *[!0-9a-f]*) echo "error: commit must be a full 40-character lowercase sha" >&2; exit 2 ;;
esac
[ "${#SHA}" -eq 40 ] || { echo "error: commit must be a full 40-character lowercase sha" >&2; exit 2; }

if ! runs=$(gh api --paginate "repos/$REPO/commits/$SHA/check-runs?per_page=100" \
  --jq '.check_runs[] | [.id, .name, .head_sha, .status, (.conclusion // "-"), (.app.slug // "-")] | @tsv'); then
  echo "unknown $SHA: check runs could not be read"
  exit 2
fi

missing=''
for check in "$@"; do
  # Latest GitHub Actions run of this exact name on this exact commit, by run id.
  latest=$(printf '%s\n' "$runs" | awk -F '\t' -v n="$check" -v s="$SHA" '
    $2 == n && $3 == s && $6 == "github-actions" && ($1 + 0) > best { best = $1 + 0; st = $4; co = $5 }
    END { if (best) print st, co }')
  if [ -z "$latest" ]; then
    state=missing
  else
    read -r status conclusion <<EOF
$latest
EOF
    if [ "$status" != completed ]; then
      state=$status
    else
      state=$conclusion
    fi
  fi
  [ "$state" = success ] || missing="${missing:+$missing, }$check=$state"
done

if [ -n "$missing" ]; then
  echo "unproven $SHA: $missing"
  exit 1
fi
echo "proved $SHA: $# required checks succeeded on this commit"
