#!/usr/bin/env bash
# fm-lane-release-lib.sh - the read side of a lane release's durable marker.
#
# bin/fm-lane-release.sh is the only writer of state/<id>.released and owns the
# release state machine; this library is the one reader every relaunch or
# reconcile path sources, so the marker's format and its "active" rule are
# stated here once.
#
# Marker file (key=value lines, first line the format tag):
#   fm-lane-release-v1
#   task=<id>
#   spawn_gen=<the task meta's spawn_gen when the release began>
#   released_at=<epoch the release began>
#   anchor=<epoch of the finished-and-landed evidence>
#   class=<merged-ship|scout>
#   result=<releasing|released|release-incomplete>
#
# A marker is ACTIVE only while its spawn_gen equals the task meta's current
# non-empty spawn_gen. Any relaunch mints a new spawn_gen (bin/fm-spawn.sh), so
# the marker clears itself without a second writer; a stale marker is ignored
# here and removed by the next sweep.
#
# Rule for every reader: a task with an active marker is never relaunched
# automatically, and is reported as `released` (seat freed, local copy kept),
# never as dead or as needing recovery. An explicit person-driven
# `bin/fm-control.sh <id> relaunch` is the continuation path and is not a reader.
#
# Sourced; no side effects on source.

fm_lane_release_marker_path() {  # <state-dir> <id>
  printf '%s/%s.released\n' "$1" "$2"
}

# fm_lane_release_marker_field <marker> <key>: print one field's value.
fm_lane_release_marker_field() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# 0 when <id> has an active marker. Sets FM_LANE_RELEASE_CLASS,
# FM_LANE_RELEASE_RESULT, and FM_LANE_RELEASE_AT from it; clears them otherwise.
fm_lane_release_marker_active() {  # <state-dir> <id>
  local state=$1 id=$2 marker meta gen meta_gen
  FM_LANE_RELEASE_CLASS=
  FM_LANE_RELEASE_RESULT=
  FM_LANE_RELEASE_AT=
  marker=$(fm_lane_release_marker_path "$state" "$id")
  meta="$state/$id.meta"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(head -n 1 "$marker" 2>/dev/null)" = fm-lane-release-v1 ] || return 1
  [ "$(fm_lane_release_marker_field "$marker" task)" = "$id" ] || return 1
  gen=$(fm_lane_release_marker_field "$marker" spawn_gen)
  meta_gen=$(sed -n 's/^spawn_gen=//p' "$meta" 2>/dev/null | tail -n 1)
  [ -n "$gen" ] && [ "$gen" = "$meta_gen" ] || return 1
  # shellcheck disable=SC2034 # Public results consumed by sourcing readers.
  FM_LANE_RELEASE_CLASS=$(fm_lane_release_marker_field "$marker" class)
  # shellcheck disable=SC2034
  FM_LANE_RELEASE_RESULT=$(fm_lane_release_marker_field "$marker" result)
  # shellcheck disable=SC2034
  FM_LANE_RELEASE_AT=$(fm_lane_release_marker_field "$marker" released_at)
  return 0
}

# One plain phrase for a reader's report line.
fm_lane_release_phrase() {  # (after fm_lane_release_marker_active succeeded)
  printf 'released by lane release (%s, %s): seat freed, local copy kept, not a failure' \
    "${FM_LANE_RELEASE_CLASS:-unknown}" "${FM_LANE_RELEASE_RESULT:-unknown}"
}
