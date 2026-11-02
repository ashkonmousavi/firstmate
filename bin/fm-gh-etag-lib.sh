#!/usr/bin/env bash
# fm-gh-etag-lib.sh - the one conditional-GET helper for GitHub REST polls.
#
# WHY. Every request made with the fleet's one personal token, from every
# machine and worker, spends the same 5,000-per-hour core budget. GitHub does
# not count a conditional request that answers 304 Not Modified against that
# budget (docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api),
# so a poll of an unchanged object is free once it sends the ETag it last saw.
# The research record is data/research-book/github-rate-limits.md.
#
# USE. Source this file, then call, without a command substitution so the
# result globals survive:
#
#   fm_gh_etag_get <cache-dir> <key> <endpoint> [extra gh api args...]
#
# <endpoint> is one REST path (for example repos/o/r/pulls/7?per_page=100).
# <key> names this poll inside <cache-dir>; it is [A-Za-z0-9._-] only. The
# helper keeps three records per key there: <key>.etag, <key>.body and, for an
# endpoint that spans pages, <key>.multi. Nothing else is read or written.
#
# Results (globals):
#   FM_GH_ETAG_STATUS  200 fresh body fetched, 304 cached body is current
#   FM_GH_ETAG_VALUE   the ETag now stored for the key
#   FM_GH_ETAG_BODY    path of the body file, valid until the next call on the key
# Return: 0 ok (200 or 304), 1 the request failed (the cache is left untouched),
#   2 gh or the cache directory is unusable, 3 the endpoint spans more than one
#   page, so a caller must paginate it unconditionally instead (an ETag on page
#   one says nothing about page two; the key is marked for a day so the probe
#   is not repeated every tick).
#
# A 304 carries no body, so the cached body is the answer; a caller that needs
# facts that age without the object changing (for example the minutes since a
# label was applied) must keep the aged input, not only the verdict.
# `-i` and `--paginate` do not mix, which is why page-spanning endpoints are
# refused rather than faked.
#
# FM_GH_CONDITIONAL=0 turns every conditional read off (the call returns 2 and
# callers use their unconditional reads), an escape hatch for a gh that
# misbehaves and for tests that count exact unconditional calls.
#
# fm_gh_etag_run is the single place gh is invoked; a sourcing script that
# bounds or retries forge reads redefines it after sourcing.
#
# Sourced by bin/fm-pr-poll.sh, bin/fm-pr-orphan-sweep.sh,
# bin/fm-contributions.sh and bin/fm-inactive-reconcile.sh. No side effects
# on source.

# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_GH_ETAG_STATUS=
# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_GH_ETAG_VALUE=
# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_GH_ETAG_BODY=

# Seconds a page-spanning mark suppresses the one-page probe.
FM_GH_ETAG_MULTI_TTL=86400
# Cache entries untouched this long are swept when a new one is written.
FM_GH_ETAG_PRUNE_AGE_DAYS=14

fm_gh_etag_run() {
  GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@"
}

