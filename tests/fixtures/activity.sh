#!/usr/bin/env bash
# External activity --machine-json protocol fixture (empty machine by default).
# The test home owns the ceiling; retained metadata never supplies lane facts.
set -eu
[ "$1" = --machine-json ]
read -r target _ < "$FM_CONFIG_OVERRIDE/lane-capacity"
jq -cn --argjson target "$target" --argjson lanes "${FM_TEST_ACTIVITY_LANES:-0}" \
  '{readable:true,lanes:$lanes,target:$target,free_lanes:([$target-$lanes,0]|max)}'
