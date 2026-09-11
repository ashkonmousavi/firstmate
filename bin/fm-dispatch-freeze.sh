#!/usr/bin/env bash
# fm-dispatch-freeze.sh - guarded owner for the home-wide dispatch pause.
#
# Usage:
#   fm-dispatch-freeze.sh set --reason <text> --recheck YYYY-MM-DD
#   fm-dispatch-freeze.sh release
#   fm-dispatch-freeze.sh status
#
# A recheck date is a reminder, never an automatic release. Only `release`
# removes the record. The command always addresses the explicit/current
# FM_HOME and writes atomically beneath its private state directory.
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
FM_HOME=${FM_HOME:-$ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
RECORD="$STATE/.dispatch-freeze"

usage() {
  sed -n '2,10p' "$0" >&2
  exit 2
}

cmd=${1:-}
shift || true
case "$cmd" in
  set)
    reason='' recheck=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reason) [ "$#" -ge 2 ] || usage; reason=$2; shift 2 ;;
        --recheck) [ "$#" -ge 2 ] || usage; recheck=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$reason" ] || usage
    case "$reason" in *$'\n'*|*$'\r'*) echo "refused: reason must be one line" >&2; exit 2 ;; esac
    case "$recheck" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) usage ;; esac
    mkdir -p "$STATE"
    tmp=$(mktemp "$STATE/.dispatch-freeze.tmp.XXXXXX")
    trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
    printf '%s\n%s\n' "$reason" "$recheck" > "$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$RECORD"
    trap - EXIT HUP INT TERM
    printf 'frozen: recheck %s\n' "$recheck"
    ;;
  release)
    [ "$#" -eq 0 ] || usage
    if [ -e "$RECORD" ]; then
      rm -f -- "$RECORD"
      printf 'released\n'
    else
      printf 'already released\n'
    fi
    ;;
  status)
    [ "$#" -eq 0 ] || usage
    # shellcheck source=bin/fm-supervision-lib.sh
    . "$ROOT/bin/fm-supervision-lib.sh"
    fm_idle_freeze_line "$STATE" || printf 'released\n'
    ;;
  *) usage ;;
esac