fm_gh_etag_dir_ready() {  # <dir>
  local dir=$1
  [ -n "$dir" ] && [ ! -L "$dir" ] || return 1
  if [ ! -d "$dir" ]; then
    local parent=${dir%/*}
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    mkdir -m 0700 "$dir" 2>/dev/null || [ -d "$dir" ] || return 1
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -w "$dir" ]
}

fm_gh_etag_regular() {  # <file>
  [ -f "$1" ] && [ ! -L "$1" ]
}

fm_gh_etag_mtime() {  # <file>
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_gh_etag_get() {  # <cache-dir> <key> <endpoint> [gh api args...]
  local dir=${1-} key=${2-} endpoint=${3-} etag_file body_file multi_file
  local raw status etag='' stored='' next=0 mark now tmp_body rc=0
  FM_GH_ETAG_STATUS=
  FM_GH_ETAG_VALUE=
  FM_GH_ETAG_BODY=
  [ "${FM_GH_CONDITIONAL:-1}" != 0 ] || return 2
  [ "$#" -ge 3 ] && [ -n "$endpoint" ] || return 2
  shift 3
  case "$key" in
    ''|*[!A-Za-z0-9._-]*|.|..) return 2 ;;
  esac
  command -v gh >/dev/null 2>&1 || return 2
  fm_gh_etag_dir_ready "$dir" || return 2
  etag_file="$dir/$key.etag"
  body_file="$dir/$key.body"
  multi_file="$dir/$key.multi"

  if fm_gh_etag_regular "$multi_file"; then
    mark=$(fm_gh_etag_mtime "$multi_file") || mark=0
    now=$(date +%s)
    case "$mark" in ''|*[!0-9]*) mark=0 ;; esac
    if [ $((now - mark)) -lt "$FM_GH_ETAG_MULTI_TTL" ]; then
      return 3
    fi
    rm -f -- "$multi_file"
  fi

  # Send the stored tag only while the stored body that it describes is intact.
  if fm_gh_etag_regular "$etag_file" && fm_gh_etag_regular "$body_file"; then
    IFS= read -r stored < "$etag_file" || stored=
    case "$stored" in
      *[$'\r\n\t']*|'') stored= ;;
    esac
  fi

  raw=$(mktemp "$dir/.raw.XXXXXX") || return 2
  tmp_body=$(mktemp "$dir/.body.XXXXXX") || { rm -f -- "$raw"; return 2; }
  if [ -n "$stored" ]; then
    fm_gh_etag_run api -i -H "If-None-Match: $stored" "$@" "$endpoint" > "$raw" 2>/dev/null </dev/null || rc=$?
  else
    fm_gh_etag_run api -i "$@" "$endpoint" > "$raw" 2>/dev/null </dev/null || rc=$?
  fi
  # gh exits non-zero on 304, so a 304 is read from the status line alone; a
  # 200 must also have exited 0, or its body may have been cut off mid-transfer.
  status=$(awk 'NR == 1 { print $2; exit }' "$raw" | tr -d '\r')
  case "$status:$rc" in
    200:0|304:*) ;;
    *) rm -f -- "$raw" "$tmp_body"; return 1 ;;
  esac
  awk -v body="$tmp_body" -v etag_out="$raw.etag" -v next_out="$raw.next" '
    BEGIN { header = 1 }
    header {
      sub(/\r$/, "")
      if ($0 == "") { header = 0; next }
      name = tolower($0)
      if (name ~ /^etag:/) { v = $0; sub(/^[^:]*:[ \t]*/, "", v); print v > etag_out }
      if (name ~ /^link:/ && name ~ /rel="next"/) { print "1" > next_out }
      next
    }
    { print > body }
  ' "$raw"
  [ -f "$raw.etag" ] && IFS= read -r etag < "$raw.etag" || etag=
  [ -f "$raw.next" ] && next=1
  rm -f -- "$raw" "$raw.etag" "$raw.next"
  case "$etag" in
    *[$'\r\n\t']*) etag= ;;
  esac

  if [ "$status" = 304 ]; then
    rm -f -- "$tmp_body"
    fm_gh_etag_regular "$body_file" || return 1
    touch -c -- "$etag_file" "$body_file" 2>/dev/null || true
    FM_GH_ETAG_STATUS=304
    FM_GH_ETAG_VALUE=$stored
    FM_GH_ETAG_BODY=$body_file
    return 0
  fi

  if [ "$next" = 1 ]; then
    rm -f -- "$tmp_body" "$etag_file" "$body_file"
    : > "$multi_file" 2>/dev/null || true
    return 3
  fi
  [ -n "$etag" ] || { rm -f -- "$tmp_body" "$etag_file" "$body_file"; return 1; }
  chmod 0600 "$tmp_body" || { rm -f -- "$tmp_body"; return 2; }
  # Body first, tag second: a crash between them leaves a stale body that no
  # stored tag vouches for, never a tag that vouches for a missing body.
  rm -f -- "$etag_file"
  mv -f -- "$tmp_body" "$body_file" || { rm -f -- "$tmp_body"; return 2; }
  if ! { printf '%s\n' "$etag" > "$etag_file.tmp.$$" && chmod 0600 "$etag_file.tmp.$$" \
    && mv -f -- "$etag_file.tmp.$$" "$etag_file"; }; then
    rm -f -- "$etag_file.tmp.$$"
    return 2
  fi
  find "$dir" -maxdepth 1 -type f \( \( -name '.raw.*' -o -name '.body.*' \) -mtime +0 \
    -o ! -name '.*' -mtime "+$FM_GH_ETAG_PRUNE_AGE_DAYS" \) -delete 2>/dev/null || true
  FM_GH_ETAG_STATUS=200
  FM_GH_ETAG_VALUE=$etag
  FM_GH_ETAG_BODY=$body_file
  return 0
}
