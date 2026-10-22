#!/usr/bin/env bash
# Read-only note of open pull requests that touch a brief's planned paths.
# Usage: fm-pr-overlap.sh --project <dir> --brief <path>
# bin/fm-spawn.sh runs this after the brief is filled and before it renders
# the launch brief. The brief's ## SCOPE section is one relative path per
# line. This writes or replaces a ## SHARED block naming each open pull
# request whose merge into the project's HEAD changes one of those paths.
# git merge-tree supplies that file list when the pull request head is a
# local commit. When merge-tree cannot run, the pull request's own file list
# is used instead. A missing SCOPE section leaves the brief unchanged.
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
  local brief=$1 line in_scope=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '## SCOPE') in_scope=1; continue ;;
      '## '*|'# '*)
        [ "$in_scope" -eq 1 ] && break
        continue
        ;;
    esac
    [ "$in_scope" -eq 1 ] || continue
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      /*|-*|*' '*) continue ;;
    esac
    case "/$line/" in
      */../*|*/./*) continue ;;
    esac
    printf '%s\n' "$line"
  done < "$brief"
}

overlap_has_scope_heading() {  # <brief>
  grep -qxF '## SCOPE' "$1"
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
  if [ "$inserted" -eq 0 ] && grep -qxF '## SCOPE' "$tmp"; then
    printf '%s\n' "$note" >> "$tmp"
    inserted=1
  fi
  if [ "$inserted" -eq 0 ]; then
    rm -f -- "$tmp"
    return 1
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
  git -C "$project" diff --name-only "$base" "$tree" 2>/dev/null || true
  printf '%s\n' "$raw" | tail -n +2
}

overlap_pr_file_list() {  # <project> <number>
  local project=$1 number=$2
  ( cd "$project" && gh pr diff "$number" --name-only )
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
  local changed='' hits='' hit_text='' lines='' listed=0
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
  overlap_has_scope_heading "$brief" || return 0
  scope=$(overlap_scope_paths "$brief")
  if [ -z "$scope" ]; then
    # A heading with no usable paths should not keep a stale note.
    if grep -qF '<!-- fm-pr-overlap:start -->' "$brief"; then
      overlap_rewrite_brief "$brief" "$(printf '%s\n' \
        '<!-- fm-pr-overlap:start -->' \
        '## SHARED' \
        'No planned paths were declared, so no open pull request was compared.' \
        '<!-- fm-pr-overlap:end -->')" || true
    fi
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
  lines=
  while IFS=$(printf '\t') read -r -u 3 number url head || [ -n "${number:-}" ]; do
    [ -n "$number" ] || continue
    case "$number" in
      ''|*[!0-9]*) continue ;;
    esac
    case "$url" in
      https://*) ;;
      *) continue ;;
    esac
    case "$url" in
      *[[:space:]]*) continue ;;
    esac
    listed=1
    changed=
    if [ -n "$head" ]; then
      changed=$(overlap_merge_tree_files "$project" "$base" "$head" 2>/dev/null) || changed=
    fi
    if [ -z "$changed" ]; then
      changed=$(overlap_pr_file_list "$project" "$number" 2>/dev/null) || changed=
    fi
    [ -n "$changed" ] || continue
    hits=$(overlap_hits "$scope" "$changed") || hits=
    [ -n "$hits" ] || continue
    hit_text=$(printf '%s\n' "$hits" | overlap_join)
    lines="${lines}
- ${url} (${hit_text})"
  done 3<<EOF
$(printf '%s\n' "$json" | jq -r 'if type == "array" then sort_by(.number) | .[] | [(.number | tostring), (.url // ""), (.headRefOid // "")] | @tsv else empty end' 2>/dev/null)
EOF
  if [ "$listed" -eq 0 ] && [ -z "$lines" ]; then
    # An empty list is a real answer. A jq failure on a non-array is not.
    if ! printf '%s\n' "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then
      overlap_rewrite_brief "$brief" "$(overlap_fail_note)" || true
      return 0
    fi
  fi
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
      'No open pull request touches the planned files.' \
      '<!-- fm-pr-overlap:end -->')
  fi
  overlap_rewrite_brief "$brief" "$note" || true
}

overlap_main "$@" || true
exit 0
