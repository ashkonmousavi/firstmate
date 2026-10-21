#!/usr/bin/env bash
# fm-capacity.sh - machine lanes and memory headroom, based on upstream's reporter.
# Usage: fm-capacity.sh [--json|--publish|--admit|--help]
# All consumers (activity, ledger, CI admission and placement) use these facts.
# fm-capacity-lib.sh owns the config/lane-capacity format and admission rules.
# No option: human report with the upstream capacity: key=value first line.
# --json: print facts. --publish: also atomically save state/lane-capacity.json.
# --admit: dry admission, exit 75 on any refusal, without allocations or writes.
# Reporting exits 1 for unreadable facts, 0 for a readable full/low-memory host.
# Publication is called by the existing home-summary refresh, not a new daemon.
# Placement consumers must reject publications older than five minutes.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  ''|--json|--publish|--admit) ;;
  *) echo 'usage: fm-capacity.sh [--json|--publish|--admit|--help]' >&2; exit 2 ;;
esac
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-capacity-lib.sh
. "$SCRIPT_DIR/fm-capacity-lib.sh"
rc=0
fm_capacity_read "$FM_HOME" "$CONFIG" "$STATE" || rc=$?
case "${1:-}" in
  --json|--publish)
    facts=$(fm_capacity_json) || exit 1
    if [ "${1:-}" = --publish ]; then
      tmp=$(mktemp "$STATE/.lane-capacity.XXXXXXXX") || exit 1
      trap 'rm -f -- "$tmp"' EXIT
      printf '%s\n' "$facts" > "$tmp" && mv -f -- "$tmp" "$STATE/lane-capacity.json" || exit 1
    fi
    printf '%s\n' "$facts"
    ;;
  *)
    printf 'capacity: free_lanes=%s reason=%s lanes=%s target=%s secondmates=%s mem_available_kb=%s reserve_kb=%s headroom_kb=%s\n' \
      "$FM_CAPACITY_FREE" "$FM_CAPACITY_REASON" "$FM_CAPACITY_LANES" "$FM_CAPACITY_TARGET" \
      "$FM_CAPACITY_SECONDMATES" "$FM_CAPACITY_AVAILABLE_KB" "$FM_CAPACITY_RESERVE_KB" "$FM_CAPACITY_HEADROOM_KB"
    printf 'Lanes: %s of %s; %s open. Memory headroom: %s kB.\n' \
      "$FM_CAPACITY_LANES" "$FM_CAPACITY_TARGET" "$FM_CAPACITY_FREE" "$FM_CAPACITY_HEADROOM_KB"
    ;;
esac
[ -z "$FM_CAPACITY_ERROR" ] || printf 'fm-capacity: %s\n' "$FM_CAPACITY_ERROR" >&2
[ "${1:-}" != --admit ] || exit "$rc"
[ "$FM_CAPACITY_REASON" != unreadable ] || exit 1
