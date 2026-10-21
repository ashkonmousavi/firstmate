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
#   <state> [key=K] [corr=ID] [at=<epoch>]: <text>
# Key and corr are omitted when those flags are absent. Their order is the
# documented before-colon order: key, then corr, then the time stamp.
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
set -eu

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
