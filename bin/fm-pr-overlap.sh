#!/usr/bin/env bash
# Read-only note of open pull requests that touch a brief's planned paths.
# Usage: fm-pr-overlap.sh --project <dir> --brief <path>
# bin/fm-spawn.sh runs this after the brief is filled and before it renders
# the launch brief. The brief's ## SCOPE section is one relative path per
# line. This writes or replaces a ## SHARED block naming each open pull
# request whose merge into the project's HEAD changes one of those paths.
# git merge-tree supplies that file list when the pull request head is a
# local commit. When merge-tree cannot run, the pull request's own file list
# is used instead. FILES and BLAST RADIUS path lines supply paths when SCOPE
# is absent. A brief without planned paths receives an unchecked note.
# Listing failures, a missing tool, and a brief that cannot be rewritten are
# recorded in the note or skipped. This script exits 0 either way, so a spawn
# is never blocked on it.
set -u

overlap_fail_note() {
  printf '%s\n' \
    '<!-- fm-pr-overlap:start -->' \
    '## SHARED' \
    'The overlap check could not list open pull requests, so none are named here.' \
    '<!-- fm-pr-overlap:end -->'
}

overlap_scope_paths() {  # <brief>
  awk '
    function paths(text,    count, lines, row, n, parts, i, path) {
      count = split(text, lines, "\n")
      for (row = 1; row <= count; row++) {
        gsub(/[`*]/, "", lines[row])
        sub(/^[[:space:]]*[-+][[:space:]]+/, "", lines[row])
        sub(/^[[:space:]]+/, "", lines[row])
        sub(/[[:space:]]+$/, "", lines[row])
        n = split(lines[row], parts, /[[:space:],]+/)
        for (i = 1; i <= n; i++) {
          path = parts[i]
          if (path == "" || path ~ /^[-\/]/ || path ~ /:/ || path ~ /[{}<>]/) continue
          if ((n > 1 && path !~ /[.\/]/) || path ~ /(^|\/)\.\.?(\/|$)/) continue
          print path
        }
      }
    }
    /^## SCOPE[[:space:]]*$/ { scope=1; have_scope=1; next }
    /^#/ { scope=0 }
    scope { scope_text = scope_text $0 "\n"; next }
    {
      line=$0
      gsub(/[`*]/, "", line)
      sub(/^[#[:space:]-]+/, "", line)
      if (line ~ /^(FILES|BLAST RADIUS)(:|[[:space:]]*$)/) {
        fallback=1
        sub(/^(FILES|BLAST RADIUS):?[[:space:]]*/, "", line)
        fallback_text = fallback_text line "\n"
        next
      }
      if ($0 ~ /^#/ || line ~ /^[A-Z][A-Z _-]*:/) fallback=0
      if (fallback) fallback_text = fallback_text line "\n"
    }
    END { paths(have_scope ? scope_text : fallback_text) }
  ' "$1"
}

# Drop any previous note, then insert the new one immediately after the
# SCOPE section so the worker reads the paths and the overlap together.
overlap_rewrite_brief() {  # <brief> <note>
  local brief=$1 note=$2 tmp line in_block=0 in_scope=0 inserted=0
  tmp=$(mktemp "$(dirname "$brief")/.fm-pr-overlap.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = '<!-- fm-pr-overlap:start -->' ]; then
      in_block=1
      continue
    fi
    if [ "$line" = '<!-- fm-pr-overlap:end -->' ]; then
      in_block=0
      continue
    fi
    [ "$in_block" -eq 0 ] || continue
    if [ "$inserted" -eq 0 ] && [ "$in_scope" -eq 1 ]; then
      case "$line" in
        '## '*|'# '*)
          printf '%s\n' "$note" >> "$tmp"
          inserted=1
          ;;
      esac
    fi
    printf '%s\n' "$line" >> "$tmp"
    case "$line" in
      '## SCOPE') in_scope=1 ;;
    esac
  done < "$brief"
  if [ "$inserted" -eq 0 ]; then
    printf '%s\n' "$note" >> "$tmp"
    inserted=1
  fi
  mv -f -- "$tmp" "$brief"
}

overlap_merge_tree_files() {  # <project> <base> <head>
  local project=$1 base=$2 head=$3 raw tree
  git -C "$project" cat-file -e "${head}^{commit}" 2>/dev/null || return 1
  raw=$(git -C "$project" merge-tree --write-tree --name-only "$base" "$head" 2>/dev/null) || true
  tree=$(printf '%s\n' "$raw" | head -n 1)
  case "$tree" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) return 1 ;;
  esac
  git -C "$project" cat-file -e "${tree}^{tree}" 2>/dev/null || return 1
  git -C "$project" diff --no-renames --name-only "$base" "$tree" 2>/dev/null || return 1
  printf '%s\n' "$raw" | tail -n +2
}

overlap_pr_file_list() {  # <project> <number>
  local project=$1 number=$2
  ( cd "$project" && gh api "repos/{owner}/{repo}/pulls/$number/files" --paginate \
    --jq '.[] | .filename, (.previous_filename // empty)' )
}

overlap_hits() {  # <scope-text> <changed-text>
  local scope=$1 changed=$2 path
  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    printf '%s\n' "$changed" | grep -Fxq -- "$path" || continue
    printf '%s\n' "$path"
  done <<EOF
$scope
EOF
}

overlap_join() {
  local out='' first=1 part
  while IFS= read -r part || [ -n "$part" ]; do
    [ -n "$part" ] || continue
    if [ "$first" -eq 1 ]; then
      out=$part
      first=0
    else
      out="$out, $part"
    fi
  done
  printf '%s' "$out"
}

overlap_main() {
  local project='' brief='' note='' scope='' base='' json='' number='' url='' head=''
  local changed='' hits='' hit_text='' lines='' compared=0 unchecked='' rows=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project)
        [ "$#" -ge 2 ] || return 0
        project=$2
        shift 2
        ;;
      --brief)
        [ "$#" -ge 2 ] || return 0
        brief=$2
        shift 2
        ;;
      *) shift ;;
    esac
  done
  [ -n "$project" ] && [ -n "$brief" ] && [ -f "$brief" ] || return 0
  scope=$(overlap_scope_paths "$brief")
  if [ -z "$scope" ]; then
    overlap_rewrite_brief "$brief" "$(printf '%s\n' \
      '<!-- fm-pr-overlap:start -->' \
      '## SHARED' \
      'Overlap was not checked: no planned paths found in SCOPE, FILES, or BLAST RADIUS.' \
      '<!-- fm-pr-overlap:end -->')" || true
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 \
    || ! git -C "$project" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    overlap_rewrite_brief "$brief" "$(overlap_fail_note)" || true
    return 0
  fi
  base=$(git -C "$project" rev-parse HEAD 2>/dev/null) || {
    overlap_rewrite_brief "$brief" "$(overlap_fail_note)" || true
    return 0
  }
  json=$(cd "$project" && gh pr list --state open --json number,url,headRefOid --limit 200 2>/dev/null) || {
    overlap_rewrite_brief "$brief" "$(overlap_fail_note)" || true
    return 0
  }
  rows=$(printf '%s\n' "$json" | jq -er '
    if type == "array" and all(.[];
      (.number | type == "number" and . > 0 and . == floor)
      and (.url | type == "string" and test("^https://[^\\s]+$"))
      and (.headRefOid == null or (.headRefOid | type == "string")))
    then sort_by(.number) | map([(.number | tostring), .url, (.headRefOid // "")] | @tsv) | join("\n")
    else error("invalid pull request list") end' 2>/dev/null) || {
      overlap_rewrite_brief "$brief" "$(overlap_fail_note)" || true
      return 0
    }
  lines=
  while IFS=$(printf '\t') read -r -u 3 number url head || [ -n "${number:-}" ]; do
    [ -n "$number" ] || continue
    if ! changed=$(overlap_merge_tree_files "$project" "$base" "$head" 2>/dev/null); then
      if ! changed=$(overlap_pr_file_list "$project" "$number" 2>/dev/null); then
        unchecked="${unchecked}
- ${url} (unchecked: could not read changed files)"
        continue
      fi
    fi
    compared=$((compared + 1))
    hits=$(overlap_hits "$scope" "$changed") || hits=
    [ -n "$hits" ] || continue
    hit_text=$(printf '%s\n' "$hits" | overlap_join)
    lines="${lines}
- ${url} (${hit_text})"
  done 3<<EOF
$rows
EOF
  if [ -n "$lines" ]; then
    note=$(printf '%s\n' \
      '<!-- fm-pr-overlap:start -->' \
      '## SHARED' \
      'Open pull requests touching the planned files:' \
      "${lines#?}" \
      '<!-- fm-pr-overlap:end -->')
  else
    note=$(printf '%s\n' \
      '<!-- fm-pr-overlap:start -->' \
      '## SHARED' \
      "No overlap found among $compared compared open pull requests." \
      '<!-- fm-pr-overlap:end -->')
  fi
  if [ -n "$unchecked" ]; then
    note=${note%$'\n<!-- fm-pr-overlap:end -->'}
    note=$(printf '%s\n' "$note" 'Unchecked open pull requests:' "${unchecked#?}" \
      '<!-- fm-pr-overlap:end -->')
  fi
  overlap_rewrite_brief "$brief" "$note" || true
}

overlap_main "$@" || true
exit 0
