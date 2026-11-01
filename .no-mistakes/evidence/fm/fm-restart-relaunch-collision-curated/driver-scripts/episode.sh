#!/usr/bin/env bash
# One liveness recovery episode for the mate through the real shared library,
# in the watcher tick's order: per-mate lock, probe, guarded relaunch.
. /tmp/fm-drive-01M6/env.sh
labenv STATE="$LAB/state" FM_ROOT="$LAB" bash -c '
  . "$1/bin/fm-secondmate-liveness-lib.sh"
  id=$2; meta="$STATE/$id.meta"
  if ! fm_secondmate_liveness_lock "$id"; then echo "$(date +%T.%N | cut -c1-12) skipped: lock held"; exit 0; fi
  fm_secondmate_liveness_probe "$meta" "$id" poll
  echo "$(date +%T.%N | cut -c1-12) probe=$FM_SM_LIVE_STATUS state=$FM_SM_LIVE_STATE"
  if [ "$FM_SM_LIVE_STATUS" = relaunchable ]; then
    rc=0; fm_secondmate_liveness_relaunch "$meta" "$id" 300 || rc=$?
    echo "relaunch rc=$rc"; [ "$rc" -eq 0 ] || printf "%s\n" "$FM_SM_LIVE_OUT"
  fi
  fm_secondmate_liveness_unlock "$id"
' _ "$LAB" "$ID"
