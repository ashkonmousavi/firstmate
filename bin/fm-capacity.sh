#!/usr/bin/env bash
# fm-capacity.sh - report machine lanes, host probes and admission headroom.
# Usage: fm-capacity.sh [--json|--publish|--admit|--help]
# fm-capacity-lib.sh owns machine configuration, counting and refusal rules.
# The upstream capacity: key=value first line retains load1, cores,
# mem_free_pct and disk_free_mb as informational host probes; CPU load and
# disk figures do not change machine lane admission.
# --json reports one machine-wide `admitted` fact (readable, reason ok and a
# free lane), with generated_epoch as its age. Per-task eligibility, filtering
# before ranking and the join are computed by the consuming reader that joins
# this fact with its own task list. --publish also atomically saves
# state/lane-capacity.json for placement (fm-place.sh owns freshness).
# --admit is read-only and exits 75 on any refusal. Other reports exit 1 for
# unreadable machine facts, 0 for a readable full or low-memory machine.
# With no option, host probes are read-only and unavailable probes say unknown.
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
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
rc=0
fm_capacity_read "$FM_HOME" "$CONFIG" "$STATE" || rc=$?
# --- host probes ------------------------------------------------------------
os=$(uname -s 2>/dev/null) || os=unknown

load1=unknown
if [ "$os" = Darwin ]; then
  v=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')
else
  v=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
fi
case "$v" in [0-9]*) load1=$v ;; esac

cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cores=
is_uint "$cores" || cores=$(sysctl -n hw.logicalcpu 2>/dev/null) || cores=
is_uint "$cores" && [ "$cores" -gt 0 ] || cores=unknown

mem_free_pct=unknown
if [ "$os" = Darwin ]; then
  v=$(sysctl -n kern.memorystatus_level 2>/dev/null)
else
  v=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if (t > 0 && a != "") printf "%d", a * 100 / t}' /proc/meminfo 2>/dev/null)
fi
is_uint "$v" && mem_free_pct=$v

disk_free_mb=unknown
v=$(df -Pk "$FM_HOME" 2>/dev/null | awk 'NR==2{print int($4 / 1024)}')
is_uint "$v" && disk_free_mb=$v

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
    printf 'capacity: free_lanes=%s reason=%s lanes=%s target=%s secondmates=%s load1=%s cores=%s mem_free_pct=%s disk_free_mb=%s mem_available_kb=%s reserve_kb=%s headroom_kb=%s\n' \
      "$FM_CAPACITY_FREE" "$FM_CAPACITY_REASON" "$FM_CAPACITY_LANES" "$FM_CAPACITY_TARGET" \
      "$FM_CAPACITY_SECONDMATES" "$load1" "$cores" "$mem_free_pct" "$disk_free_mb" "$FM_CAPACITY_AVAILABLE_KB" "$FM_CAPACITY_RESERVE_KB" "$FM_CAPACITY_HEADROOM_KB"
    printf 'Lanes: %s of %s; %s open. Memory headroom: %s kB.\n' \
      "$FM_CAPACITY_LANES" "$FM_CAPACITY_TARGET" "$FM_CAPACITY_FREE" "$FM_CAPACITY_HEADROOM_KB"
    mem_text="${mem_free_pct}%"; [ "$mem_free_pct" != unknown ] || mem_text=unknown
    disk_text="$disk_free_mb MB"; [ "$disk_free_mb" != unknown ] || disk_text=unknown
    printf 'Host: load %s on %s cores, memory free %s, disk free %s.\n' "$load1" "$cores" "$mem_text" "$disk_text"
    ;;
esac
[ -z "$FM_CAPACITY_ERROR" ] || printf 'fm-capacity: %s\n' "$FM_CAPACITY_ERROR" >&2
[ "${1:-}" != --admit ] || exit "$rc"
[ "$FM_CAPACITY_REASON" != unreadable ] || exit 1
