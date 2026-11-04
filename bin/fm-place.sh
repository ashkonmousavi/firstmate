#!/usr/bin/env bash
# fm-place.sh - advise placement from machine-published fm-capacity.sh facts.
# Usage: fm-place.sh [--json] <machine-facts.json>...
# Fetch each machine's state/lane-capacity.json through its existing transport
# before invoking. Missing, malformed, future or >300s-old facts never qualify.
# Rank eligible machines by free lanes, then memory headroom, then machine name.
# Default output is a human-readable recommendation; --json emits the chosen
# publication unchanged as one compact JSON object.
# No config, probe, remote execution or spawn occurs here. Exit 75 if none fit.
set -u
format=text
if [ "${1:-}" = --json ]; then format=json; shift; fi
[ "$#" -gt 0 ] || { echo 'usage: fm-place.sh <machine-facts.json>...' >&2; exit 2; }
facts=()
for file in "$@"; do
  fact=$(jq -cse '
    def uint: type == "number" and . >= 0 and floor == .;
    select(length == 1) | .[0] |
    select(.schema == "fm-lane-capacity.v1" and .readable == true and .reason == "ok")
    | select((.machine | type == "string" and length > 0)
      and (.generated_epoch | uint) and .generated_epoch <= now and .generated_epoch >= (now-300)
      and (.target | uint) and (.lanes | uint) and (.free_lanes | uint)
      and .free_lanes > 0 and .free_lanes == (.target - .lanes)
      and (.mem_available_kb | uint) and (.reserve_kb | uint) and (.headroom_kb | uint)
      and .headroom_kb == (.mem_available_kb - .reserve_kb))
  ' "$file" 2>/dev/null) || { echo "unavailable: $file" >&2; continue; }
  facts+=("$fact")
done
[ "${#facts[@]}" -gt 0 ] || { echo 'Placement: none (no readable machine has room).' >&2; exit 75; }
winner=$(printf '%s\n' "${facts[@]}" | jq -sc '
  sort_by([-.free_lanes, -.headroom_kb, .machine]) | .[0]') || exit 1
if [ "$format" = json ]; then printf '%s\n' "$winner"; exit 0; fi
printf '%s\n' "$winner" | jq -r '
  "Placement: \(.machine) (\(.free_lanes) lanes free, \(.headroom_kb) kB memory headroom)."'
