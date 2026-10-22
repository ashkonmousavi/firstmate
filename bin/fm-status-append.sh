#!/usr/bin/env bash
# fm-status-append.sh - append one status line, with the report text as data.
#
# The report text is read from stdin and written with printf. It is never
# evaluated, so backticks, command substitutions, and dollar expansions in a
# report stay literal characters. Callers pass that text with a quoted heredoc.
#
# Usage:
#   fm-status-append.sh <status-file> <state> [--key K] [--corr ID] <<'EOF'
#   <one short line>
#   EOF
#
# One line is written:
#   <state> [key=K] [corr=ID] [at=<epoch>] [handoff=<sha>]: <text>
# Key and corr are omitted when those flags are absent. Their order is the
# documented before-colon order: key, then corr, then the time stamp.
# The optional handoff tag follows the rule below.
# Newlines in the text are folded to spaces. One trailing newline, the
# heredoc's usual terminator, is dropped before that fold.
# The clock is read here. A hand-written status line still uses the literal
# <epoch> placeholder; this command does not.
#
# When FM_CONFIG_OVERRIDE is set, or otherwise the sibling config/ of the
# status file's state directory, an existing fleet-ledger flag runs
# bin/fm-fleet-ledger.sh appended exactly once after the line is written.
# A missing flag does nothing. A ledger failure does not change this
# command's result. A failed write runs no ledger hook and exits nonzero.
#
# A line whose text is exactly EOF ends a <<'EOF' heredoc early. Use a
# different delimiter only if a report can be that line; the brief's
# rendered command uses EOF.
#
# A ship done: that bin/fm-dod-lib.sh recognizes as the no-mistakes handoff
# gains one [handoff=<sha>] tag after the time stamp when the task meta names
# a worktree whose HEAD reads as 40 hex characters. A missing meta, a predicate
# miss, or an unreadable HEAD still appends the line exactly as before.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

# The captured head for a handoff line, or nothing.
# Never fails the append: a missing meta, a predicate miss, or an unreadable
# HEAD returns empty.
fm_status_append_handoff_sha() {  # <status-file> <line>
  local status_file=$1 line=$2 meta id kind mode wt sha
  id=$(basename -- "$status_file")
  case "$id" in
    *.status) id=${id%.status} ;;
    *) return 0 ;;
  esac
  meta=$(dirname -- "$status_file")/$id.meta
  [ -f "$meta" ] && [ -r "$meta" ] || return 0
  kind=$(fm_dod_meta_value "$meta" kind)
  mode=$(fm_dod_meta_value "$meta" mode)
  fm_dod_done_is_nm_handoff "$kind" "$mode" "$line" || return 0
  wt=$(fm_dod_meta_value "$meta" worktree)
  [ -n "$wt" ] || return 0
  sha=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 0
  fm_dod_is_sha40 "$sha" || return 0
  printf '%s\n' "$sha"
}

usage() {
  printf '%s\n' "usage: fm-status-append.sh <status-file> <state> [--key K] [--corr ID]" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
status_file=$1
state=$2
shift 2

case "$state" in
  [A-Za-z]*) ;;
  *) usage ;;
esac
case "$state" in
  *[!A-Za-z0-9_-]*) usage ;;
esac

key=
corr=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --key)
      [ "$#" -ge 2 ] || usage
      [ -z "$key" ] || usage
      key=$2
      shift 2
      ;;
    --corr)
      [ "$#" -ge 2 ] || usage
      [ -z "$corr" ] || usage
      corr=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

case "$key" in
  ''|*[!A-Za-z0-9._-]*) [ -z "$key" ] || usage ;;
esac
case "$corr" in
  corr=*) corr=${corr#corr=} ;;
esac
case "$corr" in
  '') ;;
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *) usage ;;
esac

text=$(cat; printf x)
text=${text%x}
case "$text" in
  *$'\n') text=${text%$'\n'} ;;
esac
text=${text//$'\r\n'/ }
text=${text//$'\n'/ }
text=${text//$'\r'/ }

line=$state
[ -z "$key" ] || line="$line [key=$key]"
[ -z "$corr" ] || line="$line [corr=$corr]"
epoch=$(date +%s 2>/dev/null || true)
case "$epoch" in
  ''|*[!0-9]*) epoch= ;;
esac
[ -z "$epoch" ] || line="$line [at=$epoch]"
line="$line: $text"
sha=
if [ "$state" = "done" ]; then
  sha=$(fm_status_append_handoff_sha "$status_file" "$line") || sha=
fi
if [ -n "$sha" ] && [ -n "$epoch" ]; then
  prefix=${line%%:*}
  rest=${line#*:}
  line="$prefix [handoff=$sha]:$rest"
fi
printf '%s\n' "$line" >> "$status_file"

config=${FM_CONFIG_OVERRIDE:-}
if [ -z "$config" ]; then
  config=$(dirname -- "$status_file")
  config=$(dirname -- "$config")/config
fi
if [ -e "$config/fleet-ledger" ]; then
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  "$script_dir/fm-fleet-ledger.sh" appended "$config" "$status_file" >/dev/null 2>&1 || true
fi
