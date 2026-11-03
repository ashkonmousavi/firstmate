#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" != --machine-json ] || [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo 'usage: activity.sh --machine-json <machine-home> [replaced-task-meta]' >&2
  exit 2
fi
SCRIPT_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd) || exit 75
export FM_HOME=$2
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$SCRIPT_DIR/fm-agent-process-lib.sh"
fm_local_firstmate_state_dirs "$FM_HOME/state" || {
  echo "$FM_LOCAL_FIRSTMATE_ERROR" >&2; exit 75;
}
raw=$(cat -- "$FM_HOME/config/lane-capacity") || exit 75
IFS=' ' read -r ceiling reserve extra <<< "$raw"
if [[ "$raw" == *$'\n'* ]] || ! [[ "$ceiling" =~ ^[0-9]{1,6}$ && "$reserve" =~ ^[0-9]{1,6}$ ]] || [ -n "$extra" ]; then
  exit 75
fi
proc=/proc
if [ "${FM_TEST_SEAM:-}" = 1 ]; then proc=${FM_ACTIVITY_PROC_ROOT:-$proc}; fi
[ -d "$proc" ] && [ -r "$proc" ] && [ -x "$proc" ] || exit 75
live=$(
  for d in "$proc"/[0-9]*; do
    [ -O "$d" ] || continue
    name=$(cat "$d/comm" 2>/dev/null) || continue
    [ "$name" != codex-code-mode ] || continue
    args=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
    argv0=${args%% *}
    [ "$(fm_agent_process_classify "$name" "$argv0" "$args" "${d##*/}")" = agent ] || continue
    readlink "$d/cwd" 2>/dev/null || true
  done | sort -u
) || exit 75
lanes=0 secondmates=0
for dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
  [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || exit 75
  for meta in "$dir"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ "$meta" != "${3:-}" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || exit 75
    raw=$(cat -- "$meta") || exit 75
    kind=$(sed -n 's/^kind=//p' <<< "$raw" | head -1)
    if [ "$kind" = secondmate ]; then
      secondmates=$((secondmates + 1))
      continue
    fi
    worktree=$(sed -n 's/^worktree=//p' <<< "$raw" | head -1)
    [ -n "$worktree" ] || continue
    if printf '%s\n' "$live" | grep -qxF -- "$worktree"; then
      lanes=$((lanes + 1))
    fi
  done
done
ceiling=$((10#$ceiling))
free=$((ceiling - lanes))
[ "$free" -ge 0 ] || free=0
jq -cn --argjson lanes "$lanes" --argjson target "$ceiling" \
  --argjson free "$free" --argjson secondmates "$secondmates" \
  '{schema:"fm-activity-lanes.v1",generated_epoch:(now|floor),readable:true,
    lanes:$lanes,target:$target,free_lanes:$free,secondmates:$secondmates,
    source:"activity.sh live-process lister"}'
